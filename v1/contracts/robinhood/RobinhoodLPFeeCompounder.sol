// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

interface IRobinhoodCompoundPositionManager {
    function ownerOf(uint256 tokenId) external view returns (address);
    function getApproved(uint256 tokenId) external view returns (address);
    function isApprovedForAll(address owner, address operator)
        external
        view
        returns (bool);
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

/// @notice Compounds accrued Uniswap v4 LP fees into approved positions owned
/// by a fixed vault.
/// @dev This contract deliberately has no arbitrary-call, token-transfer,
/// position-transfer, settlement, liquidity-decrease, or upgrade functionality.
/// The only PositionManager action plan it can submit:
/// 1. realizes accrued fees without changing principal liquidity,
/// 2. reinvests the usable fee ratio into the same position, and
/// 3. returns unmatched fee dust to POSITION_OWNER.
contract RobinhoodLPFeeCompounder is
    Ownable2Step,
    Pausable,
    ReentrancyGuard
{
    IRobinhoodCompoundPositionManager public immutable POSITION_MANAGER;
    address public immutable POSITION_OWNER;

    mapping(address admin => bool authorized) public compoundAdmins;

    error InvalidAddress();
    error UnauthorizedCompoundAdmin(address caller);
    error DeadlineExpired(uint256 deadline);
    error InvalidMinimumLiquidity();
    error PositionOwnerMismatch(
        uint256 tokenId,
        address expectedOwner,
        address actualOwner
    );
    error PositionApprovalRequired(
        uint256 tokenId,
        address expectedApproval,
        address actualApproval
    );
    error OwnershipRenounceDisabled();
    error LiquidityIncreaseTooSmall(
        uint128 minimumLiquidityAdded,
        uint128 actualLiquidityAdded
    );

    event CompoundAdminSet(address indexed admin, bool authorized);
    event FeesCompounded(
        uint256 indexed tokenId,
        address indexed admin,
        uint128 liquidityBefore,
        uint128 liquidityAfter,
        uint128 liquidityAdded
    );

    modifier onlyCompoundAdmin() {
        if (!compoundAdmins[msg.sender]) {
            revert UnauthorizedCompoundAdmin(msg.sender);
        }
        _;
    }

    constructor(
        address positionOwner_,
        IRobinhoodCompoundPositionManager positionManager_,
        address initialCompoundAdmin_
    )
        Ownable(positionOwner_)
    {
        if (
            positionOwner_ == address(0)
                || address(positionManager_) == address(0)
                || address(positionManager_).code.length == 0
                || initialCompoundAdmin_ == address(0)
        ) {
            revert InvalidAddress();
        }
        POSITION_OWNER = positionOwner_;
        POSITION_MANAGER = positionManager_;
        compoundAdmins[initialCompoundAdmin_] = true;
        emit CompoundAdminSet(initialCompoundAdmin_, true);
    }

    function setCompoundAdmin(address admin, bool authorized)
        external
        onlyOwner
    {
        if (admin == address(0)) revert InvalidAddress();
        compoundAdmins[admin] = authorized;
        emit CompoundAdminSet(admin, authorized);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function renounceOwnership() public pure override {
        revert OwnershipRenounceDisabled();
    }

    /// @notice Reinvests accrued fees into the same v4 position.
    /// @param tokenId The approved PositionManager NFT.
    /// @param minimumLiquidityAdded Minimum acceptable position-liquidity gain.
    /// @param deadline Latest timestamp at which the operation may execute.
    /// @return liquidityAdded The amount by which position liquidity increased.
    function compound(
        uint256 tokenId,
        uint128 minimumLiquidityAdded,
        uint256 deadline
    )
        external
        onlyCompoundAdmin
        whenNotPaused
        nonReentrant
        returns (uint128 liquidityAdded)
    {
        if (block.timestamp > deadline) revert DeadlineExpired(deadline);
        if (minimumLiquidityAdded == 0) revert InvalidMinimumLiquidity();

        address actualOwner = POSITION_MANAGER.ownerOf(tokenId);
        if (actualOwner != POSITION_OWNER) {
            revert PositionOwnerMismatch(
                tokenId, POSITION_OWNER, actualOwner
            );
        }

        // Accept either exact per-token approval or operator-wide approval
        // from the immutable position owner.
        address actualApproval = POSITION_MANAGER.getApproved(tokenId);
        bool operatorApproved = POSITION_MANAGER.isApprovedForAll(
            POSITION_OWNER, address(this)
        );
        if (actualApproval != address(this) && !operatorApproved) {
            revert PositionApprovalRequired(
                tokenId, address(this), actualApproval
            );
        }

        uint128 liquidityBefore =
            POSITION_MANAGER.getPositionLiquidity(tokenId);
        (PoolKey memory key,) =
            POSITION_MANAGER.getPoolAndPositionInfo(tokenId);

        bytes[] memory params = new bytes[](3);

        // Increasing by zero realizes all fees as positive PoolManager deltas
        // without decreasing or otherwise touching principal liquidity.
        params[0] = abi.encode(
            tokenId,
            uint256(0),
            uint128(0),
            uint128(0),
            bytes("")
        );

        // Reinvest the maximum balanced liquidity derivable solely from those
        // positive deltas. There is deliberately no SETTLE action in this plan,
        // so the compounder cannot pull tokens from itself or POSITION_OWNER.
        params[1] = abi.encode(
            tokenId,
            type(uint128).max,
            type(uint128).max,
            bytes("")
        );

        // Return any one-sided fee remainder to the immutable position owner.
        params[2] =
            abi.encode(key.currency0, key.currency1, POSITION_OWNER);

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
}
