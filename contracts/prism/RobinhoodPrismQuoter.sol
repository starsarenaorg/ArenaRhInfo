// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IArenaPoolDeployer} from "../robinhood/interfaces/IArenaPoolDeployer.sol";
import {IRobinhoodArenaManagerHelper} from "../helpers/RobinhoodHelperInterfaces.sol";
import {RobinhoodArenaPairPriceHelper} from "../helpers/RobinhoodArenaPairPriceHelper.sol";

interface IPrismRegistryView {
    function isApprovedManager(address manager) external view returns (bool);
}

interface IPrismPostBondQuoter {
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

    function quotePostBond(PostBondQuoteParams calldata params)
        external
        view
        returns (uint256 tokenOut, uint256 pairedTokenConsumed);
}

interface IPrismPriceHelperIdentity {
    function TOKEN_MANAGER() external view returns (IRobinhoodArenaManagerHelper);
}

/// @notice Quotes creation, graduation, and the immediate v4 buy for any
///         registry-approved Arena Prism manager.
contract RobinhoodPrismQuoter {
    uint256 private constant GRANULARITY = 1e18;

    struct QuoteParams {
        address manager;
        address priceHelper;
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

    IPrismRegistryView public immutable REGISTRY;
    IPrismPostBondQuoter public immutable POST_BOND_QUOTER;

    error ManagerNotApproved();
    error InvalidDependency();
    error PriceHelperMismatch();
    error CurveNotConfigured();

    constructor(IPrismRegistryView registry, IPrismPostBondQuoter postBondQuoter) {
        if (address(registry) == address(0) || address(postBondQuoter) == address(0)) {
            revert InvalidDependency();
        }
        REGISTRY = registry;
        POST_BOND_QUOTER = postBondQuoter;
    }

    function quoteCreation(QuoteParams calldata params)
        external
        view
        returns (QuoteResult memory quote)
    {
        if (!REGISTRY.isApprovedManager(params.manager)) revert ManagerNotApproved();
        if (
            address(IPrismPriceHelperIdentity(params.priceHelper).TOKEN_MANAGER())
                != params.manager
        ) revert PriceHelperMismatch();
        IRobinhoodArenaManagerHelper manager = IRobinhoodArenaManagerHelper(params.manager);
        uint256 allowed = manager.allowedTotalSupplyWithParameters(
            params.a, params.b, params.curveScaler, params.tokenSplit
        );
        if (allowed == 0) revert CurveNotConfigured();
        uint256 amountToBond = allowed * params.tokenSplit / 100;
        quote.preBondCost = manager.calculateCostScaledParametricWithFees(
            amountToBond, 0, params.a, params.b, params.curveScaler,
            params.creatorFeeBasisPoints
        ) + manager.tokenCreationBuyFeeAmount();
        if (params.amountIn < quote.preBondCost) {
            (quote.preBondTokenOut, quote.preBondCost) =
                RobinhoodArenaPairPriceHelper(params.priceHelper)
                    .calculatePurchaseAmountAndPriceParametric(
                        params.amountIn, params.a, params.b, params.curveScaler,
                        params.creatorFeeBasisPoints, params.tokenSplit
                    );
            quote.totalTokenOut = quote.preBondTokenOut;
            return quote;
        }
        quote.preBondTokenOut = amountToBond;
        quote.tokenBonds = true;
        quote.postBondCost = params.amountIn - quote.preBondCost;
        if (quote.postBondCost != 0) {
            (quote.postBondTokenOut, quote.postBondInputConsumed) =
                _quotePostBond(manager, params, allowed, amountToBond, quote.postBondCost);
        }
        quote.totalTokenOut = quote.preBondTokenOut + quote.postBondTokenOut;
    }

    function _quotePostBond(
        IRobinhoodArenaManagerHelper manager,
        QuoteParams calldata params,
        uint256 allowed,
        uint256 amountToBond,
        uint256 postBondCost
    ) internal view returns (uint256 tokenOut, uint256 pairedTokenConsumed) {
        uint256 tokenAmountToLp =
            allowed * (100 - params.tokenSplit) / 100;
        uint256 pairedTokenAmountToLp = manager.calculateCostScaledParametric(
            amountToBond,
            0,
            params.a,
            params.b,
            params.curveScaler
        );
        IRobinhoodArenaManagerHelper.V4PoolInitParams memory config =
            manager.getV4PoolInitParams();
        return POST_BOND_QUOTER.quotePostBond(
            IPrismPostBondQuoter.PostBondQuoteParams({
                pairedToken: manager.ARENA_ADDRESS(),
                launchToken: params.predictedToken,
                tokenAmountToLp: tokenAmountToLp,
                pairedTokenAmountToLp: pairedTokenAmountToLp,
                pairedTokenAmountIn: postBondCost,
                config: config.poolInitParams,
                creatorFeePpm: config.creatorFeePpm,
                invertedStartingPrice: config.invertedStartingPrice
            })
        );
    }
}
