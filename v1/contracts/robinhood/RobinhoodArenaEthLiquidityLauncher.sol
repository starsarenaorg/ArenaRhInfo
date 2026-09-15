// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {ArenaLiquidityAmounts} from "./libraries/ArenaLiquidityAmounts.sol";

interface IArenaEthPositionManager {
    function nextTokenId() external view returns (uint256);
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline)
        external
        payable;
}

interface IArenaEthPermit2 {
    function allowance(address user, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);

    function approve(address token, address spender, uint160 amount, uint48 expiration)
        external;
}

/// @notice One-purpose production coordinator for atomically initializing and
/// seeding the canonical native-ETH/ARENA Uniswap v4 pool.
/// @dev The fee, tick spacing, hook and range are immutable. The fee hook must
/// authorize this contract (not an EOA) as an initializer before launch. The
/// resulting position is an ordinary unlocked, transferable v4 position NFT.
contract RobinhoodArenaEthLiquidityLauncher is Ownable2Step, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    IERC20 public immutable ARENA;
    IArenaEthPositionManager public immutable POSITION_MANAGER;
    IPoolManager public immutable POOL_MANAGER;
    IArenaEthPermit2 public immutable PERMIT2;
    uint24 public immutable LP_FEE;
    int24 public immutable TICK_SPACING;
    int24 public immutable TICK_LOWER;
    int24 public immutable TICK_UPPER;
    IHooks public immutable HOOKS;
    uint160 public immutable EXPECTED_SQRT_PRICE_X96;
    uint160 public immutable MIN_SQRT_PRICE_X96;
    uint160 public immutable MAX_SQRT_PRICE_X96;

    bool public launched;
    uint256 public positionTokenId;

    error AlreadyLaunched();
    error InvalidAddress();
    error InvalidAmount();
    error InvalidTicks();
    error NativeRefundFailed();

    event PoolInitializedAndSeeded(
        PoolId indexed poolId,
        uint256 indexed tokenId,
        address indexed positionOwner,
        uint160 sqrtPriceX96,
        uint256 ethAmount,
        uint256 arenaAmount,
        uint128 liquidity
    );

    constructor(
        address owner_,
        IERC20 arena_,
        IArenaEthPositionManager positionManager_,
        IPoolManager poolManager_,
        IArenaEthPermit2 permit2_,
        uint24 lpFee_,
        int24 tickSpacing_,
        int24 tickLower_,
        int24 tickUpper_,
        IHooks hooks_,
        uint160 expectedSqrtPriceX96_,
        uint160 minSqrtPriceX96_,
        uint160 maxSqrtPriceX96_
    ) Ownable(owner_) {
        if (
            owner_ == address(0) || address(arena_) == address(0)
                || address(positionManager_) == address(0)
                || address(poolManager_) == address(0)
                || address(permit2_) == address(0) || address(hooks_) == address(0)
        ) revert InvalidAddress();
        if (
            tickSpacing_ <= 0 || tickLower_ >= tickUpper_
                || tickLower_ % tickSpacing_ != 0 || tickUpper_ % tickSpacing_ != 0
                || tickLower_ < TickMath.MIN_TICK || tickUpper_ > TickMath.MAX_TICK
        ) revert InvalidTicks();
        if (
            minSqrtPriceX96_ == 0 || minSqrtPriceX96_ > expectedSqrtPriceX96_
                || expectedSqrtPriceX96_ > maxSqrtPriceX96_
        ) revert InvalidTicks();

        ARENA = arena_;
        POSITION_MANAGER = positionManager_;
        POOL_MANAGER = poolManager_;
        PERMIT2 = permit2_;
        LP_FEE = lpFee_;
        TICK_SPACING = tickSpacing_;
        TICK_LOWER = tickLower_;
        TICK_UPPER = tickUpper_;
        HOOKS = hooks_;
        EXPECTED_SQRT_PRICE_X96 = expectedSqrtPriceX96_;
        MIN_SQRT_PRICE_X96 = minSqrtPriceX96_;
        MAX_SQRT_PRICE_X96 = maxSqrtPriceX96_;
    }

    function poolKey() public view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(ARENA)),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: HOOKS
        });
    }

    function poolId() external view returns (PoolId) {
        return poolKey().toId();
    }

    /// @notice Initializes the immutable pool and mints its first position in
    /// the same transaction. Any failure rolls back both operations.
    function launch(
        uint128 arenaAmount,
        address positionOwner,
        address refundRecipient
    ) external payable onlyOwner nonReentrant returns (uint256 tokenId) {
        if (launched) revert AlreadyLaunched();
        if (
            msg.value == 0 || msg.value >= type(uint128).max
                || arenaAmount == 0 || arenaAmount == type(uint128).max
        ) revert InvalidAmount();
        if (positionOwner == address(0) || refundRecipient == address(0)) {
            revert InvalidAddress();
        }

        PoolKey memory key = poolKey();
        uint160 sqrtPriceX96 = EXPECTED_SQRT_PRICE_X96;
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(TICK_LOWER);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(TICK_UPPER);
        if (
            sqrtPriceX96 < MIN_SQRT_PRICE_X96
                || sqrtPriceX96 > MAX_SQRT_PRICE_X96
                || sqrtPriceX96 <= sqrtLower || sqrtPriceX96 >= sqrtUpper
        ) {
            revert InvalidTicks();
        }

        uint128 liquidity = ArenaLiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtLower,
            sqrtUpper,
            msg.value,
            arenaAmount
        );
        if (liquidity == 0) revert InvalidAmount();

        ARENA.safeTransferFrom(msg.sender, address(this), arenaAmount);
        _ensureApprovals(arenaAmount);

        // Pool initialization and position minting deliberately share this call.
        // A revert in settlement or minting also reverts initialize().
        POOL_MANAGER.initialize(key, sqrtPriceX96);
        tokenId = POSITION_MANAGER.nextTokenId();

        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(
            key,
            TICK_LOWER,
            TICK_UPPER,
            liquidity,
            uint128(msg.value + 1),
            uint128(uint256(arenaAmount) + 1),
            positionOwner,
            bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, refundRecipient);
        params[3] = abi.encode(key.currency1, refundRecipient);
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR),
            uint8(Actions.SWEEP),
            uint8(Actions.SWEEP)
        );

        POSITION_MANAGER.modifyLiquidities{value: msg.value}(
            abi.encode(actions, params), block.timestamp
        );

        launched = true;
        positionTokenId = tokenId;
        emit PoolInitializedAndSeeded(
            key.toId(), tokenId, positionOwner, sqrtPriceX96, msg.value,
            arenaAmount, liquidity
        );
    }

    function _ensureApprovals(uint128 arenaAmount) private {
        ARENA.forceApprove(address(PERMIT2), type(uint256).max);
        (uint160 allowed,,) = PERMIT2.allowance(
            address(this), address(ARENA), address(POSITION_MANAGER)
        );
        if (allowed < arenaAmount) {
            PERMIT2.approve(
                address(ARENA), address(POSITION_MANAGER), type(uint160).max,
                type(uint48).max
            );
        }
    }

    /// @notice Recovers only accidental post-launch dust. The position NFT is
    /// minted directly to positionOwner and is never controlled here.
    function recoverDust(address token, address recipient) external onlyOwner {
        if (recipient == address(0)) revert InvalidAddress();
        if (token == address(0)) {
            uint256 balance = address(this).balance;
            (bool success,) = recipient.call{value: balance}("");
            if (!success) revert NativeRefundFailed();
        } else {
            IERC20 asset = IERC20(token);
            asset.safeTransfer(recipient, asset.balanceOf(address(this)));
        }
    }

    receive() external payable {}
}
