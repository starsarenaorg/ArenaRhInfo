// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IArenaFeeHelperMinimal} from "../robinhood/interfaces/IArenaFeeHelperMinimal.sol";
import {IArenaPoolDeployer} from "../robinhood/interfaces/IArenaPoolDeployer.sol";
import {ArenaLiquidityAmounts} from "../robinhood/libraries/ArenaLiquidityAmounts.sol";
import {
    IRobinhoodArenaManagerHelper,
    IRobinhoodNativeManagerHelper
} from "./RobinhoodHelperInterfaces.sol";
import {RobinhoodArenaPairPriceHelper} from "./RobinhoodArenaPairPriceHelper.sol";
import {RobinhoodNativePriceHelper} from "./RobinhoodNativePriceHelper.sol";

/// @notice Pre-deployment quoter for a launch that crosses the bonding threshold
/// and spends its remaining paired currency in the newly initialized v4 pool.
contract RobinhoodSingleTxQuoter {
    using PoolIdLibrary for PoolKey;

    uint256 public constant GRANULARITY_SCALER = 1e18;
    uint256 public constant FEE_DENOMINATOR = 1e6;

    struct NativeQuoteParams {
        uint16 a;
        uint8 b;
        uint128 curveScaler;
        uint8 creatorFeeBasisPoints;
        uint256 tokenSplit;
        bool enableHolderRewards;
        uint256 amountIn;
        address predictedToken;
    }

    struct ArenaQuoteParams {
        uint32 a;
        uint8 b;
        uint128 curveScaler;
        uint8 creatorFeeBasisPoints;
        uint256 tokenSplit;
        bool enableHolderRewards;
        uint256 amountIn;
        address predictedToken;
    }

    struct QuoteResult {
        uint256 preBondTokenOut;
        uint256 preBondCost;
        uint256 postBondTokenOut;
        uint256 postBondCost;
        uint256 postBondInputConsumed;
        uint256 totalTokenOut;
        bool tokenBonds;
    }

    struct PostBondQuoteParams {
        address pairedToken;
        address launchToken;
        uint256 tokenAmountToLp;
        uint256 pairedTokenAmountToLp;
        uint256 pairedTokenAmountIn;
        IArenaPoolDeployer.PoolInitParams config;
        uint16 creatorFeePpm;
        uint160 invertedStartingPrice;
    }

    IRobinhoodNativeManagerHelper public immutable NATIVE_MANAGER;
    IRobinhoodArenaManagerHelper public immutable ARENA_MANAGER;
    RobinhoodNativePriceHelper public immutable NATIVE_PRICE_HELPER;
    RobinhoodArenaPairPriceHelper public immutable ARENA_PRICE_HELPER;
    IArenaFeeHelperMinimal public immutable FEE_HELPER;

    error InvalidDependency();
    error InvalidPredictedToken();
    error InvalidPoolConfiguration();
    error InvalidQuoteAmount();

    constructor(
        IRobinhoodNativeManagerHelper nativeManager_,
        IRobinhoodArenaManagerHelper arenaManager_,
        RobinhoodNativePriceHelper nativePriceHelper_,
        RobinhoodArenaPairPriceHelper arenaPriceHelper_,
        IArenaFeeHelperMinimal feeHelper_
    ) {
        if (
            address(nativeManager_) == address(0)
                || address(arenaManager_) == address(0)
                || address(nativePriceHelper_) == address(0)
                || address(arenaPriceHelper_) == address(0)
                || address(feeHelper_) == address(0)
        ) revert InvalidDependency();
        NATIVE_MANAGER = nativeManager_;
        ARENA_MANAGER = arenaManager_;
        NATIVE_PRICE_HELPER = nativePriceHelper_;
        ARENA_PRICE_HELPER = arenaPriceHelper_;
        FEE_HELPER = feeHelper_;
    }

    function quoteNativeCreation(NativeQuoteParams calldata params)
        external
        view
        returns (QuoteResult memory quote)
    {
        _validatePredictedToken(params.predictedToken);
        uint256 allowedSupply = NATIVE_MANAGER.allowedTotalSupplyWithParameters(
            params.a, params.b, params.curveScaler, params.tokenSplit
        );
        if (allowedSupply == 0) revert InvalidQuoteAmount();
        uint256 amountToBond = allowedSupply * params.tokenSplit / 100;
        quote.preBondCost =
            NATIVE_MANAGER.calculateInitialBuyCostScaledParametricWithFees(
                amountToBond,
                0,
                params.a,
                params.b,
                params.curveScaler,
                params.creatorFeeBasisPoints
            );
        if (params.amountIn < quote.preBondCost) {
            (quote.preBondTokenOut, quote.preBondCost) =
                NATIVE_PRICE_HELPER.calculatePurchaseAmountAndPriceParametric(
                    params.amountIn,
                    params.a,
                    params.b,
                    params.curveScaler,
                    params.creatorFeeBasisPoints,
                    params.tokenSplit
                );
            quote.totalTokenOut = quote.preBondTokenOut;
            return quote;
        }

        quote.preBondTokenOut = amountToBond;
        quote.tokenBonds = true;
        quote.postBondCost = params.amountIn - quote.preBondCost;
        if (quote.postBondCost != 0) {
            IRobinhoodNativeManagerHelper.V4PoolInitParams memory config =
                NATIVE_MANAGER.getV4PoolInitParams();
            (quote.postBondTokenOut, quote.postBondInputConsumed) = _quotePostBond(
                PostBondQuoteParams({
                    pairedToken: NATIVE_MANAGER.WETH_ADDRESS(),
                    launchToken: params.predictedToken,
                    tokenAmountToLp: _tokenAmountToLp(
                        allowedSupply, params.tokenSplit, params.enableHolderRewards
                    ),
                    pairedTokenAmountToLp: NATIVE_MANAGER.calculateCostScaledParametric(
                        amountToBond, 0, params.a, params.b, params.curveScaler
                    ),
                    pairedTokenAmountIn: quote.postBondCost,
                    config: config.poolInitParams,
                    creatorFeePpm: config.creatorFeePpm,
                    invertedStartingPrice: config.invertedStartingPrice
                })
            );
        }
        quote.totalTokenOut = quote.preBondTokenOut + quote.postBondTokenOut;
    }

    function quoteArenaCreation(ArenaQuoteParams calldata params)
        external
        view
        returns (QuoteResult memory quote)
    {
        _validatePredictedToken(params.predictedToken);
        uint256 allowedSupply = ARENA_MANAGER.allowedTotalSupplyWithParameters(
            params.a, params.b, params.curveScaler, params.tokenSplit
        );
        if (allowedSupply == 0) revert InvalidQuoteAmount();
        uint256 amountToBond = allowedSupply * params.tokenSplit / 100;
        quote.preBondCost = ARENA_MANAGER.calculateCostScaledParametricWithFees(
            amountToBond,
            0,
            params.a,
            params.b,
            params.curveScaler,
            params.creatorFeeBasisPoints
        ) + ARENA_MANAGER.tokenCreationBuyFeeAmount();
        if (params.amountIn < quote.preBondCost) {
            (quote.preBondTokenOut, quote.preBondCost) =
                ARENA_PRICE_HELPER.calculatePurchaseAmountAndPriceParametric(
                    params.amountIn,
                    params.a,
                    params.b,
                    params.curveScaler,
                    params.creatorFeeBasisPoints,
                    params.tokenSplit
                );
            quote.totalTokenOut = quote.preBondTokenOut;
            return quote;
        }

        quote.preBondTokenOut = amountToBond;
        quote.tokenBonds = true;
        quote.postBondCost = params.amountIn - quote.preBondCost;
        if (quote.postBondCost != 0) {
            IRobinhoodArenaManagerHelper.V4PoolInitParams memory config =
                ARENA_MANAGER.getV4PoolInitParams();
            (quote.postBondTokenOut, quote.postBondInputConsumed) = _quotePostBond(
                PostBondQuoteParams({
                    pairedToken: ARENA_MANAGER.ARENA_ADDRESS(),
                    launchToken: params.predictedToken,
                    tokenAmountToLp: _tokenAmountToLp(
                        allowedSupply, params.tokenSplit, params.enableHolderRewards
                    ),
                    pairedTokenAmountToLp: ARENA_MANAGER.calculateCostScaledParametric(
                        amountToBond, 0, params.a, params.b, params.curveScaler
                    ),
                    pairedTokenAmountIn: quote.postBondCost,
                    config: config.poolInitParams,
                    creatorFeePpm: config.creatorFeePpm,
                    invertedStartingPrice: config.invertedStartingPrice
                })
            );
        }
        quote.totalTokenOut = quote.preBondTokenOut + quote.postBondTokenOut;
    }

    function quotePostBond(PostBondQuoteParams calldata params)
        external
        view
        returns (uint256 tokenOut, uint256 pairedTokenConsumed)
    {
        return _quotePostBond(params);
    }

    function _quotePostBond(PostBondQuoteParams memory params)
        internal
        view
        returns (uint256 tokenOut, uint256 pairedTokenConsumed)
    {
        if (
            params.pairedToken == address(0) || params.launchToken == address(0)
                || params.pairedToken == params.launchToken
                || params.pairedTokenAmountIn == 0
        ) revert InvalidQuoteAmount();
        bool pairedIsToken0 = params.pairedToken < params.launchToken;
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(pairedIsToken0 ? params.pairedToken : params.launchToken),
            currency1: Currency.wrap(pairedIsToken0 ? params.launchToken : params.pairedToken),
            fee: params.config.fee,
            tickSpacing: params.config.tickSpacing,
            hooks: IHooks(params.config.hookContract)
        });

        uint160 startingPrice =
            pairedIsToken0 ? params.config.startingPrice : params.invertedStartingPrice;
        int24 tickLower = pairedIsToken0
            ? _snap(params.config.tickLower, params.config.tickSpacing)
            : _snap(-params.config.tickUpper, params.config.tickSpacing);
        int24 tickUpper = pairedIsToken0
            ? _snap(params.config.tickUpper, params.config.tickSpacing)
            : _snap(-params.config.tickLower, params.config.tickSpacing);
        if (
            params.config.tickSpacing <= 0 || tickLower >= tickUpper
                || startingPrice <= TickMath.getSqrtPriceAtTick(tickLower)
                || startingPrice >= TickMath.getSqrtPriceAtTick(tickUpper)
        ) revert InvalidPoolConfiguration();

        uint128 liquidity = ArenaLiquidityAmounts.getLiquidityForAmounts(
            startingPrice,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            pairedIsToken0 ? params.pairedTokenAmountToLp : params.tokenAmountToLp,
            pairedIsToken0 ? params.tokenAmountToLp : params.pairedTokenAmountToLp
        );
        if (liquidity == 0 || params.pairedTokenAmountIn > uint256(type(int256).max)) {
            revert InvalidPoolConfiguration();
        }

        uint160 targetPrice = pairedIsToken0
            ? TickMath.getSqrtPriceAtTick(tickLower)
            : TickMath.getSqrtPriceAtTick(tickUpper);
        (, uint256 amountInNet, uint256 grossTokenOut, uint256 lpFeeAmount) =
            SwapMath.computeSwapStep(
                startingPrice,
                targetPrice,
                liquidity,
                -int256(params.pairedTokenAmountIn),
                params.config.fee
            );
        pairedTokenConsumed = amountInNet + lpFeeAmount;
        uint256 hookFeePpm =
            FEE_HELPER.getTotalFeePpm(key.toId()) + params.creatorFeePpm;
        if (hookFeePpm >= FEE_DENOMINATOR) revert InvalidPoolConfiguration();
        tokenOut = grossTokenOut - grossTokenOut * hookFeePpm / FEE_DENOMINATOR;
    }

    function _tokenAmountToLp(
        uint256 allowedSupply,
        uint256 tokenSplit,
        bool
    )
        internal
        pure
        returns (uint256)
    {
        return allowedSupply * (100 - tokenSplit) / 100;
    }

    function _validatePredictedToken(address predictedToken) internal pure {
        if (predictedToken == address(0)) revert InvalidPredictedToken();
    }

    function _snap(int24 tick, int24 spacing) internal pure returns (int24) {
        return (tick / spacing) * spacing;
    }
}
