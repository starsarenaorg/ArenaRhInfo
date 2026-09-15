// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IRobinhoodLaunchToken} from "../robinhood/interfaces/IRobinhoodLaunchToken.sol";
import {IArenaPoolDeployer} from "../robinhood/interfaces/IArenaPoolDeployer.sol";
import {
    IRobinhoodArenaManagerHelper,
    IRobinhoodHelperPermit2,
    IRobinhoodHelperUniversalRouter
} from "../helpers/RobinhoodHelperInterfaces.sol";
import {RobinhoodV4SwapExecutor} from "../helpers/RobinhoodV4SwapExecutor.sol";

interface IPrismNativeRouterRegistry {
    function isApprovedManager(address manager) external view returns (bool);
    function pairTokenForManager(address manager) external view returns (address);
}

interface IPrismNativeRouterBuyer {
    struct CreationParams {
        address manager;
        uint32 a;
        uint8 b;
        uint128 curveScaler;
        uint8 creatorFeeBasisPoints;
        address tokenCreatorAddress;
        uint256 tokenSplit;
        bool enableHolderRewards;
        string name;
        string symbol;
    }

    function bondAndBuyFromLpOnCreation(
        CreationParams calldata params,
        uint256 pairTokenToSpend,
        uint256 minPostBondTokenOut,
        uint256 deadline
    ) external returns (address token, uint256 tokenOut);

    function bondAndBuyFromLpOnCreationWithWhitelist(
        CreationParams calldata params,
        uint256 pairTokenToSpend,
        IRobinhoodLaunchToken.Whitelist calldata whitelist,
        uint256 minPostBondTokenOut,
        uint256 deadline
    ) external returns (address token, uint256 tokenOut);
}

