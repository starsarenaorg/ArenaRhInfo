// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev Creation-fee buyback support for the Robinhood Chain launch stack.

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";

interface ICreationFeeUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline)
        external
        payable;

    function poolManager() external view returns (address);
}

/// @notice Queues native-ETH token-creation fees and swaps them into ARENA through
///         one immutable, initialized Uniswap v4 pool.
/// @dev Deposits remain available while swaps are paused so a DEX outage cannot
///      block token launches. Swap execution is keeper-gated and always requires
///      an exact ETH input, nonzero minimum output and deadline. ARENA is delivered
///      directly to the immutable vault and can never be redirected by a keeper.
contract CreationFeeBuybackAdapter is Ownable2Step, Pausable, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    bytes1 private constant V4_SWAP_COMMAND = 0x10;

    /// @dev Shape required by Robinhood's deployed Universal Router. Encoding
    /// the fields flat omits the leading tuple offset required by hookData.
    struct RobinhoodExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    IERC20 public immutable ARENA;
    address public immutable ARENA_VAULT;
    ICreationFeeUniversalRouter public immutable UNIVERSAL_ROUTER;
    IPoolManager public immutable POOL_MANAGER;
    IStateView public immutable STATE_VIEW;
    uint24 public immutable POOL_FEE;
    int24 public immutable TICK_SPACING;
    address public immutable HOOKS;
    bytes32 public immutable POOL_ID;

    uint256 public pendingEth;
    mapping(address => bool) public isDepositor;
    mapping(address => bool) public isKeeper;

    error InvalidAddress();
    error InvalidPoolConfiguration();
    error PoolNotInitialized();
    error UnauthorizedDepositor();
    error UnauthorizedKeeper();
    error ZeroAmount();
    error InvalidMinimumOutput();
    error DeadlineExpired();
    error AmountExceedsPendingEth();
    error InputNotFullyConsumed();
    error InsufficientArenaOutput();
    error UnsupportedArenaToken();
    error UnauthorizedNativeTransfer();
    error EthTransferFailed();
    error CannotRecoverArena();

    event DepositorSet(address indexed depositor, bool authorized);
    event KeeperSet(address indexed keeper, bool authorized);
    event CreationFeeDeposited(address indexed depositor, uint256 amount, uint256 pendingEth);
    event BuybackExecuted(
        address indexed keeper,
        uint256 ethIn,
        uint256 arenaOut,
        uint256 pendingEth
    );
    event ArenaSweptToVault(uint256 amount);
    event UnaccountedEthRecovered(address indexed recipient, uint256 amount);
    event UnsupportedTokenRecovered(
        address indexed token,
        address indexed recipient,
        uint256 amount
    );

    constructor(
        address owner_,
        IERC20 arena_,
        address arenaVault_,
        ICreationFeeUniversalRouter universalRouter_,
        IStateView stateView_,
        uint24 poolFee_,
        int24 tickSpacing_,
        address hooks_
    ) Ownable(owner_) {
        if (
            owner_ == address(0) || address(arena_) == address(0)
                || address(arena_).code.length == 0 || arenaVault_ == address(0)
                || arenaVault_ == address(this) || address(universalRouter_) == address(0)
                || address(universalRouter_).code.length == 0 || address(stateView_) == address(0)
                || address(stateView_).code.length == 0
        ) revert InvalidAddress();
        if (poolFee_ == 0 || tickSpacing_ <= 0) revert InvalidPoolConfiguration();
        if (hooks_ != address(0) && hooks_.code.length == 0) revert InvalidAddress();

        address poolManager = universalRouter_.poolManager();
        if (
            poolManager == address(0) || poolManager.code.length == 0
                || address(stateView_.poolManager()) != poolManager
        ) revert InvalidPoolConfiguration();

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(arena_)),
            fee: poolFee_,
            tickSpacing: tickSpacing_,
            hooks: IHooks(hooks_)
        });
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96,,,) = stateView_.getSlot0(poolId);
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        ARENA = arena_;
        ARENA_VAULT = arenaVault_;
        UNIVERSAL_ROUTER = universalRouter_;
        POOL_MANAGER = IPoolManager(poolManager);
        STATE_VIEW = stateView_;
        POOL_FEE = poolFee_;
        TICK_SPACING = tickSpacing_;
        HOOKS = hooks_;
        POOL_ID = PoolId.unwrap(poolId);
    }

    function setDepositor(address depositor, bool authorized) external onlyOwner {
        if (depositor == address(0)) revert InvalidAddress();
        isDepositor[depositor] = authorized;
        emit DepositorSet(depositor, authorized);
    }

    function setKeeper(address keeper, bool authorized) external onlyOwner {
        if (keeper == address(0)) revert InvalidAddress();
        isKeeper[keeper] = authorized;
        emit KeeperSet(keeper, authorized);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function depositCreationFee() external payable {
        if (!isDepositor[msg.sender]) revert UnauthorizedDepositor();
        if (msg.value == 0) revert ZeroAmount();
        pendingEth += msg.value;
        emit CreationFeeDeposited(msg.sender, msg.value, pendingEth);
    }

    function executeBuyback(uint256 amountIn, uint256 minArenaOut, uint256 deadline)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 arenaOut)
    {
        if (!isKeeper[msg.sender]) revert UnauthorizedKeeper();
        if (amountIn == 0) revert ZeroAmount();
        if (minArenaOut == 0) revert InvalidMinimumOutput();
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (amountIn > pendingEth) revert AmountExceedsPendingEth();
        if (amountIn > type(uint128).max) revert InvalidPoolConfiguration();
        if (minArenaOut > type(uint128).max) revert InvalidMinimumOutput();

        uint256 ethBefore = address(this).balance;
        uint256 arenaBefore = ARENA.balanceOf(address(this));
        pendingEth -= amountIn;

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(ARENA)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOKS)
        });
        bytes[] memory actionParams = new bytes[](4);
        actionParams[0] = abi.encode(
            RobinhoodExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: uint128(amountIn),
                amountOutMinimum: uint128(minArenaOut),
                minHopPriceX36: 0,
                hookData: bytes("")
            })
        );
        actionParams[1] = abi.encode(address(0), amountIn, true);
        actionParams[2] = abi.encode(address(ARENA), minArenaOut);
        actionParams[3] = abi.encode(address(0), uint256(0));

        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE),
            uint8(Actions.SETTLE),
            uint8(Actions.TAKE_ALL),
            uint8(Actions.TAKE_ALL)
        );
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, actionParams);
        UNIVERSAL_ROUTER.execute{value: amountIn}(
            abi.encodePacked(V4_SWAP_COMMAND), inputs, deadline
        );

        if (address(this).balance != ethBefore - amountIn) revert InputNotFullyConsumed();
        arenaOut = ARENA.balanceOf(address(this)) - arenaBefore;
        if (arenaOut < minArenaOut) revert InsufficientArenaOutput();
        _transferArenaToVault(arenaOut);
        emit BuybackExecuted(msg.sender, amountIn, arenaOut, pendingEth);
    }

    /// @notice Sends ARENA transferred to this contract outside a buyback to the
    ///         only permitted ARENA destination.
    function sweepArenaToVault() external nonReentrant returns (uint256 amount) {
        amount = ARENA.balanceOf(address(this));
        if (amount == 0) revert ZeroAmount();
        _transferArenaToVault(amount);
        emit ArenaSweptToVault(amount);
    }

    function recoverUnaccountedEth(address payable recipient)
        external
        onlyOwner
        nonReentrant
        returns (uint256 amount)
    {
        if (recipient == address(0)) revert InvalidAddress();
        amount = address(this).balance - pendingEth;
        if (amount == 0) revert ZeroAmount();
        (bool success,) = recipient.call{value: amount}("");
        if (!success) revert EthTransferFailed();
        emit UnaccountedEthRecovered(recipient, amount);
    }

    function recoverUnsupportedToken(address token, address recipient)
        external
        onlyOwner
        nonReentrant
        returns (uint256 amount)
    {
        if (token == address(ARENA)) revert CannotRecoverArena();
        if (token == address(0) || recipient == address(0)) revert InvalidAddress();
        amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransfer(recipient, amount);
        emit UnsupportedTokenRecovered(token, recipient, amount);
    }

    function _transferArenaToVault(uint256 amount) internal {
        uint256 beforeBalance = ARENA.balanceOf(ARENA_VAULT);
        ARENA.safeTransfer(ARENA_VAULT, amount);
        if (ARENA.balanceOf(ARENA_VAULT) - beforeBalance != amount) {
            revert UnsupportedArenaToken();
        }
    }

    receive() external payable {
        if (msg.sender != address(UNIVERSAL_ROUTER) && msg.sender != address(POOL_MANAGER)) {
            revert UnauthorizedNativeTransfer();
        }
    }
}
