// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IRobinhoodArenaManagerHelper} from "./RobinhoodHelperInterfaces.sol";

/// @notice Read-only inverse curve helper for Robinhood's wARENA-paired launcher.
contract RobinhoodArenaPairPriceHelper {
    uint256 public constant GRANULARITY_SCALER = 1e18;

    IRobinhoodArenaManagerHelper public immutable TOKEN_MANAGER;

    error InvalidManager();
    error CurveNotConfigured();

    constructor(IRobinhoodArenaManagerHelper tokenManager_) {
        if (address(tokenManager_) == address(0) || address(tokenManager_).code.length == 0) {
            revert InvalidManager();
        }
        TOKEN_MANAGER = tokenManager_;
    }

    function calculatePurchaseAmountAndPrice(uint256 arenaAmount, uint256 tokenId)
        external
        view
        returns (uint256 tokenAmount, uint256 price)
    {
        if (arenaAmount == 0) return (0, 0);
        uint256 maximum = TOKEN_MANAGER.getMaxTokensForSale(tokenId) / GRANULARITY_SCALER;
        uint256 units = _searchExisting(arenaAmount, tokenId, maximum);
        tokenAmount = units * GRANULARITY_SCALER;
        if (units != 0) price = TOKEN_MANAGER.calculateCostWithFees(units, tokenId);
    }

    function calculatePurchaseAmountAndPriceParametric(
        uint256 arenaAmount,
        uint32 a,
        uint8 b,
        uint128 curveScaler,
        uint8 creatorFeeBasisPoints,
        uint256 tokenSplit
    ) external view returns (uint256 tokenAmount, uint256 price) {
        if (arenaAmount == 0) return (0, 0);
        uint256 allowedSupply =
            TOKEN_MANAGER.allowedTotalSupplyWithParameters(a, b, curveScaler, tokenSplit);
        if (allowedSupply == 0) revert CurveNotConfigured();
        uint256 maximum = allowedSupply * tokenSplit / 100 / GRANULARITY_SCALER;
        uint256 units = _searchParametric(
            arenaAmount,
            a,
            b,
            curveScaler,
            creatorFeeBasisPoints,
            maximum
        );
        tokenAmount = units * GRANULARITY_SCALER;
        if (units != 0) {
            price = _initialCost(
                tokenAmount, a, b, curveScaler, creatorFeeBasisPoints
            );
        }
    }

    function calculateRewardWithFeesInArena(uint256 sellAmount, uint256 tokenId)
        external
        view
        returns (uint256)
    {
        return TOKEN_MANAGER.calculateRewardWithFees(
            sellAmount / GRANULARITY_SCALER, tokenId
        );
    }

    /// @notice Reverses rounded bonding fees and the optional flat creation fee.
    function invertTotalToRaw(
        uint256 protocolFeeBasisPoints,
        uint256 referralFeeBasisPoints,
        uint256 creatorFeeBasisPoints,
        uint256 flatFee,
        uint256 totalPaid
    ) external pure returns (uint256 rawCost) {
        if (totalPaid == 0) return 0;
        require(totalPaid >= flatFee, "total below flat fee");
        uint256 sum =
            protocolFeeBasisPoints + referralFeeBasisPoints + creatorFeeBasisPoints;
        uint256 approximation = (totalPaid - flatFee) * 10_000 / (10_000 + sum);
        uint256 computed = approximation
            + (approximation * protocolFeeBasisPoints + 5_000) / 10_000
            + (approximation * referralFeeBasisPoints + 5_000) / 10_000
            + (approximation * creatorFeeBasisPoints + 5_000) / 10_000 + flatFee;
        if (computed < totalPaid) return approximation + (totalPaid - computed);
        if (computed > totalPaid) return approximation - (computed - totalPaid);
        return approximation;
    }

    function _searchExisting(uint256 budget, uint256 tokenId, uint256 high)
        internal
        view
        returns (uint256 low)
    {
        while (low < high) {
            uint256 mid = (low + high + 1) / 2;
            uint256 cost = TOKEN_MANAGER.calculateCostWithFees(mid, tokenId);
            if (cost <= budget) low = mid;
            else high = mid - 1;
        }
    }

    function _searchParametric(
        uint256 budget,
        uint32 a,
        uint8 b,
        uint128 curveScaler,
        uint8 creatorFeeBasisPoints,
        uint256 high
    ) internal view returns (uint256 low) {
        while (low < high) {
            uint256 mid = (low + high + 1) / 2;
            uint256 cost = _initialCost(
                mid * GRANULARITY_SCALER,
                a,
                b,
                curveScaler,
                creatorFeeBasisPoints
            );
            if (cost <= budget) low = mid;
            else high = mid - 1;
        }
    }

    function _initialCost(
        uint256 amount,
        uint32 a,
        uint8 b,
        uint128 curveScaler,
        uint8 creatorFeeBasisPoints
    ) internal view returns (uint256) {
        return TOKEN_MANAGER.calculateCostScaledParametricWithFees(
            amount, 0, a, b, curveScaler, creatorFeeBasisPoints
        ) + TOKEN_MANAGER.tokenCreationBuyFeeAmount();
    }
}
