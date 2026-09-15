// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IRobinhoodLaunchToken} from "../../../contracts/contracts/robinhood/interfaces/IRobinhoodLaunchToken.sol";
import {IArenaPoolDeployer} from "../../../contracts/contracts/robinhood/interfaces/IArenaPoolDeployer.sol";
import {
    IRobinhoodHelperPermit2,
    IRobinhoodHelperUniversalRouter,
    IRobinhoodHelperWETH
} from "../../../contracts/contracts/helpers/RobinhoodHelperInterfaces.sol";
import {RobinhoodV4SwapExecutor} from "../../../contracts/contracts/helpers/RobinhoodV4SwapExecutor.sol";
import {
    IRobinhoodV2PrismBuyer,
    IRobinhoodV2PrismManager,
    IRobinhoodV2PrismRegistry
} from "./interfaces/IRobinhoodV2Periphery.sol";

/// @notice Native ETH entry/exit router for registry-approved V2 Prism pairs.
/// @dev The native leg may use either a native ETH/pair V4 pool or a
///      WETH/pair V4 pool. The launch-token leg always uses its V4 pool.
contract RobinhoodV2PrismNativeRouter is
    RobinhoodV4SwapExecutor,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    enum NativePairRoute {
        Native,
        Wrapped
    }

    struct TradeRequest {
        address manager;
        uint256 tokenId;
        uint256 tokenAmount;
        uint256 minPairOut;
        uint256 minFinalOut;
        PoolKey nativePairPool;
        uint256 deadline;
    }

    struct TradeContext {
        IRobinhoodV2PrismManager manager;
        IERC20 pairToken;
        address token;
        bool postBond;
    }

    struct NativeLaunchRequest {
        PoolKey nativePairPool;
        uint256 minPairOut;
        uint256 minPostBondTokenOut;
        uint256 deadline;
        bool withWhitelist;
    }

    struct NativeCreateAndBuyRequest {
        PoolKey nativePairPool;
        uint256 tokenAmount;
        uint256 minPairOut;
        uint256 minTokenOut;
        uint256 deadline;
        bool withWhitelist;
    }

    IRobinhoodV2PrismRegistry public immutable REGISTRY;
    IRobinhoodV2PrismBuyer public immutable PRISM_BUYER;
    IRobinhoodHelperWETH public immutable WETH;

    error InvalidDependency();
    error ManagerNotApproved();
    error InvalidNativePairPool();
    error InvalidToken();
    error InvalidValue();
    error OutputTooLow();
    error NativeTransferFailed();

    event PrismNativeTrade(
        address indexed user,
        address indexed manager,
        address indexed token,
        uint256 tokenId,
        bool isBuy,
        bool postBond,
        uint256 nativeAmount,
        uint256 pairAmount,
        uint256 tokenAmount
    );

    event PrismNativeLaunch(
        address indexed user,
        address indexed manager,
        address indexed token,
        uint256 nativeIn,
        uint256 pairTokenIn,
        uint256 tokenOut
    );

    constructor(
        IRobinhoodV2PrismRegistry registry_,
        IRobinhoodV2PrismBuyer prismBuyer_,
        IRobinhoodHelperUniversalRouter universalRouter_,
        IRobinhoodHelperPermit2 permit2_,
        IRobinhoodHelperWETH weth_
    ) RobinhoodV4SwapExecutor(universalRouter_, permit2_) {
        if (
            address(registry_) == address(0)
                || address(registry_).code.length == 0
                || address(prismBuyer_) == address(0)
                || address(prismBuyer_).code.length == 0
                || address(weth_) == address(0)
                || address(weth_).code.length == 0
        ) revert InvalidDependency();
        REGISTRY = registry_;
        PRISM_BUYER = prismBuyer_;
        WETH = weth_;
    }

    function buyWithNative(TradeRequest calldata request)
        external
        payable
        nonReentrant
        returns (uint256 tokenOut, uint256 pairSpent)
    {
        if (msg.value == 0) revert InvalidValue();
        TradeContext memory context = _validatedTrade(request);
        uint256 pairBefore = context.pairToken.balanceOf(address(this));
        uint256 pairOut = _swapNativeForPair(
            request.nativePairPool,
            address(context.pairToken),
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

    function sellToNative(TradeRequest calldata request)
        external
        nonReentrant
        returns (uint256 nativeOut, uint256 pairOut)
    {
        TradeContext memory context = _validatedTrade(request);
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
        nativeOut = _swapPairForNative(
            request.nativePairPool,
            address(context.pairToken),
            pairOut,
            request.minFinalOut,
            request.deadline
        );
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

    function createAndBuyWithNative(
        IRobinhoodV2PrismBuyer.CreationParams calldata params,
        PoolKey calldata nativePairPool,
        uint256 tokenAmount,
        uint256 minPairOut,
        uint256 minTokenOut,
        uint256 deadline
    ) external payable nonReentrant returns (address token, uint256 tokenOut) {
        IRobinhoodLaunchToken.Whitelist memory whitelist;
        return _createAndBuy(
            params,
            NativeCreateAndBuyRequest({
                nativePairPool: nativePairPool,
                tokenAmount: tokenAmount,
                minPairOut: minPairOut,
                minTokenOut: minTokenOut,
                deadline: deadline,
                withWhitelist: false
            }),
            whitelist
        );
    }

    function createAndBuyWithNativeWithWhitelist(
        IRobinhoodV2PrismBuyer.CreationParams calldata params,
        PoolKey calldata nativePairPool,
        uint256 tokenAmount,
        uint256 minPairOut,
        IRobinhoodLaunchToken.Whitelist calldata whitelist,
        uint256 minTokenOut,
        uint256 deadline
    ) external payable nonReentrant returns (address token, uint256 tokenOut) {
        return _createAndBuy(
            params,
            NativeCreateAndBuyRequest({
                nativePairPool: nativePairPool,
                tokenAmount: tokenAmount,
                minPairOut: minPairOut,
                minTokenOut: minTokenOut,
                deadline: deadline,
                withWhitelist: true
            }),
            whitelist
        );
    }

    function launchAndBuyWithNative(
        IRobinhoodV2PrismBuyer.CreationParams calldata params,
        PoolKey calldata nativePairPool,
        uint256 minPairOut,
        uint256 minPostBondTokenOut,
        uint256 deadline
    ) external payable nonReentrant returns (address token, uint256 tokenOut) {
        IRobinhoodLaunchToken.Whitelist memory whitelist;
        return _launch(
            params,
            NativeLaunchRequest({
                nativePairPool: nativePairPool,
                minPairOut: minPairOut,
                minPostBondTokenOut: minPostBondTokenOut,
                deadline: deadline,
                withWhitelist: false
            }),
            whitelist
        );
    }

    function launchAndBuyWithNativeWithWhitelist(
        IRobinhoodV2PrismBuyer.CreationParams calldata params,
        PoolKey calldata nativePairPool,
        uint256 minPairOut,
        IRobinhoodLaunchToken.Whitelist calldata whitelist,
        uint256 minPostBondTokenOut,
        uint256 deadline
    ) external payable nonReentrant returns (address token, uint256 tokenOut) {
        return _launch(
            params,
            NativeLaunchRequest({
                nativePairPool: nativePairPool,
                minPairOut: minPairOut,
                minPostBondTokenOut: minPostBondTokenOut,
                deadline: deadline,
                withWhitelist: true
            }),
            whitelist
        );
    }

    function _launch(
        IRobinhoodV2PrismBuyer.CreationParams calldata params,
        NativeLaunchRequest memory request,
        IRobinhoodLaunchToken.Whitelist memory whitelist
    ) internal returns (address token, uint256 tokenOut) {
        if (msg.value == 0) revert InvalidValue();
        IERC20 pairToken = IERC20(_approvedPairToken(params.manager));
        uint256 pairBefore = pairToken.balanceOf(address(this));
        uint256 pairOut = _swapNativeForPair(
            request.nativePairPool,
            address(pairToken),
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

        uint256 tokenId =
            IRobinhoodV2PrismManager(params.manager).tokenIdentifier() - 1;
        _forwardDividends(
            IRobinhoodV2PrismManager(params.manager), tokenId, msg.sender
        );
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

    function _createAndBuy(
        IRobinhoodV2PrismBuyer.CreationParams calldata params,
        NativeCreateAndBuyRequest memory request,
        IRobinhoodLaunchToken.Whitelist memory whitelist
    ) internal returns (address token, uint256 tokenOut) {
        if (msg.value == 0 || request.tokenAmount == 0) revert InvalidValue();
        IERC20 pairToken = IERC20(_approvedPairToken(params.manager));
        IRobinhoodV2PrismManager manager =
            IRobinhoodV2PrismManager(params.manager);
        uint256 tokenId = manager.tokenIdentifier();
        uint256 pairBefore = pairToken.balanceOf(address(this));
        uint256 pairOut = _swapNativeForPair(
            request.nativePairPool,
            address(pairToken),
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

    function _createToken(
        IRobinhoodV2PrismManager manager,
        IRobinhoodV2PrismBuyer.CreationParams calldata params,
        uint256 tokenAmount,
        IRobinhoodLaunchToken.Whitelist memory whitelist,
        bool withWhitelist,
        uint256 maxTotalCost,
        uint256 deadline
    ) internal {
        if (withWhitelist) {
            manager.createTokenWithWL(
                params.a,
                params.b,
                params.curveScaler,
                params.creatorFeeBasisPoints,
                params.dividendFeeBasisPoints,
                params.tokenCreatorAddress,
                params.tokenSplit,
                params.name,
                params.symbol,
                tokenAmount,
                whitelist,
                maxTotalCost,
                deadline
            );
        } else {
            manager.createToken(
                params.a,
                params.b,
                params.curveScaler,
                params.creatorFeeBasisPoints,
                params.dividendFeeBasisPoints,
                params.tokenCreatorAddress,
                params.tokenSplit,
                params.name,
                params.symbol,
                tokenAmount,
                maxTotalCost,
                deadline
            );
        }
    }

    function _buyLaunchToken(
        IRobinhoodV2PrismManager manager,
        IERC20 pairToken,
        address token,
        uint256 tokenId,
        uint256 tokenAmount,
        uint256 minTokenOut,
        uint256 deadline,
        uint256 pairOut
    ) internal returns (uint256 tokenOut, bool postBond) {
        uint256 tokenBefore = IERC20(token).balanceOf(address(this));
        postBond = manager.getTokenParameters(tokenId).lpDeployed;
        if (postBond) {
            tokenOut = _swapExactInputSingle(
                _launchPoolKey(manager, address(pairToken), token),
                address(pairToken) < token,
                pairOut,
                minTokenOut,
                deadline
            );
        } else {
            pairToken.forceApprove(address(manager), pairOut);
            manager.buyAndCreateLpIfPossibleWithUser(
                tokenAmount, tokenId, msg.sender, pairOut
            );
            tokenOut = IERC20(token).balanceOf(address(this)) - tokenBefore;
            pairToken.forceApprove(address(manager), 0);
            if (tokenOut < minTokenOut) revert OutputTooLow();
        }
    }

    function _validatedTrade(TradeRequest calldata request)
        internal
        view
        returns (TradeContext memory context)
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

    function _approvedPairToken(address manager)
        internal
        view
        returns (address pairToken)
    {
        if (!REGISTRY.isApprovedManager(manager)) revert ManagerNotApproved();
        pairToken = REGISTRY.pairTokenForManager(manager);
        if (pairToken == address(0)) revert ManagerNotApproved();
    }

    function _swapNativeForPair(
        PoolKey memory key,
        address pairToken,
        uint256 nativeAmount,
        uint256 minPairOut,
        uint256 deadline
    ) internal returns (uint256 pairOut) {
        NativePairRoute route = _validateNativePairPool(key, pairToken);
        address input =
            route == NativePairRoute.Native ? address(0) : address(WETH);
        if (route == NativePairRoute.Wrapped) {
            WETH.deposit{value: nativeAmount}();
        }
        pairOut = _swapExactInputSingle(
            key,
            _zeroForOne(input, pairToken, key),
            nativeAmount,
            minPairOut,
            deadline
        );
    }

    function _swapPairForNative(
        PoolKey memory key,
        address pairToken,
        uint256 pairAmount,
        uint256 minNativeOut,
        uint256 deadline
    ) internal returns (uint256 nativeOut) {
        NativePairRoute route = _validateNativePairPool(key, pairToken);
        address output =
            route == NativePairRoute.Native ? address(0) : address(WETH);
        nativeOut = _swapExactInputSingle(
            key,
            _zeroForOne(pairToken, output, key),
            pairAmount,
            minNativeOut,
            deadline
        );
        if (route == NativePairRoute.Wrapped) WETH.withdraw(nativeOut);
    }

    function _validateNativePairPool(PoolKey memory key, address pairToken)
        internal
        view
        returns (NativePairRoute)
    {
        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);
        if (currency0 == currency1) revert InvalidNativePairPool();
        if (currency0 == pairToken) {
            if (currency1 == address(0)) return NativePairRoute.Native;
            if (currency1 == address(WETH)) return NativePairRoute.Wrapped;
        }
        if (currency1 == pairToken) {
            if (currency0 == address(0)) return NativePairRoute.Native;
            if (currency0 == address(WETH)) return NativePairRoute.Wrapped;
        }
        revert InvalidNativePairPool();
    }

    function _zeroForOne(address input, address output, PoolKey memory key)
        internal
        pure
        returns (bool)
    {
        return Currency.unwrap(key.currency0) == input
            && Currency.unwrap(key.currency1) == output;
    }

    function _launchPoolKey(
        IRobinhoodV2PrismManager manager,
        address pairToken,
        address launchToken
    ) internal view returns (PoolKey memory) {
        IArenaPoolDeployer.PoolInitParams memory config =
            manager.getV4PoolInitParams().poolInitParams;
        address token0 = pairToken < launchToken ? pairToken : launchToken;
        address token1 = pairToken < launchToken ? launchToken : pairToken;
        return PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: config.fee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(config.hookContract)
        });
    }

    function _forwardDividends(
        IRobinhoodV2PrismManager manager,
        uint256 tokenId,
        address user
    ) internal {
        manager.dividendController().claimFor(tokenId, user, user);
        manager.dividendController().claimFor(tokenId, address(this), user);
    }

    function _sendNative(address recipient, uint256 amount) internal {
        (bool success,) = payable(recipient).call{value: amount}("");
        if (!success) revert NativeTransferFailed();
    }
}
