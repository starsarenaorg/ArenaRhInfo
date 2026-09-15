// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";

import {RobinhoodCurrencySettler} from "./RobinhoodCurrencySettler.sol";

/// @notice Base fee-hook behavior used by Robinhood launch pools.
abstract contract RobinhoodBaseHookFee is BaseHook {
    using PoolIdLibrary for PoolKey;
    using RobinhoodCurrencySettler for Currency;
    using SafeCast for *;

    error HookFeeTooLarge();

    uint24 internal constant MAX_HOOK_FEE = 1e6;

    event HookFee(
        bytes32 indexed poolId,
        address indexed sender,
        uint128 amount0,
        uint128 amount1
    );
    event HookSwap(
        bytes32 indexed poolId,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint128 hookLPfeeAmount0,
        uint128 hookLPfeeAmount1
    );
    event HookModifyLiquidity(
        bytes32 indexed poolId,
        address indexed sender,
        int128 amount0,
        int128 amount1
    );
    event HookBonus(bytes32 indexed poolId, uint128 amount0, uint128 amount1);

    function _getHookFee(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal view virtual returns (uint24 fee);

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal virtual override returns (bytes4, int128) {
        (Currency unspecified, int128 unspecifiedAmount) =
            (params.amountSpecified < 0 == params.zeroForOne)
                ? (key.currency1, delta.amount1())
                : (key.currency0, delta.amount0());

        if (unspecifiedAmount == 0) return (this.afterSwap.selector, 0);
        if (unspecifiedAmount < 0) unspecifiedAmount = -unspecifiedAmount;

        uint24 hookFee = _getHookFee(sender, key, params, delta, hookData);
        if (hookFee == 0) return (this.afterSwap.selector, 0);
        if (hookFee > MAX_HOOK_FEE) revert HookFeeTooLarge();

        uint256 feeAmount = FullMath.mulDiv(
            uint256(unspecifiedAmount.toUint128()), hookFee, MAX_HOOK_FEE
        );
        unspecified.take(poolManager, address(this), feeAmount, true);

        if (unspecified == key.currency0) {
            emit HookFee(
                PoolId.unwrap(key.toId()),
                sender,
                feeAmount.toUint128(),
                0
            );
        } else {
            emit HookFee(
                PoolId.unwrap(key.toId()),
                sender,
                0,
                feeAmount.toUint128()
            );
        }

        return (this.afterSwap.selector, feeAmount.toInt128());
    }

    function handleHookFees(Currency[] memory currencies) public virtual;

    function getHookPermissions()
        public
        pure
        virtual
        override
        returns (Hooks.Permissions memory permissions)
    {
        permissions.afterSwap = true;
        permissions.afterSwapReturnDelta = true;
    }
}
