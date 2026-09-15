// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IRobinhoodNativeManagerHelper} from "./RobinhoodHelperInterfaces.sol";

/// @notice Read-only inverse curve helper for Robinhood's native-ETH launcher.
/// @dev Searches whole-token amounts because the manager only accepts buys in
/// GRANULARITY_SCALER-sized units.
contract RobinhoodNativePriceHelper {
    uint256 public constant GRANULARITY_SCALER = 1e18;

    IRobinhoodNativeManagerHelper public immutable TOKEN_MANAGER;

    error InvalidManager();
    error CurveNotConfigured();

    constructor(IRobinhoodNativeManagerHelper tokenManager_) {
        if (address(tokenManager_) == address(0) || address(tokenManager_).code.length == 0) {
            revert InvalidManager();
        }
        TOKEN_MANAGER = tokenManager_;
    }

    function calculatePurchaseAmountAndPrice(uint256 nativeAmount, uint256 tokenId)
        external
        view
        returns (uint256 tokenAmount, uint256 price)
    {
        if (nativeAmount == 0) return (0, 0);
        uint256 maximum = TOKEN_MANAGER.getMaxTokensForSale(tokenId) / GRANULARITY_SCALER;
        uint256 units = _searchExisting(nativeAmount, tokenId, maximum);
        tokenAmount = units * GRANULARITY_SCALER;
        if (units != 0) price = TOKEN_MANAGER.calculateCostWithFees(units, tokenId);
    }

    function calculatePurchaseAmountAndPriceParametric(
        uint256 nativeAmount,
        uint16 a,
        uint8 b,
        uint128 curveScaler,
        uint8 creatorFeeBasisPoints,
        uint256 tokenSplit
    ) external view returns (uint256 tokenAmount, uint256 price) {
        if (nativeAmount == 0) return (0, 0);
        uint256 allowedSupply =
            TOKEN_MANAGER.allowedTotalSupplyWithParameters(a, b, curveScaler, tokenSplit);
        if (allowedSupply == 0) revert CurveNotConfigured();
        uint256 maximum = allowedSupply * tokenSplit / 100 / GRANULARITY_SCALER;
        uint256 units = _searchParametric(
            nativeAmount,
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
        uint16 a,
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
        uint16 a,
        uint8 b,
        uint128 curveScaler,
        uint8 creatorFeeBasisPoints
    ) internal view returns (uint256) {
        return TOKEN_MANAGER.calculateInitialBuyCostScaledParametricWithFees(
            amount, 0, a, b, curveScaler, creatorFeeBasisPoints
        );
    }
}
