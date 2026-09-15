// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {
    IRobinhoodHelperPermit2,
    IRobinhoodHelperUniversalRouter
} from "./RobinhoodHelperInterfaces.sol";

/// @notice Shared Universal Router plumbing for the Robinhood helper suite.
/// @dev The extra minHopPriceX36 field matches Robinhood's deployed Universal
/// Router encoding, which is also exercised by CreationFeeBuybackAdapter.
abstract contract RobinhoodV4SwapExecutor {
    using SafeERC20 for IERC20;

    bytes1 internal constant V4_SWAP_COMMAND = 0x10;

    /// @dev Robinhood's deployed Universal Router extends the upstream v4
    /// ExactInputSingleParams with a per-hop price guard. Because hookData is
    /// dynamic, the router expects this struct to be ABI-encoded as one tuple,
    /// including its leading offset word.
    struct RobinhoodExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    struct RobinhoodExactOutputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountOut;
        uint128 amountInMaximum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    IRobinhoodHelperUniversalRouter public immutable UNIVERSAL_ROUTER;
    IRobinhoodHelperPermit2 public immutable PERMIT2;
    IPoolManager public immutable POOL_MANAGER;

    error InvalidSwapDependency();
    error InvalidSwapAmount();
    error InvalidMinimumOutput();
    error InvalidPoolKey();
    error SwapOutputTooLow(uint256 minimum, uint256 actual);
    error SwapInputTooHigh(uint256 maximum, uint256 actual);

    constructor(
        IRobinhoodHelperUniversalRouter universalRouter_,
        IRobinhoodHelperPermit2 permit2_
    ) {
        if (
            address(universalRouter_) == address(0)
                || address(universalRouter_).code.length == 0
                || address(permit2_) == address(0)
                || address(permit2_).code.length == 0
        ) revert InvalidSwapDependency();
        address poolManager = universalRouter_.poolManager();
        if (poolManager == address(0)) revert InvalidSwapDependency();
        UNIVERSAL_ROUTER = universalRouter_;
        PERMIT2 = permit2_;
        POOL_MANAGER = IPoolManager(poolManager);
    }

    function _swapExactInputSingle(
        PoolKey memory key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline
    ) internal returns (uint256 amountOut) {
        return _swapExactInputSingle(
            key, zeroForOne, amountIn, minAmountOut, 0, bytes(""), deadline
        );
    }

    function _swapExactInputSingle(
        PoolKey memory key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 minHopPriceX36,
        bytes memory hookData,
        uint256 deadline
    ) internal returns (uint256 amountOut) {
        if (amountIn == 0 || amountIn > type(uint128).max) revert InvalidSwapAmount();
        if (minAmountOut == 0 || minAmountOut > type(uint128).max) {
            revert InvalidMinimumOutput();
        }

        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);
        if (currency0 == currency1) revert InvalidPoolKey();
        address input = zeroForOne ? currency0 : currency1;
        address output = zeroForOne ? currency1 : currency0;
        uint256 outputBefore = _currencyBalance(output);

        if (input != address(0)) _ensureRouterApproval(input, amountIn);

        bytes[] memory actionParams = new bytes[](4);
        actionParams[0] = abi.encode(
            RobinhoodExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: uint128(amountIn),
                amountOutMinimum: uint128(minAmountOut),
                minHopPriceX36: minHopPriceX36,
                hookData: hookData
            })
        );
        actionParams[1] = abi.encode(input, amountIn, true);
        actionParams[2] = abi.encode(output, minAmountOut);
        actionParams[3] = abi.encode(input, uint256(0));

        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE),
            uint8(Actions.SETTLE),
            uint8(Actions.TAKE_ALL),
            uint8(Actions.TAKE_ALL)
        );
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, actionParams);

        UNIVERSAL_ROUTER.execute{value: input == address(0) ? amountIn : 0}(
            abi.encodePacked(V4_SWAP_COMMAND), inputs, deadline
        );

        amountOut = _currencyBalance(output) - outputBefore;
        if (amountOut < minAmountOut) revert SwapOutputTooLow(minAmountOut, amountOut);
    }

    function _swapExactOutputSingle(
        RobinhoodExactOutputSingleParams memory params,
        uint256 deadline
    ) internal returns (uint256 amountIn) {
        uint256 amountOut = params.amountOut;
        uint256 maxAmountIn = params.amountInMaximum;
        if (amountOut == 0 || maxAmountIn == 0) revert InvalidSwapAmount();

        address currency0 = Currency.unwrap(params.poolKey.currency0);
        address currency1 = Currency.unwrap(params.poolKey.currency1);
        if (currency0 == currency1) revert InvalidPoolKey();
        address input = params.zeroForOne ? currency0 : currency1;
        address output = params.zeroForOne ? currency1 : currency0;
        uint256 inputBefore = _currencyBalance(input);
        uint256 outputBefore = _currencyBalance(output);

        if (input != address(0)) _ensureRouterApproval(input, maxAmountIn);

        bytes[] memory actionParams = new bytes[](4);
        actionParams[0] = abi.encode(params);
        actionParams[1] = abi.encode(input, maxAmountIn);
        actionParams[2] = abi.encode(output, amountOut);
        actionParams[3] = abi.encode(input, uint256(0));

        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_OUT_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE_ALL),
            uint8(Actions.TAKE_ALL)
        );
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, actionParams);

        UNIVERSAL_ROUTER.execute{value: input == address(0) ? maxAmountIn : 0}(
            abi.encodePacked(V4_SWAP_COMMAND), inputs, deadline
        );

        uint256 actualOut = _currencyBalance(output) - outputBefore;
        if (actualOut < amountOut) revert SwapOutputTooLow(amountOut, actualOut);
        amountIn = inputBefore - _currencyBalance(input);
        if (amountIn > maxAmountIn) revert SwapInputTooHigh(maxAmountIn, amountIn);
    }

    function _ensureRouterApproval(address token, uint256 required) internal {
        (uint160 allowance,,) =
            PERMIT2.allowance(address(this), token, address(UNIVERSAL_ROUTER));
        if (uint256(allowance) >= required) return;
        IERC20(token).forceApprove(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(
            token,
            address(UNIVERSAL_ROUTER),
            type(uint160).max,
            type(uint48).max
        );
    }

    function _currencyBalance(address currency) internal view returns (uint256) {
        return currency == address(0)
            ? address(this).balance
            : IERC20(currency).balanceOf(address(this));
    }

    receive() external payable {}
}
