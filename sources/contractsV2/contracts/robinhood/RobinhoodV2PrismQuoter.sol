// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    IRobinhoodV2FeeHelperQuote,
    IRobinhoodV2PrismManager,
    IRobinhoodV2PrismRegistry
} from "./interfaces/IRobinhoodV2Periphery.sol";
import {RobinhoodV2PrismPriceHelper} from "./RobinhoodV2PrismPriceHelper.sol";
import {RobinhoodV2InitialPoolQuote} from "./libraries/RobinhoodV2InitialPoolQuote.sol";

/// @notice Quotes V2 Prism creation, graduation, and the first pool purchase.
contract RobinhoodV2PrismQuoter {
    struct QuoteParams {
        address manager;
        address priceHelper;
        uint32 a;
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

    IRobinhoodV2PrismRegistry public immutable REGISTRY;

    error InvalidDependency();
    error InvalidPredictedToken();
    error ManagerNotApproved();
    error PriceHelperMismatch();
    error CurveNotConfigured();

    constructor(IRobinhoodV2PrismRegistry registry_) {
        if (
            address(registry_) == address(0)
                || address(registry_).code.length == 0
        ) revert InvalidDependency();
        REGISTRY = registry_;
    }

    function quoteCreation(QuoteParams calldata params)
        external
        view
        returns (QuoteResult memory quote)
    {
        if (!REGISTRY.isApprovedManager(params.manager)) {
            revert ManagerNotApproved();
        }
        if (params.predictedToken == address(0)) revert InvalidPredictedToken();
        if (
            address(RobinhoodV2PrismPriceHelper(params.priceHelper).TOKEN_MANAGER())
                != params.manager
        ) revert PriceHelperMismatch();

        IRobinhoodV2PrismManager manager =
            IRobinhoodV2PrismManager(params.manager);
        uint256 allowedSupply = manager.allowedTotalSupplyWithParameters(
            params.a, params.b, params.curveScaler, params.tokenSplit
        );
        if (allowedSupply == 0) revert CurveNotConfigured();

        uint256 amountToBond = allowedSupply * params.tokenSplit / 100;
        quote.preBondCost =
            manager.calculateInitialBuyCostScaledParametricWithFees(
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
                RobinhoodV2PrismPriceHelper(params.priceHelper)
                    .calculatePurchaseAmountAndPriceParametric(
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
                    manager,
                    params,
                    allowedSupply,
                    amountToBond,
                    quote.postBondCost
                );
        }
        quote.totalTokenOut = quote.preBondTokenOut + quote.postBondTokenOut;
    }

    function _quotePostBond(
        IRobinhoodV2PrismManager manager,
        QuoteParams calldata params,
        uint256 allowedSupply,
        uint256 amountToBond,
        uint256 postBondCost
    ) internal view returns (uint256 tokenOut, uint256 pairedTokenConsumed) {
        IRobinhoodV2PrismManager.V4PoolInitParams memory config =
            manager.getV4PoolInitParams();
        IRobinhoodV2FeeHelperQuote.ProtocolFeeSettings memory protocol =
            IRobinhoodV2FeeHelperQuote(manager.dividendFeeHelper())
                .getProtocolFeeSettings();
        uint256 specifiedFeePpm =
            uint256(params.dividendFeeBasisPoints) * 100;
        uint256 unspecifiedFeePpm = uint256(params.creatorFeeBasisPoints) * 100
            + protocol.protocolFeePpm + protocol.referralFeePpm;

        return RobinhoodV2InitialPoolQuote.quote(
            RobinhoodV2InitialPoolQuote.QuoteParams({
                pairedToken: manager.PAIR_TOKEN(),
                launchToken: params.predictedToken,
                tokenAmountToLp: allowedSupply * (100 - params.tokenSplit) / 100,
                pairedTokenAmountToLp: manager.calculateCostScaledParametric(
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
