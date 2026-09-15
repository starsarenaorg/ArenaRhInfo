// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";

import {RobinhoodCurrencySettler} from "../../../contracts/contracts/robinhood/libraries/RobinhoodCurrencySettler.sol";
import {IRobinhoodDividendController} from "./interfaces/IRobinhoodDividendController.sol";
import {IRobinhoodDividendFeeHelper} from "./interfaces/IRobinhoodDividendFeeHelper.sol";

/// @notice V2 post-bond hook that charges every swap fee in the paired asset.
contract RobinhoodDividendFeeHook is BaseHook, Ownable2Step, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using RobinhoodCurrencySettler for Currency;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    uint24 internal constant MAX_HOOK_FEE = 1e6;
    uint24 public constant MAX_TOTAL_FEE_PPM = 99_000;

    IRobinhoodDividendFeeHelper public dividendFeeHelper;
    mapping(address => bool) public isDeployer;

    error RewardCurrencyCantBeNative();
    error TotalFeeExceedsHookCap(uint256 totalFeePpm, uint256 maxFeePpm);

    event DividendFeeHelperSet(address indexed oldHelper, address indexed newHelper);
    event DeployerSet(address indexed deployer, bool authorized);
    event PairedFeesTaken(
        PoolId indexed poolId,
        uint256 indexed tokenId,
        address indexed sender,
        address rewardToken,
        uint256 basisAmount,
        uint256 dividendAmount,
        uint256 creatorAmount,
        uint256 protocolAmount,
        uint256 referralAmount
    );

    constructor(
        address owner_,
        address dividendFeeHelper_,
        IPoolManager poolManager_
    ) Ownable(owner_) BaseHook(poolManager_) {
        dividendFeeHelper = IRobinhoodDividendFeeHelper(dividendFeeHelper_);
    }

    function setDividendFeeHelper(address helper) external onlyOwner {
        address oldHelper = address(dividendFeeHelper);
        dividendFeeHelper = IRobinhoodDividendFeeHelper(helper);
        emit DividendFeeHelperSet(oldHelper, helper);
    }

    function setDeployer(address deployer, bool authorized) external onlyOwner {
        isDeployer[deployer] = authorized;
        emit DeployerSet(deployer, authorized);
    }

    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override nonReentrant returns (bytes4, BeforeSwapDelta, uint24) {
        IRobinhoodDividendFeeHelper.SwapFeeInfo memory info =
            dividendFeeHelper.getSwapFeeInfo(key.toId());
        Currency rewardCurrency = Currency.wrap(info.rewardToken);
        Currency specified = _specifiedCurrency(key, params);
        if (!(specified == rewardCurrency)) {
            return (
                IHooks.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                0
            );
        }

        uint256 basisAmount = _absAmountSpecified(params.amountSpecified);
        uint256 feeAmount =
            _takeAndRouteFees(key.toId(), sender, rewardCurrency, info, basisAmount);
        return (
            IHooks.beforeSwap.selector,
            toBeforeSwapDelta(feeAmount.toInt128(), 0),
            0
        );
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override nonReentrant returns (bytes4, int128) {
        IRobinhoodDividendFeeHelper.SwapFeeInfo memory info =
            dividendFeeHelper.getSwapFeeInfo(key.toId());
        Currency rewardCurrency = Currency.wrap(info.rewardToken);
        (Currency unspecified, uint256 basisAmount) =
            _unspecifiedCurrencyAndAmount(key, params, delta);
        if (!(unspecified == rewardCurrency) || basisAmount == 0) {
            return (IHooks.afterSwap.selector, 0);
        }

        uint256 feeAmount =
            _takeAndRouteFees(key.toId(), sender, rewardCurrency, info, basisAmount);
        return (IHooks.afterSwap.selector, feeAmount.toInt128());
    }

    function _takeAndRouteFees(
        PoolId poolId,
        address sender,
        Currency rewardCurrency,
        IRobinhoodDividendFeeHelper.SwapFeeInfo memory info,
        uint256 basisAmount
    ) internal returns (uint256 totalFeeAmount) {
        uint256 totalFeePpm = uint256(info.dividendFeePpm)
            + info.creatorFeePpm
            + info.protocolFeePpm
            + info.referralFeePpm;
        if (totalFeePpm > MAX_TOTAL_FEE_PPM) {
            revert TotalFeeExceedsHookCap(
                totalFeePpm, MAX_TOTAL_FEE_PPM
            );
        }
        if (basisAmount == 0 || totalFeePpm == 0) return 0;

        address rewardToken = Currency.unwrap(rewardCurrency);
        if (rewardToken == address(0)) revert RewardCurrencyCantBeNative();

        totalFeeAmount = FullMath.mulDiv(basisAmount, totalFeePpm, MAX_HOOK_FEE);
        rewardCurrency.take(poolManager, address(this), totalFeeAmount, false);

        uint256 dividendAmount =
            FullMath.mulDiv(basisAmount, info.dividendFeePpm, MAX_HOOK_FEE);
        uint256 creatorAmount =
            FullMath.mulDiv(basisAmount, info.creatorFeePpm, MAX_HOOK_FEE);
        uint256 referralAmount =
            FullMath.mulDiv(basisAmount, info.referralFeePpm, MAX_HOOK_FEE);
        uint256 protocolAmount = totalFeeAmount
            - dividendAmount
            - creatorAmount
            - referralAmount;

        if (dividendAmount > 0) {
            IERC20(rewardToken).forceApprove(
                info.dividendController, dividendAmount
            );
            IRobinhoodDividendController(info.dividendController).deposit(
                info.tokenId, rewardToken, dividendAmount
            );
        }
        if (creatorAmount > 0) {
            IERC20(rewardToken).safeTransfer(
                info.creatorFeeRecipient, creatorAmount
            );
        }
        if (referralAmount > 0) {
            IERC20(rewardToken).safeTransfer(info.referrer, referralAmount);
        }
        if (protocolAmount > 0) {
            IERC20(rewardToken).safeTransfer(
                info.protocolFeeRecipient, protocolAmount
            );
        }

        emit PairedFeesTaken(
            poolId,
            info.tokenId,
            sender,
            rewardToken,
            basisAmount,
            dividendAmount,
            creatorAmount,
            protocolAmount,
            referralAmount
        );
    }

    function _specifiedCurrency(PoolKey calldata key, SwapParams calldata params)
        internal
        pure
        returns (Currency)
    {
        return params.zeroForOne == (params.amountSpecified < 0)
            ? key.currency0
            : key.currency1;
    }

    function _unspecifiedCurrencyAndAmount(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta
    ) internal pure returns (Currency currency, uint256 amount) {
        int128 rawAmount;
        if (params.zeroForOne == (params.amountSpecified < 0)) {
            currency = key.currency1;
            rawAmount = delta.amount1();
        } else {
            currency = key.currency0;
            rawAmount = delta.amount0();
        }

        if (rawAmount < 0) rawAmount = -rawAmount;
        amount = uint256(uint128(rawAmount));
    }

    function _absAmountSpecified(int256 amountSpecified)
        internal
        pure
        returns (uint256)
    {
        return amountSpecified < 0
            ? uint256(-amountSpecified)
            : uint256(amountSpecified);
    }

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory permissions)
    {
        permissions.beforeInitialize = true;
        permissions.beforeSwap = true;
        permissions.beforeSwapReturnDelta = true;
        permissions.afterSwap = true;
        permissions.afterSwapReturnDelta = true;
    }

    function _beforeInitialize(address sender, PoolKey calldata, uint160)
        internal
        view
        override
        returns (bytes4)
    {
        require(isDeployer[sender], "Only deployer can call this function");
        return IHooks.beforeInitialize.selector;
    }
}
