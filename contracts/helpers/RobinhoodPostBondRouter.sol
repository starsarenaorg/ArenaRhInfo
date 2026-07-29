// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {
    IRobinhoodHelperPermit2,
    IRobinhoodHelperUniversalRouter,
    IRobinhoodHelperWETH
} from "./RobinhoodHelperInterfaces.sol";
import {RobinhoodV4SwapExecutor} from "./RobinhoodV4SwapExecutor.sol";

/// @notice User-facing exact-input router for graduated Robinhood launch pools.
/// @dev Handles native ETH wrapping/unwrapping while retaining wARENA as ERC20.
contract RobinhoodPostBondRouter is RobinhoodV4SwapExecutor, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IRobinhoodHelperWETH public immutable WETH;

    struct ExactOutputRequest {
        PoolKey key;
        bool zeroForOne;
        uint128 amountOut;
        uint128 maxAmountIn;
        address recipient;
        bool nativeIn;
        bool nativeOut;
        uint256 minHopPriceX36;
        bytes hookData;
        uint256 deadline;
    }

    error InvalidRecipient();
    error InvalidNativeValue();
    error InvalidNativeRoute();
    error NativeTransferFailed();

    event PostBondSwap(
        address indexed sender,
        address indexed recipient,
        address indexed input,
        address output,
        uint256 amountIn,
        uint256 amountOut,
        bool nativeIn,
        bool nativeOut
    );

    event PostBondExactOutputSwap(
        address indexed sender,
        address indexed recipient,
        address indexed input,
        address output,
        uint256 amountIn,
        uint256 amountOut,
        bool nativeIn,
        bool nativeOut
    );

    constructor(
        IRobinhoodHelperUniversalRouter universalRouter_,
        IRobinhoodHelperPermit2 permit2_,
        IRobinhoodHelperWETH weth_
    ) RobinhoodV4SwapExecutor(universalRouter_, permit2_) {
        if (address(weth_) == address(0) || address(weth_).code.length == 0) {
            revert InvalidSwapDependency();
        }
        WETH = weth_;
    }

    function swapExactInput(
        PoolKey calldata key,
        bool zeroForOne,
        uint128 amountIn,
        uint128 minAmountOut,
        address recipient,
        bool nativeIn,
        bool nativeOut,
        uint256 deadline
    ) external payable nonReentrant returns (uint256 amountOut) {
        return _swapExactInput(
            key, zeroForOne, amountIn, minAmountOut, recipient, nativeIn,
            nativeOut, 0, bytes(""), deadline
        );
    }

    function swapExactInputAdvanced(
        PoolKey calldata key,
        bool zeroForOne,
        uint128 amountIn,
        uint128 minAmountOut,
        address recipient,
        bool nativeIn,
        bool nativeOut,
        uint256 minHopPriceX36,
        bytes calldata hookData,
        uint256 deadline
    ) external payable nonReentrant returns (uint256 amountOut) {
        return _swapExactInput(
            key, zeroForOne, amountIn, minAmountOut, recipient, nativeIn,
            nativeOut, minHopPriceX36, hookData, deadline
        );
    }

    function _swapExactInput(
        PoolKey calldata key,
        bool zeroForOne,
        uint128 amountIn,
        uint128 minAmountOut,
        address recipient,
        bool nativeIn,
        bool nativeOut,
        uint256 minHopPriceX36,
        bytes memory hookData,
        uint256 deadline
    ) internal returns (uint256 amountOut) {
        if (recipient == address(0)) revert InvalidRecipient();
        address input = Currency.unwrap(zeroForOne ? key.currency0 : key.currency1);
        address output = Currency.unwrap(zeroForOne ? key.currency1 : key.currency0);

        if (nativeIn) {
            if (input != address(WETH)) revert InvalidNativeRoute();
            if (msg.value != amountIn) revert InvalidNativeValue();
            WETH.deposit{value: amountIn}();
        } else {
            if (msg.value != 0) revert InvalidNativeValue();
            IERC20(input).safeTransferFrom(msg.sender, address(this), amountIn);
        }
        if (nativeOut && output != address(WETH)) revert InvalidNativeRoute();

        amountOut = _swapExactInputSingle(
            key, zeroForOne, amountIn, minAmountOut, minHopPriceX36,
            hookData, deadline
        );
        if (nativeOut) {
            WETH.withdraw(amountOut);
            (bool success,) = payable(recipient).call{value: amountOut}("");
            if (!success) revert NativeTransferFailed();
        } else {
            IERC20(output).safeTransfer(recipient, amountOut);
        }

        emit PostBondSwap(
            msg.sender,
            recipient,
            input,
            output,
            amountIn,
            amountOut,
            nativeIn,
            nativeOut
        );
    }

    function swapExactOutput(ExactOutputRequest calldata request)
        external
        payable
        nonReentrant
        returns (uint256 amountIn)
    {
        if (request.recipient == address(0)) revert InvalidRecipient();
        address input = Currency.unwrap(
            request.zeroForOne ? request.key.currency0 : request.key.currency1
        );
        address output = Currency.unwrap(
            request.zeroForOne ? request.key.currency1 : request.key.currency0
        );

        if (request.nativeIn) {
            if (input != address(WETH)) revert InvalidNativeRoute();
            if (msg.value != request.maxAmountIn) revert InvalidNativeValue();
            WETH.deposit{value: request.maxAmountIn}();
        } else {
            if (msg.value != 0) revert InvalidNativeValue();
            IERC20(input).safeTransferFrom(
                msg.sender, address(this), request.maxAmountIn
            );
        }
        if (request.nativeOut && output != address(WETH)) revert InvalidNativeRoute();

        amountIn = _swapExactOutputSingle(
            RobinhoodExactOutputSingleParams({
                poolKey: request.key,
                zeroForOne: request.zeroForOne,
                amountOut: request.amountOut,
                amountInMaximum: request.maxAmountIn,
                minHopPriceX36: request.minHopPriceX36,
                hookData: request.hookData
            }),
            request.deadline
        );

        uint256 refund = uint256(request.maxAmountIn) - amountIn;
        if (request.nativeIn) {
            if (refund != 0) {
                WETH.withdraw(refund);
                (bool refundSuccess,) = payable(msg.sender).call{value: refund}("");
                if (!refundSuccess) revert NativeTransferFailed();
            }
        } else if (refund != 0) {
            IERC20(input).safeTransfer(msg.sender, refund);
        }

        if (request.nativeOut) {
            WETH.withdraw(request.amountOut);
            (bool success,) = payable(request.recipient).call{value: request.amountOut}("");
            if (!success) revert NativeTransferFailed();
        } else {
            IERC20(output).safeTransfer(request.recipient, request.amountOut);
        }

        emit PostBondExactOutputSwap(
            msg.sender, request.recipient, input, output, amountIn,
            request.amountOut, request.nativeIn, request.nativeOut
        );
    }
}
