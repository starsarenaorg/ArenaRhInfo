// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IRobinhoodLaunchToken} from "../robinhood/interfaces/IRobinhoodLaunchToken.sol";
import {IArenaPoolDeployer} from "../robinhood/interfaces/IArenaPoolDeployer.sol";
import {
    IRobinhoodArenaManagerHelper,
    IRobinhoodHelperPermit2,
    IRobinhoodHelperUniversalRouter,
    IRobinhoodHelperWETH,
    IRobinhoodNativeManagerHelper
} from "./RobinhoodHelperInterfaces.sol";
import {RobinhoodV4SwapExecutor} from "./RobinhoodV4SwapExecutor.sol";

/// @notice Atomically launches, graduates, and buys from a new Robinhood v4 pool.
/// @dev The full configured bonding allocation is purchased first. Any paired
/// currency left after graduation is then swapped through the newly created pool.
contract RobinhoodSingleTxBuyer is RobinhoodV4SwapExecutor, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct NativeCreationParams {
        uint16 a;
        uint8 b;
        uint128 curveScaler;
        uint8 creatorFeeBasisPoints;
        address tokenCreatorAddress;
        uint256 tokenSplit;
        bool enableHolderRewards;
        string name;
        string symbol;
    }

    struct ArenaCreationParams {
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

    IRobinhoodNativeManagerHelper public immutable NATIVE_MANAGER;
    IRobinhoodArenaManagerHelper public immutable ARENA_MANAGER;
    IRobinhoodHelperWETH public immutable WETH;
    IERC20 public immutable ARENA;

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
    event ArenaTokenLaunchedAndBought(
        address indexed user,
        uint256 indexed tokenId,
        address indexed token,
        uint256 preBondTokenOut,
        uint256 postBondInput,
        uint256 postBondTokenOut
    );

    constructor(
        IRobinhoodNativeManagerHelper nativeManager_,
        IRobinhoodArenaManagerHelper arenaManager_,
        IRobinhoodHelperUniversalRouter universalRouter_,
        IRobinhoodHelperPermit2 permit2_
    ) RobinhoodV4SwapExecutor(universalRouter_, permit2_) {
        if (
            address(nativeManager_) == address(0)
                || address(nativeManager_).code.length == 0
                || address(arenaManager_) == address(0)
                || address(arenaManager_).code.length == 0
        ) revert InvalidManager();
        address weth = nativeManager_.WETH_ADDRESS();
        address arena = arenaManager_.ARENA_ADDRESS();
        if (
            weth == address(0) || weth.code.length == 0 || arena == address(0)
                || arena.code.length == 0
        ) revert InvalidManager();
        NATIVE_MANAGER = nativeManager_;
        ARENA_MANAGER = arenaManager_;
        WETH = IRobinhoodHelperWETH(weth);
        ARENA = IERC20(arena);
        IERC20(arena).forceApprove(address(arenaManager_), type(uint256).max);
    }

    function bondAndBuyFromLpOnNativeCreation(
        NativeCreationParams calldata params,
        uint256 minPostBondTokenOut,
        uint256 deadline
    ) external payable nonReentrant returns (address token, uint256 tokenOut) {
        IRobinhoodLaunchToken.Whitelist memory whitelist;
        return _nativeLaunch(params, whitelist, false, minPostBondTokenOut, deadline);
    }

    function bondAndBuyFromLpOnNativeCreationWithWhitelist(
        NativeCreationParams calldata params,
        IRobinhoodLaunchToken.Whitelist calldata whitelist,
        uint256 minPostBondTokenOut,
        uint256 deadline
    ) external payable nonReentrant returns (address token, uint256 tokenOut) {
        return _nativeLaunch(params, whitelist, true, minPostBondTokenOut, deadline);
    }

    function bondAndBuyFromLpOnArenaCreation(
        ArenaCreationParams calldata params,
        uint256 arenaToSpend,
        uint256 minPostBondTokenOut,
        uint256 deadline
    ) external nonReentrant returns (address token, uint256 tokenOut) {
        IRobinhoodLaunchToken.Whitelist memory whitelist;
        return _arenaLaunch(
            params,
            whitelist,
            false,
            arenaToSpend,
            minPostBondTokenOut,
            deadline
        );
    }

    function bondAndBuyFromLpOnArenaCreationWithWhitelist(
        ArenaCreationParams calldata params,
        uint256 arenaToSpend,
        IRobinhoodLaunchToken.Whitelist calldata whitelist,
        uint256 minPostBondTokenOut,
        uint256 deadline
    ) external nonReentrant returns (address token, uint256 tokenOut) {
        return _arenaLaunch(
            params,
            whitelist,
            true,
            arenaToSpend,
            minPostBondTokenOut,
            deadline
        );
    }

    function _nativeLaunch(
        NativeCreationParams calldata params,
        IRobinhoodLaunchToken.Whitelist memory whitelist,
        bool withWhitelist,
        uint256 minPostBondTokenOut,
        uint256 deadline
    ) internal returns (address token, uint256 tokenOut) {
        uint256 balanceBefore = address(this).balance - msg.value;
        uint256 tokenId = NATIVE_MANAGER.tokenIdentifier();
        uint256 preBondAmount = _nativeSaleAmount(params);

        _createNativeToken(
            params, whitelist, withWhitelist, preBondAmount, deadline
        );

        IRobinhoodNativeManagerHelper.TokenParameters memory tokenParams =
            NATIVE_MANAGER.getTokenParameters(tokenId);
        if (!tokenParams.lpDeployed) revert GraduationFailed();
        token = tokenParams.tokenContractAddress;
        uint256 postBondInput = address(this).balance - balanceBefore;
        if (postBondInput == 0) revert NoPostBondInput();

        WETH.deposit{value: postBondInput}();
        uint256 postBondOut = _swapExactInputSingle(
            _poolKey(
                address(WETH),
                token,
                NATIVE_MANAGER.getV4PoolInitParams().poolInitParams
            ),
            address(WETH) < token,
            postBondInput,
            minPostBondTokenOut,
            deadline
        );

        tokenOut = IERC20(token).balanceOf(address(this));
        if (tokenOut < preBondAmount + postBondOut) revert TokenTransferFailed();
        IERC20(token).safeTransfer(msg.sender, tokenOut);
        _refundWeth(msg.sender);
        emit NativeTokenLaunchedAndBought(
            msg.sender, tokenId, token, preBondAmount, postBondInput, postBondOut
        );
    }

    function _arenaLaunch(
        ArenaCreationParams calldata params,
        IRobinhoodLaunchToken.Whitelist memory whitelist,
        bool withWhitelist,
        uint256 arenaToSpend,
        uint256 minPostBondTokenOut,
        uint256 deadline
    ) internal returns (address token, uint256 tokenOut) {
        uint256 arenaBefore = ARENA.balanceOf(address(this));
        ARENA.safeTransferFrom(msg.sender, address(this), arenaToSpend);
        uint256 tokenId = ARENA_MANAGER.tokenIdentifier();
        uint256 preBondAmount = _arenaSaleAmount(params);

        _createArenaToken(params, whitelist, withWhitelist, preBondAmount);

        IRobinhoodArenaManagerHelper.TokenParameters memory tokenParams =
            ARENA_MANAGER.getTokenParameters(tokenId);
        if (!tokenParams.lpDeployed) revert GraduationFailed();
        token = tokenParams.tokenContractAddress;
        uint256 postBondInput = ARENA.balanceOf(address(this)) - arenaBefore;
        if (postBondInput == 0) revert NoPostBondInput();

        uint256 postBondOut = _swapExactInputSingle(
            _poolKey(
                address(ARENA),
                token,
                ARENA_MANAGER.getV4PoolInitParams().poolInitParams
            ),
            address(ARENA) < token,
            postBondInput,
            minPostBondTokenOut,
            deadline
        );

        tokenOut = IERC20(token).balanceOf(address(this));
        if (tokenOut < preBondAmount + postBondOut) revert TokenTransferFailed();
        IERC20(token).safeTransfer(msg.sender, tokenOut);
        uint256 arenaRefund = ARENA.balanceOf(address(this)) - arenaBefore;
        if (arenaRefund != 0) ARENA.safeTransfer(msg.sender, arenaRefund);
        emit ArenaTokenLaunchedAndBought(
            msg.sender, tokenId, token, preBondAmount, postBondInput, postBondOut
        );
    }

    function _nativeSaleAmount(NativeCreationParams calldata params)
        internal
        view
        returns (uint256)
    {
        uint256 allowed = NATIVE_MANAGER.allowedTotalSupplyWithParameters(
            params.a, params.b, params.curveScaler, params.tokenSplit
        );
        if (allowed == 0) revert CurveNotConfigured();
        return allowed * params.tokenSplit / 100;
    }

    function _createNativeToken(
        NativeCreationParams calldata params,
        IRobinhoodLaunchToken.Whitelist memory whitelist,
        bool withWhitelist,
        uint256 preBondAmount,
        uint256 deadline
    ) internal {
        NATIVE_MANAGER.setNextLaunchHolderRewards(params.enableHolderRewards);
        if (withWhitelist) {
            NATIVE_MANAGER.createTokenWithWL{value: msg.value}(
                params.a,
                params.b,
                params.curveScaler,
                params.creatorFeeBasisPoints,
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
            NATIVE_MANAGER.createToken{value: msg.value}(
                params.a,
                params.b,
                params.curveScaler,
                params.creatorFeeBasisPoints,
                params.tokenCreatorAddress,
                params.tokenSplit,
                params.name,
                params.symbol,
                preBondAmount,
                msg.value,
                deadline
            );
        }
    }

    function _createArenaToken(
        ArenaCreationParams calldata params,
        IRobinhoodLaunchToken.Whitelist memory whitelist,
        bool withWhitelist,
        uint256 preBondAmount
    ) internal {
        ARENA_MANAGER.setNextLaunchHolderRewards(params.enableHolderRewards);
        if (withWhitelist) {
            ARENA_MANAGER.createTokenWithWL(
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
        } else {
            ARENA_MANAGER.createToken(
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
    }

    function _arenaSaleAmount(ArenaCreationParams calldata params)
        internal
        view
        returns (uint256)
    {
        uint256 allowed = ARENA_MANAGER.allowedTotalSupplyWithParameters(
            params.a, params.b, params.curveScaler, params.tokenSplit
        );
        if (allowed == 0) revert CurveNotConfigured();
        return allowed * params.tokenSplit / 100;
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

    function _refundWeth(address recipient) internal {
        uint256 refund = WETH.balanceOf(address(this));
        if (refund == 0) return;
        WETH.withdraw(refund);
        (bool success,) = payable(recipient).call{value: refund}("");
        if (!success) revert NativeTransferFailed();
    }
}
