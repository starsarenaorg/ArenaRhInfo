// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IRobinhoodLaunchToken} from "../../../contracts/contracts/robinhood/interfaces/IRobinhoodLaunchToken.sol";
import {
    IRobinhoodHelperPermit2,
    IRobinhoodHelperUniversalRouter,
    IRobinhoodHelperWETH
} from "../../../contracts/contracts/helpers/RobinhoodHelperInterfaces.sol";
import {
    IRobinhoodV2PrismBuyer,
    IRobinhoodV2PrismManager,
    IRobinhoodV2PrismRegistry
} from "./interfaces/IRobinhoodV2Periphery.sol";
import {RobinhoodV2PrismNativeRouter} from "./RobinhoodV2PrismNativeRouter.sol";

interface IRobinhoodV2PrismV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee)
        external
        view
        returns (address pool);
}

/// @notice Adds canonical WETH/pair-token V3 routes to the V2 Prism router.
contract RobinhoodV2PrismNativeRouterV3 is RobinhoodV2PrismNativeRouter {
    using SafeERC20 for IERC20;

    bytes1 internal constant V3_SWAP_EXACT_IN_COMMAND = 0x00;

    struct V3TradeRequest {
        address manager;
        uint256 tokenId;
        uint256 tokenAmount;
        uint256 minPairOut;
        uint256 minFinalOut;
        uint24 nativePairFee;
        uint256 deadline;
    }

    struct V3TradeContext {
        IRobinhoodV2PrismManager manager;
        IERC20 pairToken;
        address token;
        bool postBond;
    }

    struct V3LaunchRequest {
        uint24 nativePairFee;
        uint256 minPairOut;
        uint256 minPostBondTokenOut;
        uint256 deadline;
        bool withWhitelist;
    }

    struct V3CreateAndBuyRequest {
        uint24 nativePairFee;
        uint256 tokenAmount;
        uint256 minPairOut;
        uint256 minTokenOut;
        uint256 deadline;
        bool withWhitelist;
    }

    IRobinhoodV2PrismV3Factory public immutable V3_FACTORY;

    error InvalidV3PairPool();

    event PrismV3Swap(
        address indexed pairToken,
        address indexed pool,
        uint24 indexed fee,
        bool wethToPair,
        uint256 amountIn,
        uint256 amountOut
    );

    constructor(
        IRobinhoodV2PrismRegistry registry_,
        IRobinhoodV2PrismBuyer prismBuyer_,
        IRobinhoodHelperUniversalRouter universalRouter_,
        IRobinhoodHelperPermit2 permit2_,
        IRobinhoodHelperWETH weth_,
        IRobinhoodV2PrismV3Factory v3Factory_
    ) RobinhoodV2PrismNativeRouter(
        registry_, prismBuyer_, universalRouter_, permit2_, weth_
    ) {
        if (
            address(v3Factory_) == address(0)
                || address(v3Factory_).code.length == 0
        ) revert InvalidDependency();
        V3_FACTORY = v3Factory_;
    }

    function buyWithNativeV3(V3TradeRequest calldata request)
        external
        payable
        nonReentrant
        returns (uint256 tokenOut, uint256 pairSpent)
    {
        if (msg.value == 0) revert InvalidValue();
        V3TradeContext memory context = _validatedV3Trade(request);
        uint256 pairBefore = context.pairToken.balanceOf(address(this));

        WETH.deposit{value: msg.value}();
        uint256 pairOut = _swapV3ExactInputSingle(
            address(WETH),
            address(context.pairToken),
            request.nativePairFee,
            msg.value,
            request.minPairOut,
            request.deadline
        );
        (tokenOut, context.postBond) = _buyLaunchToken(
            context.manager,
            context.pairToken,
            context.token,
            request.tokenId,
            request.tokenAmount,
            request.minFinalOut,
            request.deadline,
            pairOut
        );

        IERC20(context.token).safeTransfer(msg.sender, tokenOut);
        _forwardDividends(context.manager, request.tokenId, msg.sender);
        uint256 pairRefund =
            context.pairToken.balanceOf(address(this)) - pairBefore;
        pairSpent = pairOut - pairRefund;
        if (pairRefund != 0) {
            context.pairToken.safeTransfer(msg.sender, pairRefund);
        }
        emit PrismNativeTrade(
            msg.sender,
            address(context.manager),
            context.token,
            request.tokenId,
            true,
            context.postBond,
            msg.value,
            pairSpent,
            tokenOut
        );
    }

    function sellToNativeV3(V3TradeRequest calldata request)
        external
        nonReentrant
        returns (uint256 nativeOut, uint256 pairOut)
    {
        V3TradeContext memory context = _validatedV3Trade(request);
        IERC20(context.token).safeTransferFrom(
            msg.sender, address(this), request.tokenAmount
        );

        context.postBond =
            context.manager.getTokenParameters(request.tokenId).lpDeployed;
        if (context.postBond) {
            pairOut = _swapExactInputSingle(
                _launchPoolKey(
                    context.manager,
                    address(context.pairToken),
                    context.token
                ),
                context.token < address(context.pairToken),
                request.tokenAmount,
                request.minPairOut,
                request.deadline
            );
        } else {
            IERC20(context.token).forceApprove(
                address(context.manager), request.tokenAmount
            );
            uint256 pairBefore = context.pairToken.balanceOf(address(this));
            context.manager.sellWithUser(
                request.tokenAmount,
                request.tokenId,
                msg.sender,
                request.minPairOut
            );
            pairOut =
                context.pairToken.balanceOf(address(this)) - pairBefore;
            IERC20(context.token).forceApprove(address(context.manager), 0);
        }

        _forwardDividends(context.manager, request.tokenId, msg.sender);
        nativeOut = _swapV3ExactInputSingle(
            address(context.pairToken),
            address(WETH),
            request.nativePairFee,
            pairOut,
            request.minFinalOut,
            request.deadline
        );
        WETH.withdraw(nativeOut);
        _sendNative(msg.sender, nativeOut);
        emit PrismNativeTrade(
            msg.sender,
            address(context.manager),
            context.token,
            request.tokenId,
            false,
            context.postBond,
            nativeOut,
            pairOut,
            request.tokenAmount
        );
    }

    function createAndBuyWithNativeV3(
        IRobinhoodV2PrismBuyer.CreationParams calldata params,
        uint24 nativePairFee,
        uint256 tokenAmount,
        uint256 minPairOut,
        uint256 minTokenOut,
        uint256 deadline
    ) external payable nonReentrant returns (address token, uint256 tokenOut) {
        IRobinhoodLaunchToken.Whitelist memory whitelist;
        return _createAndBuyV3(
            params,
            V3CreateAndBuyRequest({
                nativePairFee: nativePairFee,
                tokenAmount: tokenAmount,
                minPairOut: minPairOut,
                minTokenOut: minTokenOut,
                deadline: deadline,
                withWhitelist: false
            }),
            whitelist
        );
    }

    function createAndBuyWithNativeV3WithWhitelist(
        IRobinhoodV2PrismBuyer.CreationParams calldata params,
        uint24 nativePairFee,
        uint256 tokenAmount,
        uint256 minPairOut,
        IRobinhoodLaunchToken.Whitelist calldata whitelist,
        uint256 minTokenOut,
        uint256 deadline
    ) external payable nonReentrant returns (address token, uint256 tokenOut) {
        return _createAndBuyV3(
            params,
            V3CreateAndBuyRequest({
                nativePairFee: nativePairFee,
                tokenAmount: tokenAmount,
                minPairOut: minPairOut,
                minTokenOut: minTokenOut,
                deadline: deadline,
                withWhitelist: true
            }),
            whitelist
        );
    }

    function launchAndBuyWithNativeV3(
        IRobinhoodV2PrismBuyer.CreationParams calldata params,
        uint24 nativePairFee,
        uint256 minPairOut,
        uint256 minPostBondTokenOut,
        uint256 deadline
    ) external payable nonReentrant returns (address token, uint256 tokenOut) {
        IRobinhoodLaunchToken.Whitelist memory whitelist;
        return _launchV3(
            params,
            V3LaunchRequest({
                nativePairFee: nativePairFee,
                minPairOut: minPairOut,
                minPostBondTokenOut: minPostBondTokenOut,
                deadline: deadline,
                withWhitelist: false
            }),
            whitelist
        );
    }

    function launchAndBuyWithNativeV3WithWhitelist(
        IRobinhoodV2PrismBuyer.CreationParams calldata params,
        uint24 nativePairFee,
        uint256 minPairOut,
        IRobinhoodLaunchToken.Whitelist calldata whitelist,
        uint256 minPostBondTokenOut,
        uint256 deadline
    ) external payable nonReentrant returns (address token, uint256 tokenOut) {
        return _launchV3(
            params,
            V3LaunchRequest({
                nativePairFee: nativePairFee,
                minPairOut: minPairOut,
                minPostBondTokenOut: minPostBondTokenOut,
                deadline: deadline,
                withWhitelist: true
            }),
            whitelist
        );
    }

    function _launchV3(
        IRobinhoodV2PrismBuyer.CreationParams calldata params,
        V3LaunchRequest memory request,
        IRobinhoodLaunchToken.Whitelist memory whitelist
    ) internal returns (address token, uint256 tokenOut) {
        if (msg.value == 0) revert InvalidValue();
        IERC20 pairToken = IERC20(_approvedPairToken(params.manager));
        uint256 pairBefore = pairToken.balanceOf(address(this));
        WETH.deposit{value: msg.value}();
        uint256 pairOut = _swapV3ExactInputSingle(
            address(WETH),
            address(pairToken),
            request.nativePairFee,
            msg.value,
            request.minPairOut,
            request.deadline
        );
        pairToken.forceApprove(address(PRISM_BUYER), pairOut);
        if (request.withWhitelist) {
            (token, tokenOut) =
                PRISM_BUYER.bondAndBuyFromLpOnCreationWithWhitelist(
                    params,
                    pairOut,
                    whitelist,
                    request.minPostBondTokenOut,
                    request.deadline
                );
        } else {
            (token, tokenOut) = PRISM_BUYER.bondAndBuyFromLpOnCreation(
                params,
                pairOut,
                request.minPostBondTokenOut,
                request.deadline
            );
        }
        pairToken.forceApprove(address(PRISM_BUYER), 0);
        IERC20(token).safeTransfer(msg.sender, tokenOut);

        IRobinhoodV2PrismManager manager =
            IRobinhoodV2PrismManager(params.manager);
        _forwardDividends(manager, manager.tokenIdentifier() - 1, msg.sender);
        uint256 refund = pairToken.balanceOf(address(this)) - pairBefore;
        if (refund != 0) pairToken.safeTransfer(msg.sender, refund);
        emit PrismNativeLaunch(
            msg.sender,
            params.manager,
            token,
            msg.value,
            pairOut - refund,
            tokenOut
        );
    }

    function _createAndBuyV3(
        IRobinhoodV2PrismBuyer.CreationParams calldata params,
        V3CreateAndBuyRequest memory request,
        IRobinhoodLaunchToken.Whitelist memory whitelist
    ) internal returns (address token, uint256 tokenOut) {
        if (msg.value == 0 || request.tokenAmount == 0) revert InvalidValue();
        IERC20 pairToken = IERC20(_approvedPairToken(params.manager));
        IRobinhoodV2PrismManager manager =
            IRobinhoodV2PrismManager(params.manager);
        uint256 tokenId = manager.tokenIdentifier();
        uint256 pairBefore = pairToken.balanceOf(address(this));
        WETH.deposit{value: msg.value}();
        uint256 pairOut = _swapV3ExactInputSingle(
            address(WETH),
            address(pairToken),
            request.nativePairFee,
            msg.value,
            request.minPairOut,
            request.deadline
        );
        pairToken.forceApprove(params.manager, pairOut);
        _createToken(
            manager,
            params,
            request.tokenAmount,
            whitelist,
            request.withWhitelist,
            pairOut,
            request.deadline
        );
        pairToken.forceApprove(params.manager, 0);

        IRobinhoodV2PrismManager.TokenParameters memory created =
            manager.getTokenParameters(tokenId);
        token = created.tokenContractAddress;
        tokenOut = IERC20(token).balanceOf(address(this));
        uint256 pairRemainder =
            pairToken.balanceOf(address(this)) - pairBefore;
        if (created.lpDeployed && pairRemainder != 0) {
            tokenOut += _swapExactInputSingle(
                _launchPoolKey(manager, address(pairToken), token),
                address(pairToken) < token,
                pairRemainder,
                1,
                request.deadline
            );
            pairRemainder =
                pairToken.balanceOf(address(this)) - pairBefore;
        }
        if (tokenOut < request.minTokenOut) revert OutputTooLow();
        IERC20(token).safeTransfer(msg.sender, tokenOut);
        _forwardDividends(manager, tokenId, msg.sender);
        if (pairRemainder != 0) {
            pairToken.safeTransfer(msg.sender, pairRemainder);
        }
        emit PrismNativeLaunch(
            msg.sender,
            params.manager,
            token,
            msg.value,
            pairOut - pairRemainder,
            tokenOut
        );
    }

    function _validatedV3Trade(V3TradeRequest calldata request)
        internal
        view
        returns (V3TradeContext memory context)
    {
        address pair = _approvedPairToken(request.manager);
        context.manager = IRobinhoodV2PrismManager(request.manager);
        if (context.manager.PAIR_TOKEN() != pair) revert ManagerNotApproved();
        context.pairToken = IERC20(pair);
        context.token =
            context.manager.getTokenParameters(request.tokenId).tokenContractAddress;
        if (context.token == address(0) || context.token.code.length == 0) {
            revert InvalidToken();
        }
    }

    function _swapV3ExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline
    ) internal returns (uint256 amountOut) {
        if (amountIn == 0 || amountIn > type(uint160).max) {
            revert InvalidSwapAmount();
        }
        if (minAmountOut == 0) revert InvalidMinimumOutput();

        (address pairToken, bool wethToPair, address pool) =
            _validateV3PairPool(tokenIn, tokenOut, fee);
        uint256 outputBefore = IERC20(tokenOut).balanceOf(address(this));
        _ensureRouterApproval(tokenIn, amountIn);
        _executeV3ExactInputSingle(
            tokenIn, tokenOut, fee, amountIn, minAmountOut, deadline
        );
        amountOut = IERC20(tokenOut).balanceOf(address(this)) - outputBefore;
        if (amountOut < minAmountOut) {
            revert SwapOutputTooLow(minAmountOut, amountOut);
        }
        emit PrismV3Swap(
            pairToken, pool, fee, wethToPair, amountIn, amountOut
        );
    }

    function _executeV3ExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline
    ) internal {
        uint256[] memory minHopPriceX36 = new uint256[](0);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            address(this),
            amountIn,
            minAmountOut,
            abi.encodePacked(tokenIn, fee, tokenOut),
            true,
            minHopPriceX36
        );
        UNIVERSAL_ROUTER.execute(
            abi.encodePacked(V3_SWAP_EXACT_IN_COMMAND), inputs, deadline
        );
    }

    function _validateV3PairPool(address tokenIn, address tokenOut, uint24 fee)
        internal
        view
        returns (address pairToken, bool wethToPair, address pool)
    {
        if (tokenIn == address(WETH) && tokenOut != address(WETH)) {
            pairToken = tokenOut;
            wethToPair = true;
        } else if (tokenOut == address(WETH) && tokenIn != address(WETH)) {
            pairToken = tokenIn;
        } else {
            revert InvalidV3PairPool();
        }

        pool = V3_FACTORY.getPool(address(WETH), pairToken, fee);
        if (pool == address(0) || pool.code.length == 0) {
            revert InvalidV3PairPool();
        }
    }
}
