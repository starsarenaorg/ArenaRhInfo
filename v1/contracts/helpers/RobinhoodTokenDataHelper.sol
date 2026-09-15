// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IArenaPoolDeployer} from "../robinhood/interfaces/IArenaPoolDeployer.sol";
import {
    IRobinhoodArenaManagerHelper,
    IRobinhoodHelperStateView,
    IRobinhoodNativeManagerHelper
} from "./RobinhoodHelperInterfaces.sol";

/// @notice Batched curve and post-graduation market data for Robinhood tokens.
contract RobinhoodTokenDataHelper {
    using PoolIdLibrary for PoolKey;

    uint256 public constant PRICE_SCALE = 1e18;

    enum PairKind {
        NATIVE,
        ARENA
    }

    struct TokenRequest {
        uint256 tokenId;
        PairKind pairKind;
    }

    struct TokenData {
        uint256 tokenId;
        address tokenAddress;
        address pairedToken;
        uint256 supply;
        uint256 pairedReserve;
        uint256 price;
        uint256 marketCap;
        uint128 liquidity;
        bool lpDeployed;
        bytes32 poolId;
    }

    IRobinhoodNativeManagerHelper public immutable NATIVE_MANAGER;
    IRobinhoodArenaManagerHelper public immutable ARENA_MANAGER;
    IRobinhoodHelperStateView public immutable STATE_VIEW;

    error InvalidDependency();
    error UnknownToken();
    error InvalidPoolPrice();

    constructor(
        IRobinhoodNativeManagerHelper nativeManager_,
        IRobinhoodArenaManagerHelper arenaManager_,
        IRobinhoodHelperStateView stateView_
    ) {
        if (
            address(nativeManager_) == address(0)
                || address(arenaManager_) == address(0)
                || address(stateView_) == address(0)
        ) revert InvalidDependency();
        NATIVE_MANAGER = nativeManager_;
        ARENA_MANAGER = arenaManager_;
        STATE_VIEW = stateView_;
    }

    function getTokenData(TokenRequest[] calldata requests)
        external
        view
        returns (TokenData[] memory response)
    {
        response = new TokenData[](requests.length);
        for (uint256 i; i < requests.length; ++i) {
            response[i] = requests[i].pairKind == PairKind.NATIVE
                ? _nativeTokenData(requests[i].tokenId)
                : _arenaTokenData(requests[i].tokenId);
        }
    }

    function _nativeTokenData(uint256 tokenId)
        internal
        view
        returns (TokenData memory data)
    {
        IRobinhoodNativeManagerHelper.TokenParameters memory params =
            NATIVE_MANAGER.getTokenParameters(tokenId);
        if (params.tokenContractAddress == address(0)) revert UnknownToken();
        data.tokenId = tokenId;
        data.tokenAddress = params.tokenContractAddress;
        data.pairedToken = NATIVE_MANAGER.WETH_ADDRESS();
        data.supply = IERC20(data.tokenAddress).totalSupply();
        data.lpDeployed = params.lpDeployed;
        if (!params.lpDeployed) {
            data.pairedReserve = NATIVE_MANAGER.tokenBalanceOf(tokenId);
            data.price = NATIVE_MANAGER.calculateCostWithFees(1, tokenId);
        } else {
            IRobinhoodNativeManagerHelper.V4PoolInitParams memory config =
                NATIVE_MANAGER.getV4PoolInitParams();
            (data.price, data.liquidity, data.poolId) = _poolData(
                data.tokenAddress, data.pairedToken, config.poolInitParams
            );
        }
        data.marketCap = FullMath.mulDiv(data.price, data.supply, PRICE_SCALE);
    }

    function _arenaTokenData(uint256 tokenId)
        internal
        view
        returns (TokenData memory data)
    {
        IRobinhoodArenaManagerHelper.TokenParameters memory params =
            ARENA_MANAGER.getTokenParameters(tokenId);
        if (params.tokenContractAddress == address(0)) revert UnknownToken();
        data.tokenId = tokenId;
        data.tokenAddress = params.tokenContractAddress;
        data.pairedToken = ARENA_MANAGER.ARENA_ADDRESS();
        data.supply = IERC20(data.tokenAddress).totalSupply();
        data.lpDeployed = params.lpDeployed;
        if (!params.lpDeployed) {
            data.pairedReserve = ARENA_MANAGER.tokenBalanceOf(tokenId);
            data.price = ARENA_MANAGER.calculateCostWithFees(1, tokenId);
        } else {
            IRobinhoodArenaManagerHelper.V4PoolInitParams memory config =
                ARENA_MANAGER.getV4PoolInitParams();
            (data.price, data.liquidity, data.poolId) = _poolData(
                data.tokenAddress, data.pairedToken, config.poolInitParams
            );
        }
        data.marketCap = FullMath.mulDiv(data.price, data.supply, PRICE_SCALE);
    }

    function _poolData(
        address token,
        address pairedToken,
        IArenaPoolDeployer.PoolInitParams memory config
    ) internal view returns (uint256 price, uint128 liquidity, bytes32 poolId) {
        bool tokenIsCurrency0 = token < pairedToken;
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(tokenIsCurrency0 ? token : pairedToken),
            currency1: Currency.wrap(tokenIsCurrency0 ? pairedToken : token),
            fee: config.fee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(config.hookContract)
        });
        poolId = PoolId.unwrap(key.toId());
        (uint160 sqrtPriceX96,,,) = STATE_VIEW.getSlot0(key.toId());
        if (sqrtPriceX96 == 0) revert InvalidPoolPrice();
        liquidity = STATE_VIEW.getLiquidity(key.toId());

        uint256 sqrt = uint256(sqrtPriceX96);
        if (tokenIsCurrency0) {
            price = FullMath.mulDiv(
                sqrt, sqrt * PRICE_SCALE, uint256(FixedPoint96.Q96) ** 2
            );
        } else {
            uint256 reciprocalSqrtX96 = FullMath.mulDiv(
                FixedPoint96.Q96, FixedPoint96.Q96, sqrt
            );
            price = FullMath.mulDiv(
                reciprocalSqrtX96,
                reciprocalSqrtX96 * PRICE_SCALE,
                uint256(FixedPoint96.Q96) ** 2
            );
        }
    }
}
