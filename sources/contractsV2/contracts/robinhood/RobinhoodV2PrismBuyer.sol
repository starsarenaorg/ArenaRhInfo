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
    IRobinhoodHelperUniversalRouter
} from "../../../contracts/contracts/helpers/RobinhoodHelperInterfaces.sol";
import {RobinhoodV4SwapExecutor} from "../../../contracts/contracts/helpers/RobinhoodV4SwapExecutor.sol";
import {
    IRobinhoodV2PrismManager,
    IRobinhoodV2PrismRegistry
} from "./interfaces/IRobinhoodV2Periphery.sol";

/// @notice Atomically launches, graduates, and performs the first V4 purchase
///         through any registry-approved V2 Prism manager.
contract RobinhoodV2PrismBuyer is RobinhoodV4SwapExecutor, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct CreationParams {
        address manager;
        uint32 a;
        uint8 b;
        uint128 curveScaler;
        uint8 creatorFeeBasisPoints;
        uint16 dividendFeeBasisPoints;
        address tokenCreatorAddress;
        uint256 tokenSplit;
        string name;
        string symbol;
    }

    struct Settlement {
        uint256 tokenId;
        address token;
        uint256 pairBalanceBefore;
        uint256 preBondAmount;
        uint256 minPostBondTokenOut;
        uint256 deadline;
    }

    IRobinhoodV2PrismRegistry public immutable REGISTRY;

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
        IRobinhoodV2PrismRegistry registry_,
        IRobinhoodHelperUniversalRouter universalRouter_,
        IRobinhoodHelperPermit2 permit2_
    ) RobinhoodV4SwapExecutor(universalRouter_, permit2_) {
        if (
            address(registry_) == address(0)
                || address(registry_).code.length == 0
        ) revert InvalidRegistry();
        REGISTRY = registry_;
    }

    function bondAndBuyFromLpOnCreation(
        CreationParams calldata params,
        uint256 pairTokenToSpend,
        uint256 minPostBondTokenOut,
        uint256 deadline
    ) external nonReentrant returns (address token, uint256 tokenOut) {
        IRobinhoodLaunchToken.Whitelist memory whitelist;
        return _launch(
            params,
            whitelist,
            false,
            pairTokenToSpend,
            minPostBondTokenOut,
            deadline
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
            params,
            whitelist,
            true,
            pairTokenToSpend,
            minPostBondTokenOut,
            deadline
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
        if (!REGISTRY.isApprovedManager(params.manager)) {
            revert ManagerNotApproved();
        }
        IRobinhoodV2PrismManager manager =
            IRobinhoodV2PrismManager(params.manager);
        IERC20 pairToken = IERC20(manager.PAIR_TOKEN());
        if (REGISTRY.pairTokenForManager(params.manager) != address(pairToken)) {
            revert ManagerNotApproved();
        }

        uint256 pairBalanceBefore = pairToken.balanceOf(address(this));
        pairToken.safeTransferFrom(msg.sender, address(this), pairTokenToSpend);
        pairToken.forceApprove(params.manager, pairTokenToSpend);

        (uint256 tokenId, uint256 preBondAmount) =
            _createAndGraduate(
                manager,
                params,
                whitelist,
                withWhitelist,
                pairTokenToSpend,
                deadline
            );
        token = manager.getTokenParameters(tokenId).tokenContractAddress;

        uint256 postBondInput;
        uint256 postBondOut;
        (tokenOut, postBondInput, postBondOut) = _swapAndSettle(
            manager,
            pairToken,
            Settlement({
                tokenId: tokenId,
                token: token,
                pairBalanceBefore: pairBalanceBefore,
                preBondAmount: preBondAmount,
                minPostBondTokenOut: minPostBondTokenOut,
                deadline: deadline
            })
        );
        emit PrismTokenLaunchedAndBought(
            msg.sender,
            params.manager,
            address(pairToken),
            tokenId,
            token,
            preBondAmount,
            postBondInput,
            postBondOut
        );
    }

    function _swapAndSettle(
        IRobinhoodV2PrismManager manager,
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
        manager.dividendController().claimFor(
            settlement.tokenId, address(this), msg.sender
        );

        uint256 refund =
            pairToken.balanceOf(address(this)) - settlement.pairBalanceBefore;
        if (refund != 0) pairToken.safeTransfer(msg.sender, refund);
        pairToken.forceApprove(address(manager), 0);
    }

    function _createAndGraduate(
        IRobinhoodV2PrismManager manager,
        CreationParams calldata params,
        IRobinhoodLaunchToken.Whitelist memory whitelist,
        bool withWhitelist,
        uint256 maxTotalCost,
        uint256 deadline
    ) internal returns (uint256 tokenId, uint256 preBondAmount) {
        tokenId = manager.tokenIdentifier();
        uint256 allowed = manager.allowedTotalSupplyWithParameters(
            params.a, params.b, params.curveScaler, params.tokenSplit
        );
        if (allowed == 0) revert CurveNotConfigured();
        preBondAmount = allowed * params.tokenSplit / 100;
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
                preBondAmount,
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
                preBondAmount,
                maxTotalCost,
                deadline
            );
        }

        if (!manager.getTokenParameters(tokenId).lpDeployed) {
            revert GraduationFailed();
        }
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
