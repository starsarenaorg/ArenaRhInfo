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

interface IPrismBuyerRegistry {
    function isApprovedManager(address manager) external view returns (bool);
}

/// @notice Atomically launches, graduates, and performs the first v4 purchase
///         through any registry-approved Arena Prism manager.
contract RobinhoodPrismBuyer is RobinhoodV4SwapExecutor, ReentrancyGuard {
    using SafeERC20 for IERC20;

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

    struct Settlement {
        address token;
        uint256 pairBalanceBefore;
        uint256 preBondAmount;
        uint256 minPostBondTokenOut;
        uint256 deadline;
    }

    IPrismBuyerRegistry public immutable REGISTRY;

    error InvalidRegistry();
    error ManagerNotApproved();
    error CurveNotConfigured();
    error GraduationFailed();
    error NoPostBondInput();
    error TokenTransferFailed();

    event PrismTokenLaunchedAndBought(
        address indexed user,
        address indexed manager,
        address indexed pairToken,
        uint256 tokenId,
        address token,
        uint256 preBondTokenOut,
        uint256 postBondInput,
        uint256 postBondTokenOut
    );

    constructor(
        IPrismBuyerRegistry registry,
        IRobinhoodHelperUniversalRouter universalRouter,
        IRobinhoodHelperPermit2 permit2
    ) RobinhoodV4SwapExecutor(universalRouter, permit2) {
        if (address(registry) == address(0) || address(registry).code.length == 0) {
            revert InvalidRegistry();
        }
        REGISTRY = registry;
    }

    function bondAndBuyFromLpOnCreation(
        CreationParams calldata params,
        uint256 pairTokenToSpend,
        uint256 minPostBondTokenOut,
        uint256 deadline
    ) external nonReentrant returns (address token, uint256 tokenOut) {
        IRobinhoodLaunchToken.Whitelist memory whitelist;
        return _launch(
            params, whitelist, false, pairTokenToSpend, minPostBondTokenOut, deadline
        );
    }

    function bondAndBuyFromLpOnCreationWithWhitelist(
        CreationParams calldata params,
        uint256 pairTokenToSpend,
        IRobinhoodLaunchToken.Whitelist calldata whitelist,
        uint256 minPostBondTokenOut,
        uint256 deadline
    ) external nonReentrant returns (address token, uint256 tokenOut) {
        return _launch(
            params, whitelist, true, pairTokenToSpend, minPostBondTokenOut, deadline
        );
    }

    function _launch(
        CreationParams calldata params,
        IRobinhoodLaunchToken.Whitelist memory whitelist,
        bool withWhitelist,
        uint256 pairTokenToSpend,
        uint256 minPostBondTokenOut,
        uint256 deadline
    ) internal returns (address token, uint256 tokenOut) {
        if (!REGISTRY.isApprovedManager(params.manager)) revert ManagerNotApproved();
        IRobinhoodArenaManagerHelper manager = IRobinhoodArenaManagerHelper(params.manager);
        IERC20 pairToken = IERC20(manager.ARENA_ADDRESS());
        uint256 balanceBefore = pairToken.balanceOf(address(this));
        pairToken.safeTransferFrom(msg.sender, address(this), pairTokenToSpend);
        pairToken.forceApprove(params.manager, pairTokenToSpend);
        (uint256 tokenId, uint256 preBondAmount) =
            _createAndGraduate(manager, params, whitelist, withWhitelist);

        token = manager.getTokenParameters(tokenId).tokenContractAddress;
        uint256 postBondInput;
        uint256 postBondOut;
        (tokenOut, postBondInput, postBondOut) = _swapAndSettle(
            manager,
            pairToken,
            Settlement(
                token,
                balanceBefore,
                preBondAmount,
                minPostBondTokenOut,
                deadline
            )
        );
        emit PrismTokenLaunchedAndBought(
            msg.sender, params.manager, address(pairToken), tokenId, token,
            preBondAmount, postBondInput, postBondOut
        );
    }

    function _swapAndSettle(
        IRobinhoodArenaManagerHelper manager,
        IERC20 pairToken,
        Settlement memory settlement
    ) internal returns (uint256 tokenOut, uint256 postBondInput, uint256 postBondOut) {
        postBondInput =
            pairToken.balanceOf(address(this)) - settlement.pairBalanceBefore;
        if (postBondInput == 0) revert NoPostBondInput();
        postBondOut = _swapExactInputSingle(
            _poolKey(
                address(pairToken),
                settlement.token,
                manager.getV4PoolInitParams().poolInitParams
            ),
            address(pairToken) < settlement.token,
            postBondInput,
            settlement.minPostBondTokenOut,
            settlement.deadline
        );
        tokenOut = IERC20(settlement.token).balanceOf(address(this));
        if (tokenOut < settlement.preBondAmount + postBondOut) {
            revert TokenTransferFailed();
        }
        IERC20(settlement.token).safeTransfer(msg.sender, tokenOut);
        uint256 refund =
            pairToken.balanceOf(address(this)) - settlement.pairBalanceBefore;
        if (refund != 0) pairToken.safeTransfer(msg.sender, refund);
        pairToken.forceApprove(address(manager), 0);
    }

    function _createAndGraduate(
        IRobinhoodArenaManagerHelper manager,
        CreationParams calldata params,
        IRobinhoodLaunchToken.Whitelist memory whitelist,
        bool withWhitelist
    ) internal returns (uint256 tokenId, uint256 preBondAmount) {
        tokenId = manager.tokenIdentifier();
        uint256 allowed = manager.allowedTotalSupplyWithParameters(
            params.a, params.b, params.curveScaler, params.tokenSplit
        );
        if (allowed == 0) revert CurveNotConfigured();
        preBondAmount = allowed * params.tokenSplit / 100;
        manager.setNextLaunchHolderRewards(params.enableHolderRewards);
        if (withWhitelist) {
            _createWithWhitelist(manager, params, preBondAmount, whitelist);
        } else {
            _createWithoutWhitelist(manager, params, preBondAmount);
        }

        IRobinhoodArenaManagerHelper.TokenParameters memory tokenParams =
            manager.getTokenParameters(tokenId);
        if (!tokenParams.lpDeployed) revert GraduationFailed();
    }

    function _createWithoutWhitelist(
        IRobinhoodArenaManagerHelper manager,
        CreationParams calldata params,
        uint256 preBondAmount
    ) internal {
        manager.createToken(
            params.a,
            params.b,
            params.curveScaler,
            params.creatorFeeBasisPoints,
            params.tokenCreatorAddress,
            params.tokenSplit,
            params.name,
            params.symbol,
            preBondAmount
        );
    }

    function _createWithWhitelist(
        IRobinhoodArenaManagerHelper manager,
        CreationParams calldata params,
        uint256 preBondAmount,
        IRobinhoodLaunchToken.Whitelist memory whitelist
    ) internal {
        manager.createTokenWithWL(
            params.a,
            params.b,
            params.curveScaler,
            params.creatorFeeBasisPoints,
            params.tokenCreatorAddress,
            params.tokenSplit,
            params.name,
            params.symbol,
            preBondAmount,
            whitelist
        );
    }

    function _poolKey(
        address pairedToken,
        address launchToken,
        IArenaPoolDeployer.PoolInitParams memory config
    ) internal pure returns (PoolKey memory) {
        address token0 = pairedToken < launchToken ? pairedToken : launchToken;
        address token1 = pairedToken < launchToken ? launchToken : pairedToken;
        return PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: config.fee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(config.hookContract)
        });
    }
}
