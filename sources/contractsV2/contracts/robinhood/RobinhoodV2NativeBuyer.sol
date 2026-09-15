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
import {IRobinhoodV2NativeManager} from "./interfaces/IRobinhoodV2Periphery.sol";

/// @notice Atomically launches, graduates, and performs the first V4 purchase
///         through the V2 native ETH manager.
contract RobinhoodV2NativeBuyer is RobinhoodV4SwapExecutor, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct CreationParams {
        uint16 a;
        uint8 b;
        uint128 curveScaler;
        uint8 creatorFeeBasisPoints;
        uint16 dividendFeeBasisPoints;
        address tokenCreatorAddress;
        uint256 tokenSplit;
        string name;
        string symbol;
    }

    IRobinhoodV2NativeManager public immutable TOKEN_MANAGER;
    IRobinhoodHelperWETH public immutable WETH;

    error InvalidManager();
    error CurveNotConfigured();
    error GraduationFailed();
    error NoPostBondInput();
    error TokenTransferFailed();
    error NativeTransferFailed();

    event NativeTokenLaunchedAndBought(
        address indexed user,
        uint256 indexed tokenId,
        address indexed token,
        uint256 preBondTokenOut,
        uint256 postBondInput,
        uint256 postBondTokenOut
    );

    constructor(
        IRobinhoodV2NativeManager tokenManager_,
        IRobinhoodHelperUniversalRouter universalRouter_,
        IRobinhoodHelperPermit2 permit2_
    ) RobinhoodV4SwapExecutor(universalRouter_, permit2_) {
        if (
            address(tokenManager_) == address(0)
                || address(tokenManager_).code.length == 0
        ) revert InvalidManager();
        address weth = tokenManager_.WETH_ADDRESS();
        if (weth == address(0) || weth.code.length == 0) revert InvalidManager();
        TOKEN_MANAGER = tokenManager_;
        WETH = IRobinhoodHelperWETH(weth);
    }

    function bondAndBuyFromLpOnCreation(
        CreationParams calldata params,
        uint256 minPostBondTokenOut,
        uint256 deadline
    ) external payable nonReentrant returns (address token, uint256 tokenOut) {
        IRobinhoodLaunchToken.Whitelist memory whitelist;
        return _launch(params, whitelist, false, minPostBondTokenOut, deadline);
    }

    function bondAndBuyFromLpOnCreationWithWhitelist(
        CreationParams calldata params,
        IRobinhoodLaunchToken.Whitelist calldata whitelist,
        uint256 minPostBondTokenOut,
        uint256 deadline
    ) external payable nonReentrant returns (address token, uint256 tokenOut) {
        return _launch(params, whitelist, true, minPostBondTokenOut, deadline);
    }

    function _launch(
        CreationParams calldata params,
        IRobinhoodLaunchToken.Whitelist memory whitelist,
        bool withWhitelist,
        uint256 minPostBondTokenOut,
        uint256 deadline
    ) internal returns (address token, uint256 tokenOut) {
        uint256 nativeBalanceBefore = address(this).balance - msg.value;
        uint256 wethBalanceBefore = WETH.balanceOf(address(this));
        uint256 tokenId = TOKEN_MANAGER.tokenIdentifier();
        uint256 preBondAmount = _saleAmount(params);

        if (withWhitelist) {
            TOKEN_MANAGER.createTokenWithWL{value: msg.value}(
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
                msg.value,
                deadline
            );
        } else {
            TOKEN_MANAGER.createToken{value: msg.value}(
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
                msg.value,
                deadline
            );
        }

        IRobinhoodV2NativeManager.TokenParameters memory tokenParams =
            TOKEN_MANAGER.getTokenParameters(tokenId);
        if (!tokenParams.lpDeployed) revert GraduationFailed();
        token = tokenParams.tokenContractAddress;

        uint256 postBondInput = address(this).balance - nativeBalanceBefore;
        if (postBondInput == 0) revert NoPostBondInput();
        WETH.deposit{value: postBondInput}();
        uint256 postBondOut = _swapExactInputSingle(
            _poolKey(
                address(WETH),
                token,
                TOKEN_MANAGER.getV4PoolInitParams().poolInitParams
            ),
            address(WETH) < token,
            postBondInput,
            minPostBondTokenOut,
            deadline
        );

        tokenOut = IERC20(token).balanceOf(address(this));
        if (tokenOut < preBondAmount + postBondOut) {
            revert TokenTransferFailed();
        }
        IERC20(token).safeTransfer(msg.sender, tokenOut);
        TOKEN_MANAGER.dividendController().claimFor(
            tokenId, address(this), address(this)
        );
        _refundWeth(msg.sender, wethBalanceBefore);

        emit NativeTokenLaunchedAndBought(
            msg.sender,
            tokenId,
            token,
            preBondAmount,
            postBondInput,
            postBondOut
        );
    }

    function _saleAmount(CreationParams calldata params)
        internal
        view
        returns (uint256)
    {
        uint256 allowed = TOKEN_MANAGER.allowedTotalSupplyWithParameters(
            params.a, params.b, params.curveScaler, params.tokenSplit
        );
        if (allowed == 0) revert CurveNotConfigured();
        return allowed * params.tokenSplit / 100;
    }

    function _refundWeth(address recipient, uint256 balanceBefore) internal {
        uint256 refund = WETH.balanceOf(address(this)) - balanceBefore;
        if (refund == 0) return;
        WETH.withdraw(refund);
        (bool success,) = payable(recipient).call{value: refund}("");
        if (!success) revert NativeTransferFailed();
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
