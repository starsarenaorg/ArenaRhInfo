// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    IRobinhoodV2FeeHelperQuote,
    IRobinhoodV2NativeManager
} from "./interfaces/IRobinhoodV2Periphery.sol";
import {RobinhoodV2NativePriceHelper} from "./RobinhoodV2NativePriceHelper.sol";
import {RobinhoodV2InitialPoolQuote} from "./libraries/RobinhoodV2InitialPoolQuote.sol";

/// @notice Quotes V2 native creation, graduation, and the first pool purchase.
contract RobinhoodV2NativeQuoter {
    struct QuoteParams {
        uint16 a;
        uint8 b;
        uint128 curveScaler;
        uint8 creatorFeeBasisPoints;
        uint16 dividendFeeBasisPoints;
        uint256 tokenSplit;
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

    IRobinhoodV2NativeManager public immutable TOKEN_MANAGER;
    RobinhoodV2NativePriceHelper public immutable PRICE_HELPER;

    error InvalidDependency();
    error InvalidPredictedToken();
    error PriceHelperMismatch();
    error CurveNotConfigured();

    constructor(
        IRobinhoodV2NativeManager tokenManager_,
        RobinhoodV2NativePriceHelper priceHelper_
    ) {
        if (
            address(tokenManager_) == address(0)
                || address(tokenManager_).code.length == 0
                || address(priceHelper_) == address(0)
                || address(priceHelper_).code.length == 0
        ) revert InvalidDependency();
        if (address(priceHelper_.TOKEN_MANAGER()) != address(tokenManager_)) {
            revert PriceHelperMismatch();
        }
        TOKEN_MANAGER = tokenManager_;
        PRICE_HELPER = priceHelper_;
    }

    function quoteCreation(QuoteParams calldata params)
        external
        view
        returns (QuoteResult memory quote)
    {
        if (params.predictedToken == address(0)) revert InvalidPredictedToken();
        uint256 allowedSupply = TOKEN_MANAGER.allowedTotalSupplyWithParameters(
            params.a, params.b, params.curveScaler, params.tokenSplit
        );
        if (allowedSupply == 0) revert CurveNotConfigured();

        uint256 amountToBond = allowedSupply * params.tokenSplit / 100;
        quote.preBondCost =
            TOKEN_MANAGER.calculateInitialBuyCostScaledParametricWithFees(
                amountToBond,
                0,
                params.a,
                params.b,
                params.curveScaler,
                params.creatorFeeBasisPoints,
                params.dividendFeeBasisPoints
            );
        if (params.amountIn < quote.preBondCost) {
            (quote.preBondTokenOut, quote.preBondCost) =
                PRICE_HELPER.calculatePurchaseAmountAndPriceParametric(
                    params.amountIn,
                    params.a,
                    params.b,
                    params.curveScaler,
                    params.creatorFeeBasisPoints,
                    params.dividendFeeBasisPoints,
                    params.tokenSplit
                );
            quote.totalTokenOut = quote.preBondTokenOut;
            return quote;
        }

        quote.preBondTokenOut = amountToBond;
        quote.tokenBonds = true;
        quote.postBondCost = params.amountIn - quote.preBondCost;
        if (quote.postBondCost != 0) {
            (quote.postBondTokenOut, quote.postBondInputConsumed) =
                _quotePostBond(
                    params,
                    allowedSupply,
                    amountToBond,
                    quote.postBondCost
                );
        }
        quote.totalTokenOut = quote.preBondTokenOut + quote.postBondTokenOut;
    }

    function _quotePostBond(
        QuoteParams calldata params,
        uint256 allowedSupply,
        uint256 amountToBond,
        uint256 postBondCost
    ) internal view returns (uint256 tokenOut, uint256 pairedTokenConsumed) {
        IRobinhoodV2NativeManager.V4PoolInitParams memory config =
            TOKEN_MANAGER.getV4PoolInitParams();
        IRobinhoodV2FeeHelperQuote.ProtocolFeeSettings memory protocol =
            IRobinhoodV2FeeHelperQuote(TOKEN_MANAGER.dividendFeeHelper())
                .getProtocolFeeSettings();
        uint256 specifiedFeePpm =
            uint256(params.dividendFeeBasisPoints) * 100;
        uint256 unspecifiedFeePpm = uint256(params.creatorFeeBasisPoints) * 100
            + protocol.protocolFeePpm + protocol.referralFeePpm;

        return RobinhoodV2InitialPoolQuote.quote(
            RobinhoodV2InitialPoolQuote.QuoteParams({
                pairedToken: TOKEN_MANAGER.WETH_ADDRESS(),
                launchToken: params.predictedToken,
                tokenAmountToLp: allowedSupply * (100 - params.tokenSplit) / 100,
                pairedTokenAmountToLp: TOKEN_MANAGER.calculateCostScaledParametric(
                    amountToBond,
                    0,
                    params.a,
                    params.b,
                    params.curveScaler
                ),
                pairedTokenAmountIn: postBondCost,
                config: config.poolInitParams,
                invertedStartingPrice: config.invertedStartingPrice,
                specifiedFeePpm: specifiedFeePpm,
                unspecifiedFeePpm: unspecifiedFeePpm
            })
        );
    }
}