/// @notice ETH entry/exit router for every registry-approved Prism pair.
/// @dev A manager must authorize this router as its native helper for pre-bond
///      buys/sells. Post-bond and atomic-launch routes need no manager custody.
contract RobinhoodPrismNativeRouter is RobinhoodV4SwapExecutor, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct TradeRequest {
        address manager;
        uint256 tokenId;
        uint256 tokenAmount;
        uint256 minPairOut;
        uint256 minFinalOut;
        PoolKey nativePairPool;
        uint256 deadline;
    }

    IPrismNativeRouterRegistry public immutable REGISTRY;
    IPrismNativeRouterBuyer public immutable PRISM_BUYER;

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

    /// @notice Creates a Prism token from native ETH and buys an arbitrary
    ///         amount on the curve. If that purchase graduates the token, any
    ///         paired-token remainder is bought through the newly created pool.
    function createAndBuyWithNative(
        IPrismNativeRouterBuyer.CreationParams calldata params,
        PoolKey calldata nativePairPool,
        uint256 tokenAmount,
        uint256 minPairOut,
        uint256 minTokenOut,
        uint256 deadline
    ) external payable nonReentrant returns (address token, uint256 tokenOut) {
        IRobinhoodLaunchToken.Whitelist memory whitelist;
        return _createAndBuy(
            params, nativePairPool, tokenAmount, minPairOut, minTokenOut,
            deadline, whitelist, false
        );
    }

    function createAndBuyWithNativeWithWhitelist(
        IPrismNativeRouterBuyer.CreationParams calldata params,
        PoolKey calldata nativePairPool,
        uint256 tokenAmount,
        uint256 minPairOut,
        IRobinhoodLaunchToken.Whitelist calldata whitelist,
        uint256 minTokenOut,
        uint256 deadline
    ) external payable nonReentrant returns (address token, uint256 tokenOut) {
        return _createAndBuy(
            params, nativePairPool, tokenAmount, minPairOut, minTokenOut,
            deadline, whitelist, true
        );
    }

    constructor(
        IPrismNativeRouterRegistry registry_,
        IPrismNativeRouterBuyer prismBuyer_,
        IRobinhoodHelperUniversalRouter universalRouter_,
        IRobinhoodHelperPermit2 permit2_
    ) RobinhoodV4SwapExecutor(universalRouter_, permit2_) {
        if (
            address(registry_) == address(0) || address(registry_).code.length == 0
                || address(prismBuyer_) == address(0) || address(prismBuyer_).code.length == 0
        ) revert InvalidDependency();
        REGISTRY = registry_;
        PRISM_BUYER = prismBuyer_;
    }

    function buyWithNative(TradeRequest calldata request)
        external
        payable
        nonReentrant
        returns (uint256 tokenOut, uint256 pairSpent)
    {
        if (msg.value == 0) revert InvalidValue();
        (IRobinhoodArenaManagerHelper manager, IERC20 pairToken, address token) =
            _validatedTrade(request);
        _validateNativePairPool(request.nativePairPool, address(pairToken));

        uint256 pairBefore = pairToken.balanceOf(address(this));
        uint256 pairOut = _swapExactInputSingle(
            request.nativePairPool,
            _zeroForOne(address(0), address(pairToken), request.nativePairPool),
            msg.value,
            request.minPairOut,
            request.deadline
        );

        uint256 tokenBefore = IERC20(token).balanceOf(address(this));
        bool postBond = manager.getTokenParameters(request.tokenId).lpDeployed;
        if (postBond) {
            tokenOut = _swapExactInputSingle(
                _launchPoolKey(manager, address(pairToken), token),
                address(pairToken) < token,
                pairOut,
                request.minFinalOut,
                request.deadline
            );
        } else {
            pairToken.forceApprove(address(manager), pairOut);
            manager.buyAndCreateLpIfPossibleWithUser(
                request.tokenAmount, request.tokenId, msg.sender, pairOut
            );
            tokenOut = IERC20(token).balanceOf(address(this)) - tokenBefore;
            pairToken.forceApprove(address(manager), 0);
            if (tokenOut < request.minFinalOut) revert OutputTooLow();
        }

        IERC20(token).safeTransfer(msg.sender, tokenOut);
        uint256 pairRefund = pairToken.balanceOf(address(this)) - pairBefore;
        pairSpent = pairOut - pairRefund;
        if (pairRefund != 0) pairToken.safeTransfer(msg.sender, pairRefund);
        emit PrismNativeTrade(
            msg.sender, address(manager), token, request.tokenId, true,
            postBond, msg.value, pairSpent, tokenOut
        );
    }

    function sellToNative(TradeRequest calldata request)
        external
        nonReentrant
        returns (uint256 nativeOut, uint256 pairOut)
    {
        (IRobinhoodArenaManagerHelper manager, IERC20 pairToken, address token) =
            _validatedTrade(request);
        _validateNativePairPool(request.nativePairPool, address(pairToken));
        IERC20(token).safeTransferFrom(msg.sender, address(this), request.tokenAmount);

        bool postBond = manager.getTokenParameters(request.tokenId).lpDeployed;
        if (postBond) {
            pairOut = _swapExactInputSingle(
                _launchPoolKey(manager, address(pairToken), token),
                token < address(pairToken),
                request.tokenAmount,
                request.minPairOut,
                request.deadline
            );
        } else {
            IERC20(token).forceApprove(address(manager), request.tokenAmount);
            uint256 pairBefore = pairToken.balanceOf(address(this));
            manager.sellWithUser(request.tokenAmount, request.tokenId, msg.sender, request.minPairOut);
            pairOut = pairToken.balanceOf(address(this)) - pairBefore;
            IERC20(token).forceApprove(address(manager), 0);
        }

        nativeOut = _swapExactInputSingle(
            request.nativePairPool,
            _zeroForOne(address(pairToken), address(0), request.nativePairPool),
            pairOut,
            request.minFinalOut,
            request.deadline
        );
        (bool success,) = payable(msg.sender).call{value: nativeOut}("");
        if (!success) revert NativeTransferFailed();
        emit PrismNativeTrade(
            msg.sender, address(manager), token, request.tokenId, false,
            postBond, nativeOut, pairOut, request.tokenAmount
        );
    }

    function launchAndBuyWithNative(
        IPrismNativeRouterBuyer.CreationParams calldata params,
        PoolKey calldata nativePairPool,
        uint256 minPairOut,
        uint256 minPostBondTokenOut,
        uint256 deadline
    ) external payable nonReentrant returns (address token, uint256 tokenOut) {
        IRobinhoodLaunchToken.Whitelist memory whitelist;
        return _launch(params, nativePairPool, minPairOut, minPostBondTokenOut, deadline, whitelist, false);
    }

    function launchAndBuyWithNativeWithWhitelist(
        IPrismNativeRouterBuyer.CreationParams calldata params,
        PoolKey calldata nativePairPool,
        uint256 minPairOut,
        IRobinhoodLaunchToken.Whitelist calldata whitelist,
        uint256 minPostBondTokenOut,
        uint256 deadline
    ) external payable nonReentrant returns (address token, uint256 tokenOut) {
        return _launch(params, nativePairPool, minPairOut, minPostBondTokenOut, deadline, whitelist, true);
    }

    function _launch(
        IPrismNativeRouterBuyer.CreationParams calldata params,
        PoolKey calldata nativePairPool,
        uint256 minPairOut,
        uint256 minPostBondTokenOut,
        uint256 deadline,
        IRobinhoodLaunchToken.Whitelist memory whitelist,
        bool withWhitelist
    ) internal returns (address token, uint256 tokenOut) {
        if (msg.value == 0) revert InvalidValue();
        IERC20 pairToken = IERC20(_approvedPairToken(params.manager));
        _validateNativePairPool(nativePairPool, address(pairToken));
        uint256 pairBefore = pairToken.balanceOf(address(this));
        uint256 pairOut = _swapExactInputSingle(
            nativePairPool,
            _zeroForOne(address(0), address(pairToken), nativePairPool),
            msg.value,
            minPairOut,
            deadline
        );
        pairToken.forceApprove(address(PRISM_BUYER), pairOut);
        if (withWhitelist) {
            (token, tokenOut) = PRISM_BUYER.bondAndBuyFromLpOnCreationWithWhitelist(
                params, pairOut, whitelist, minPostBondTokenOut, deadline
            );
        } else {
            (token, tokenOut) = PRISM_BUYER.bondAndBuyFromLpOnCreation(
                params, pairOut, minPostBondTokenOut, deadline
            );
        }
        pairToken.forceApprove(address(PRISM_BUYER), 0);
        IERC20(token).safeTransfer(msg.sender, tokenOut);
        uint256 refund = pairToken.balanceOf(address(this)) - pairBefore;
        if (refund != 0) pairToken.safeTransfer(msg.sender, refund);
        emit PrismNativeLaunch(msg.sender, params.manager, token, msg.value, pairOut - refund, tokenOut);
    }

    function _createAndBuy(
        IPrismNativeRouterBuyer.CreationParams calldata params,
        PoolKey calldata nativePairPool,
        uint256 tokenAmount,
        uint256 minPairOut,
        uint256 minTokenOut,
        uint256 deadline,
        IRobinhoodLaunchToken.Whitelist memory whitelist,
        bool withWhitelist
    ) internal returns (address token, uint256 tokenOut) {
        if (msg.value == 0 || tokenAmount == 0) revert InvalidValue();
        IERC20 pairToken = IERC20(_approvedPairToken(params.manager));
        _validateNativePairPool(nativePairPool, address(pairToken));
        IRobinhoodArenaManagerHelper manager = IRobinhoodArenaManagerHelper(params.manager);
        manager.setNextLaunchHolderRewards(params.enableHolderRewards);
        uint256 tokenId = manager.tokenIdentifier();
        uint256 pairBefore = pairToken.balanceOf(address(this));
        uint256 pairOut = _swapExactInputSingle(
            nativePairPool,
            _zeroForOne(address(0), address(pairToken), nativePairPool),
            msg.value,
            minPairOut,
            deadline
        );
        pairToken.forceApprove(params.manager, pairOut);
        if (withWhitelist) {
            manager.createTokenWithWL(
                params.a, params.b, params.curveScaler,
                params.creatorFeeBasisPoints, params.tokenCreatorAddress,
                params.tokenSplit, params.name, params.symbol, tokenAmount,
                whitelist
            );
        } else {
            manager.createToken(
                params.a, params.b, params.curveScaler,
                params.creatorFeeBasisPoints, params.tokenCreatorAddress,
                params.tokenSplit, params.name, params.symbol, tokenAmount
            );
        }
        pairToken.forceApprove(params.manager, 0);
        IRobinhoodArenaManagerHelper.TokenParameters memory created =
            manager.getTokenParameters(tokenId);
        token = created.tokenContractAddress;
        tokenOut = IERC20(token).balanceOf(address(this));
        uint256 pairRemainder = pairToken.balanceOf(address(this)) - pairBefore;
        if (created.lpDeployed && pairRemainder != 0) {
            tokenOut += _swapExactInputSingle(
                _launchPoolKey(manager, address(pairToken), token),
                address(pairToken) < token,
                pairRemainder,
                1,
                deadline
            );
            pairRemainder = pairToken.balanceOf(address(this)) - pairBefore;
        }
        if (tokenOut < minTokenOut) revert OutputTooLow();
        IERC20(token).safeTransfer(msg.sender, tokenOut);
        if (pairRemainder != 0) pairToken.safeTransfer(msg.sender, pairRemainder);
        emit PrismNativeLaunch(
            msg.sender, params.manager, token, msg.value,
            pairOut - pairRemainder, tokenOut
        );
    }

    function _validatedTrade(TradeRequest calldata request)
        internal
        view
        returns (IRobinhoodArenaManagerHelper manager, IERC20 pairToken, address token)
    {
        address pair = _approvedPairToken(request.manager);
        manager = IRobinhoodArenaManagerHelper(request.manager);
        if (manager.ARENA_ADDRESS() != pair) revert ManagerNotApproved();
        pairToken = IERC20(pair);
        token = manager.getTokenParameters(request.tokenId).tokenContractAddress;
        if (token == address(0) || token.code.length == 0) revert InvalidToken();
    }

    function _approvedPairToken(address manager) internal view returns (address pairToken) {
        if (!REGISTRY.isApprovedManager(manager)) revert ManagerNotApproved();
        pairToken = REGISTRY.pairTokenForManager(manager);
        if (pairToken == address(0)) revert ManagerNotApproved();
    }

    function _validateNativePairPool(PoolKey calldata key, address pairToken) internal pure {
        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);
        if (!((currency0 == address(0) && currency1 == pairToken) || (currency1 == address(0) && currency0 == pairToken))) {
            revert InvalidNativePairPool();
        }
    }

    function _zeroForOne(address input, address output, PoolKey calldata key)
        internal pure returns (bool)
    {
        return Currency.unwrap(key.currency0) == input
            && Currency.unwrap(key.currency1) == output;
    }

    function _launchPoolKey(
        IRobinhoodArenaManagerHelper manager,
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
}
