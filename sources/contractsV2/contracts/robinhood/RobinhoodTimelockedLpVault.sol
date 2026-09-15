// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

interface IRobinhoodTimelockPositionManager {
    function ownerOf(uint256 tokenId) external view returns (address);

    function getPositionLiquidity(uint256 tokenId)
        external
        view
        returns (uint128);

    function getPoolAndPositionInfo(uint256 tokenId)
        external
        view
        returns (PoolKey memory, PositionInfo);

    function modifyLiquidities(bytes calldata unlockData, uint256 deadline)
        external
        payable;
}

/// @notice Timelocked owner and automation vault for Uniswap v4 LP positions.
/// @dev Keepers can only collect fees into this vault or compound fees into the
/// same position. Every other operation uses TimelockController's delayed
/// schedule/execute path, including position transfers, liquidity removal,
/// withdrawals, approvals, role changes, and calls to upgradeable contracts.
contract RobinhoodTimelockedLpVault is
    TimelockController,
    Pausable,
    ReentrancyGuard
{
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    IRobinhoodTimelockPositionManager public immutable POSITION_MANAGER;
    uint256 public immutable DELAY_FLOOR;
    uint256 private _minimumDelay;

    error InvalidPositionManager();
    error InvalidMinimumDelay();
    error EmptyProposers();
    error EmptyExecutors();
    error InvalidProposer(address proposer);
    error InvalidKeeper(address keeper);
    error DelayBelowFloor(uint256 delay, uint256 floor);
    error DeadlineExpired(uint256 deadline);
    error PositionOwnerMismatch(
        uint256 tokenId,
        address expectedOwner,
        address actualOwner
    );
    error InvalidMinimumLiquidity();
    error LiquidityIncreaseTooSmall(
        uint128 minimumLiquidityAdded,
        uint128 actualLiquidityAdded
    );
    error FeesCollectedBelowMinimum(
        uint256 minimumAmount0,
        uint256 actualAmount0,
        uint256 minimumAmount1,
        uint256 actualAmount1
    );
    error TimelockOnly(address caller);

    event FeesCollected(
        uint256 indexed tokenId,
        address indexed keeper,
        address indexed currency0,
        address currency1,
        uint256 amount0,
        uint256 amount1
    );
    event FeesCompounded(
        uint256 indexed tokenId,
        address indexed keeper,
        uint128 liquidityBefore,
        uint128 liquidityAfter,
        uint128 liquidityAdded
    );
    event AutomationPaused(address indexed account);
    event AutomationUnpaused();

    constructor(
        uint256 minimumDelay_,
        address[] memory proposers_,
        address[] memory executors_,
        address[] memory keepers_,
        IRobinhoodTimelockPositionManager positionManager_
    ) TimelockController(minimumDelay_, proposers_, executors_, address(0)) {
        if (minimumDelay_ == 0) revert InvalidMinimumDelay();
        if (proposers_.length == 0) revert EmptyProposers();
        if (executors_.length == 0) revert EmptyExecutors();
        if (
            address(positionManager_) == address(0)
                || address(positionManager_).code.length == 0
        ) {
            revert InvalidPositionManager();
        }

        for (uint256 i; i < proposers_.length; ++i) {
            if (proposers_[i] == address(0)) {
                revert InvalidProposer(proposers_[i]);
            }
        }
        for (uint256 i; i < keepers_.length; ++i) {
            if (keepers_[i] == address(0)) revert InvalidKeeper(keepers_[i]);
            _grantRole(KEEPER_ROLE, keepers_[i]);
        }

        DELAY_FLOOR = minimumDelay_;
        _minimumDelay = minimumDelay_;
        POSITION_MANAGER = positionManager_;
    }

    /// @notice Returns the effective delay enforced by this vault.
    function getMinDelay() public view override returns (uint256) {
        return _minimumDelay;
    }

    /// @notice Changes the effective delay through a scheduled self-call. The
    /// delay may be increased or restored to the deployment floor, never lower.
    function updateDelay(uint256 newDelay) external override {
        if (msg.sender != address(this)) revert TimelockOnly(msg.sender);
        _requireDelayFloor(newDelay);
        emit MinDelayChange(_minimumDelay, newDelay);
        _minimumDelay = newDelay;
    }

    /// @notice Schedules an operation while preserving the deployment delay as
    /// an immutable lower bound, even if the standard timelock delay is changed.
    function schedule(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) public override {
        _requireDelayFloor(delay);
        super.schedule(target, value, data, predecessor, salt, delay);
    }

    /// @notice Schedules a batch while preserving the immutable delay floor.
    function scheduleBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) public override {
        _requireDelayFloor(delay);
        super.scheduleBatch(
            targets, values, payloads, predecessor, salt, delay
        );
    }

    /// @notice Immediately stops keeper automation. Timelocked operations are
    /// unaffected and can still execute.
    function pauseAutomation() external onlyRole(CANCELLER_ROLE) {
        _pause();
        emit AutomationPaused(msg.sender);
    }

    /// @notice Resumes automation only through a scheduled self-call.
    function unpauseAutomation() external {
        if (msg.sender != address(this)) revert TimelockOnly(msg.sender);
        _unpause();
        emit AutomationUnpaused();
    }

    /// @notice Realizes accrued fees without reducing principal liquidity and
    /// sends both currencies to this vault.
    function collectFees(
        uint256 tokenId,
        uint256 minimumAmount0,
        uint256 minimumAmount1,
        uint256 deadline
    )
        external
        onlyRole(KEEPER_ROLE)
        whenNotPaused
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        _checkDeadline(deadline);
        _requirePositionOwned(tokenId);

        (PoolKey memory key,) =
            POSITION_MANAGER.getPoolAndPositionInfo(tokenId);
        uint256 balance0Before = _currencyBalance(key.currency0);
        uint256 balance1Before = _currencyBalance(key.currency1);

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            tokenId,
            uint256(0),
            uint128(0),
            uint128(0),
            bytes("")
        );
        params[1] =
            abi.encode(key.currency0, key.currency1, address(this));

        bytes memory actions = abi.encodePacked(
            uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR)
        );
        POSITION_MANAGER.modifyLiquidities(
            abi.encode(actions, params), deadline
        );

        amount0 = _currencyBalance(key.currency0) - balance0Before;
        amount1 = _currencyBalance(key.currency1) - balance1Before;
        if (amount0 < minimumAmount0 || amount1 < minimumAmount1) {
            revert FeesCollectedBelowMinimum(
                minimumAmount0, amount0, minimumAmount1, amount1
            );
        }

        emit FeesCollected(
            tokenId,
            msg.sender,
            Currency.unwrap(key.currency0),
            Currency.unwrap(key.currency1),
            amount0,
            amount1
        );
    }

    /// @notice Realizes fees and reinvests the balanced portion into the same
    /// position. No SETTLE action is included, so vault assets cannot be pulled.
    function compound(
        uint256 tokenId,
        uint128 minimumLiquidityAdded,
        uint256 deadline
    )
        external
        onlyRole(KEEPER_ROLE)
        whenNotPaused
        nonReentrant
        returns (uint128 liquidityAdded)
    {
        _checkDeadline(deadline);
        if (minimumLiquidityAdded == 0) revert InvalidMinimumLiquidity();
        _requirePositionOwned(tokenId);

        uint128 liquidityBefore =
            POSITION_MANAGER.getPositionLiquidity(tokenId);
        (PoolKey memory key,) =
            POSITION_MANAGER.getPoolAndPositionInfo(tokenId);

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            tokenId,
            uint256(0),
            uint128(0),
            uint128(0),
            bytes("")
        );
        params[1] = abi.encode(
            tokenId,
            type(uint128).max,
            type(uint128).max,
            bytes("")
        );
        params[2] =
            abi.encode(key.currency0, key.currency1, address(this));

        bytes memory actions = abi.encodePacked(
            uint8(Actions.INCREASE_LIQUIDITY),
            uint8(Actions.INCREASE_LIQUIDITY_FROM_DELTAS),
            uint8(Actions.TAKE_PAIR)
        );
        POSITION_MANAGER.modifyLiquidities(
            abi.encode(actions, params), deadline
        );

        uint128 liquidityAfter =
            POSITION_MANAGER.getPositionLiquidity(tokenId);
        if (liquidityAfter > liquidityBefore) {
            liquidityAdded = liquidityAfter - liquidityBefore;
        }
        if (liquidityAdded < minimumLiquidityAdded) {
            revert LiquidityIncreaseTooSmall(
                minimumLiquidityAdded, liquidityAdded
            );
        }

        emit FeesCompounded(
            tokenId,
            msg.sender,
            liquidityBefore,
            liquidityAfter,
            liquidityAdded
        );
    }

    function _requireDelayFloor(uint256 delay) internal view {
        if (delay < DELAY_FLOOR) revert DelayBelowFloor(delay, DELAY_FLOOR);
    }

    function _checkDeadline(uint256 deadline) internal view {
        if (block.timestamp > deadline) revert DeadlineExpired(deadline);
    }

    function _requirePositionOwned(uint256 tokenId) internal view {
        address actualOwner = POSITION_MANAGER.ownerOf(tokenId);
        if (actualOwner != address(this)) {
            revert PositionOwnerMismatch(
                tokenId, address(this), actualOwner
            );
        }
    }

    function _currencyBalance(Currency currency)
        internal
        view
        returns (uint256)
    {
        address token = Currency.unwrap(currency);
        if (token == address(0)) return address(this).balance;
        return IERC20(token).balanceOf(address(this));
    }
}
