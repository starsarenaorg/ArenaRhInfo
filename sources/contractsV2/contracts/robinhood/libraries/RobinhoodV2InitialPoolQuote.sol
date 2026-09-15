// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {IArenaPoolDeployer} from "../../../../contracts/contracts/robinhood/interfaces/IArenaPoolDeployer.sol";
import {ArenaLiquidityAmounts} from "../../../../contracts/contracts/robinhood/libraries/ArenaLiquidityAmounts.sol";

/// @notice Simulates the first exact-input buy against a not-yet-created V2 pool.
library RobinhoodV2InitialPoolQuote {
    uint256 internal constant FEE_DENOMINATOR = 1_000_000;

    struct QuoteParams {
        address pairedToken;
        address launchToken;
        uint256 tokenAmountToLp;
        uint256 pairedTokenAmountToLp;
        uint256 pairedTokenAmountIn;
        IArenaPoolDeployer.PoolInitParams config;
        uint160 invertedStartingPrice;
        uint256 specifiedFeePpm;
        uint256 unspecifiedFeePpm;
    }

    error InvalidPoolConfiguration();
    error InvalidQuoteAmount();

    function quote(QuoteParams memory params)
        internal
        pure
        returns (uint256 tokenOut, uint256 pairedTokenConsumed)
    {
        if (
            params.pairedToken == address(0) || params.launchToken == address(0)
                || params.pairedToken == params.launchToken
                || params.pairedTokenAmountIn == 0
        ) revert InvalidQuoteAmount();
        if (
            params.config.tickSpacing <= 0
                || params.config.fee >= FEE_DENOMINATOR
                || params.specifiedFeePpm >= FEE_DENOMINATOR
                || params.unspecifiedFeePpm >= FEE_DENOMINATOR
                || params.specifiedFeePpm + params.unspecifiedFeePpm
                    >= FEE_DENOMINATOR
        ) revert InvalidPoolConfiguration();

        bool pairedIsToken0 = params.pairedToken < params.launchToken;
        uint160 startingPrice = pairedIsToken0
            ? params.config.startingPrice
            : params.invertedStartingPrice;
        int24 tickLower = pairedIsToken0
            ? _snap(params.config.tickLower, params.config.tickSpacing)
            : _snap(-params.config.tickUpper, params.config.tickSpacing);
        int24 tickUpper = pairedIsToken0
            ? _snap(params.config.tickUpper, params.config.tickSpacing)
            : _snap(-params.config.tickLower, params.config.tickSpacing);
        if (
            tickLower >= tickUpper
                || startingPrice <= TickMath.getSqrtPriceAtTick(tickLower)
                || startingPrice >= TickMath.getSqrtPriceAtTick(tickUpper)
        ) revert InvalidPoolConfiguration();

        uint128 liquidity = ArenaLiquidityAmounts.getLiquidityForAmounts(
            startingPrice,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            pairedIsToken0
                ? params.pairedTokenAmountToLp
                : params.tokenAmountToLp,
            pairedIsToken0
                ? params.tokenAmountToLp
                : params.pairedTokenAmountToLp
        );
        if (liquidity == 0) revert InvalidPoolConfiguration();

        uint256 specifiedFee = FullMath.mulDiv(
            params.pairedTokenAmountIn,
            params.specifiedFeePpm,
            FEE_DENOMINATOR
        );
        uint256 poolInput = params.pairedTokenAmountIn - specifiedFee;
        if (poolInput == 0 || poolInput > uint256(type(int256).max)) {
            revert InvalidQuoteAmount();
        }

        uint160 targetPrice = pairedIsToken0
            ? TickMath.getSqrtPriceAtTick(tickLower)
            : TickMath.getSqrtPriceAtTick(tickUpper);
        (, uint256 amountInNet, uint256 amountOut, uint256 lpFeeAmount) =
            SwapMath.computeSwapStep(
                startingPrice,
                targetPrice,
                liquidity,
                -int256(poolInput),
                params.config.fee
            );

        uint256 unspecifiedFee = FullMath.mulDiv(
            amountOut, params.unspecifiedFeePpm, FEE_DENOMINATOR
        );
        tokenOut = amountOut - unspecifiedFee;
        pairedTokenConsumed = specifiedFee + amountInNet + lpFeeAmount;
    }

    function _snap(int24 tick, int24 spacing) private pure returns (int24) {
        return (tick / spacing) * spacing;
    }
}
