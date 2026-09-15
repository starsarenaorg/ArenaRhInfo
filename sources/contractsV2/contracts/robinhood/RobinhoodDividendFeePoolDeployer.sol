// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {IArenaPoolDeployer} from "../../../contracts/contracts/robinhood/interfaces/IArenaPoolDeployer.sol";
import {ArenaLiquidityAmounts} from "../../../contracts/contracts/robinhood/libraries/ArenaLiquidityAmounts.sol";
import {IRobinhoodDividendController} from "./interfaces/IRobinhoodDividendController.sol";
import {IRobinhoodDividendFeeHelper} from "./interfaces/IRobinhoodDividendFeeHelper.sol";
import {IRobinhoodDividendFeePoolDeployer} from "./interfaces/IRobinhoodDividendFeePoolDeployer.sol";

interface IRobinhoodV2PositionManager {
    function nextTokenId() external view returns (uint256);

    function modifyLiquidities(bytes calldata unlockData, uint256 deadline)
        external
        payable;
}

interface IRobinhoodV2Permit2 {
    function allowance(address user, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);

    function approve(
        address token,
        address spender,
        uint160 amount,
        uint48 expiration
    ) external;
}

/// @notice V2 pool deployer that initializes dividend-aware post-bond pools.
contract RobinhoodDividendFeePoolDeployer is
    Ownable2Step,
    IRobinhoodDividendFeePoolDeployer
{
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    IRobinhoodV2PositionManager public immutable POSITION_MANAGER;
    IPoolManager public immutable POOL_MANAGER;
    IRobinhoodV2Permit2 public immutable PERMIT2;

    IRobinhoodDividendFeeHelper public dividendFeeHelper;
    mapping(address => bool) public isDeployer;

    error IdenticalAddresses();
    error Token1MustBeGreaterThanToken0();
    error NotDeployer();
    error PoolTokensDoNotMatchFeeConfig();

    constructor(
        address owner_,
        IRobinhoodDividendFeeHelper dividendFeeHelper_,
        IRobinhoodV2PositionManager positionManager_,
        IPoolManager poolManager_,
        IRobinhoodV2Permit2 permit2_
    ) Ownable(owner_) {
        dividendFeeHelper = dividendFeeHelper_;
        POSITION_MANAGER = positionManager_;
        POOL_MANAGER = poolManager_;
        PERMIT2 = permit2_;
    }

    function setDividendFeeHelper(address helper) external onlyOwner {
        dividendFeeHelper = IRobinhoodDividendFeeHelper(helper);
    }

    function setDeployer(address deployer, bool authorized) external onlyOwner {
        isDeployer[deployer] = authorized;
    }

    function initPoolAndSetFees(
        IArenaPoolDeployer.PoolInitParams memory params,
        IRobinhoodDividendFeeHelper.PoolFeeConfig calldata feeConfig
    ) external returns (uint256) {
        if (!isDeployer[msg.sender]) revert NotDeployer();
        _validateFeeConfigMatchesPool(params, feeConfig);

        IERC20(params.token0).safeTransferFrom(
            msg.sender, address(this), params.token0Amount
        );
        IERC20(params.token1).safeTransferFrom(
            msg.sender, address(this), params.token1Amount
        );
        _handleTokenApprovals(
            params.token0,
            params.token1,
            params.token0Amount,
            params.token1Amount
        );

        (uint256 tokenId, PoolKey memory poolKey) =
            _initPoolAndIncreaseLiquidity(params);
        dividendFeeHelper.initializePoolConfig(poolKey.toId(), feeConfig);
        IRobinhoodDividendController(feeConfig.dividendController).registerPool(
            feeConfig.tokenId, poolKey.toId()
        );
        return tokenId;
    }

    function _validateFeeConfigMatchesPool(
        IArenaPoolDeployer.PoolInitParams memory params,
        IRobinhoodDividendFeeHelper.PoolFeeConfig calldata feeConfig
    ) internal pure {
        bool hasLaunchToken =
            params.token0 == feeConfig.launchToken || params.token1 == feeConfig.launchToken;
        bool hasRewardToken =
            params.token0 == feeConfig.rewardToken || params.token1 == feeConfig.rewardToken;
        if (!hasLaunchToken || !hasRewardToken) {
            revert PoolTokensDoNotMatchFeeConfig();
        }
    }

    function _handleTokenApprovals(
        address token0,
        address token1,
        uint256 token0Amount,
        uint256 token1Amount
    ) internal {
        (uint160 allowedAmount0,,) = PERMIT2.allowance(
            address(this), token0, address(POSITION_MANAGER)
        );
        if (allowedAmount0 < uint160(token0Amount)) {
            IERC20(token0).forceApprove(address(PERMIT2), type(uint256).max);
            PERMIT2.approve(
                token0,
                address(POSITION_MANAGER),
                type(uint160).max,
                type(uint48).max
            );
        }

        (uint160 allowedAmount1,,) = PERMIT2.allowance(
            address(this), token1, address(POSITION_MANAGER)
        );
        if (allowedAmount1 < uint160(token1Amount)) {
            IERC20(token1).forceApprove(address(PERMIT2), type(uint256).max);
            PERMIT2.approve(
                token1,
                address(POSITION_MANAGER),
                type(uint160).max,
                type(uint48).max
            );
        }
    }

    function _initPoolAndIncreaseLiquidity(
        IArenaPoolDeployer.PoolInitParams memory params
    ) internal returns (uint256 tokenId, PoolKey memory poolKey) {
        require(params.token0 != params.token1, IdenticalAddresses());
        require(params.token1 > params.token0, Token1MustBeGreaterThanToken0());
        poolKey = PoolKey({
            currency0: Currency.wrap(params.token0),
            currency1: Currency.wrap(params.token1),
            fee: params.fee,
            tickSpacing: params.tickSpacing,
            hooks: IHooks(params.hookContract)
        });

        POOL_MANAGER.initialize(poolKey, params.startingPrice);

        (bytes memory actions, bytes[] memory actionParams) =
            _getActionsAndModifyLiquiditiesParams(params, poolKey);
        POSITION_MANAGER.modifyLiquidities(
            abi.encode(actions, actionParams), block.timestamp
        );
        return (POSITION_MANAGER.nextTokenId() - 1, poolKey);
    }

    function _getActionsAndModifyLiquiditiesParams(
        IArenaPoolDeployer.PoolInitParams memory params,
        PoolKey memory poolKey
    ) internal pure returns (bytes memory actions, bytes[] memory actionParams) {
        actionParams = new bytes[](4);
        int24 tickLower = snapToTickSpacing(
            params.tickLower, params.tickSpacing
        );
        int24 tickUpper = snapToTickSpacing(
            params.tickUpper, params.tickSpacing
        );
        uint128 liquidity = ArenaLiquidityAmounts.getLiquidityForAmounts(
            params.startingPrice,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            params.token0Amount,
            params.token1Amount
        );
        actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR),
            uint8(Actions.SWEEP),
            uint8(Actions.SWEEP)
        );
        actionParams[0] = abi.encode(
            poolKey,
            tickLower,
            tickUpper,
            liquidity,
            params.token0Amount + 1,
            params.token1Amount + 1,
            params.recipient,
            params.hookData
        );
        actionParams[1] = abi.encode(poolKey.currency0, poolKey.currency1);
        actionParams[2] = abi.encode(poolKey.currency0, params.recipient);
        actionParams[3] = abi.encode(poolKey.currency1, params.recipient);
    }

    function snapToTickSpacing(int24 tick, int24 tickSpacing)
        internal
        pure
        returns (int24)
    {
        return (tick / tickSpacing) * tickSpacing;
    }

    function emergencyWithdraw(
        address[] calldata tokens,
        uint256[] calldata amounts,
        address recipient
    ) external onlyOwner {
        for (uint256 i; i < tokens.length; ++i) {
            IERC20(tokens[i]).safeTransfer(recipient, amounts[i]);
        }
    }
}
