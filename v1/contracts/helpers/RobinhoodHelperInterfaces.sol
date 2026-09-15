// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IRobinhoodLaunchToken} from "../robinhood/interfaces/IRobinhoodLaunchToken.sol";
import {IArenaPoolDeployer} from "../robinhood/interfaces/IArenaPoolDeployer.sol";

interface IRobinhoodHelperUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline)
        external
        payable;

    function poolManager() external view returns (address);
}

interface IRobinhoodHelperPermit2 {
    function allowance(address user, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);

    function approve(address token, address spender, uint160 amount, uint48 expiration)
        external;
}

interface IRobinhoodHelperWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

interface IRobinhoodNativeManagerHelper {
    function setNextLaunchHolderRewards(bool enabled) external;
    struct TokenParameters {
        uint128 curveScaler;
        uint16 a;
        uint8 b;
        bool lpDeployed;
        uint8 lpPercentage;
        uint8 salePercentage;
        uint8 creatorFeeBasisPoints;
        address creatorAddress;
        address pairAddress;
        address tokenContractAddress;
    }

    struct V4PoolInitParams {
        IArenaPoolDeployer.PoolInitParams poolInitParams;
        uint16 creatorFeePpm;
        uint160 invertedStartingPrice;
    }

    function tokenIdentifier() external view returns (uint256);
    function tokenSupply(uint256 tokenId) external view returns (uint256);
    function tokenBalanceOf(uint256 tokenId) external view returns (uint256);
    function tokenCreationBuyFeeAmount() external view returns (uint88);
    function WETH_ADDRESS() external view returns (address);

    function allowedTotalSupplyWithParameters(
        uint16 a,
        uint8 b,
        uint128 curveScaler,
        uint256 tokenSplit
    ) external view returns (uint256);

    function getMaxTokensForSale(uint256 tokenId) external view returns (uint256);
    function getTokenParameters(uint256 tokenId)
        external
        view
        returns (TokenParameters memory);
    function getV4PoolInitParams() external view returns (V4PoolInitParams memory);

    function calculateCostWithFees(uint256 amountInToken, uint256 tokenId)
        external
        view
        returns (uint256);

    function calculateCostScaledParametric(
        uint256 amountInWei,
        uint256 supplyInWei,
        uint256 a,
        uint256 b,
        uint256 curveScaler
    ) external pure returns (uint256);

    function calculateInitialBuyCostScaledParametricWithFees(
        uint256 amountInWei,
        uint256 supplyInWei,
        uint256 a,
        uint256 b,
        uint256 curveScaler,
        uint256 creatorFeeBasisPoints
    ) external view returns (uint256);

    function createToken(
        uint16 a,
        uint8 b,
        uint128 curveScaler,
        uint8 creatorFeeBasisPoints,
        address tokenCreatorAddress,
        uint256 tokenSplit,
        string calldata name,
        string calldata symbol,
        uint256 amount,
        uint256 maxTotalCost,
        uint256 deadline
    ) external payable;

    function createTokenWithWL(
        uint16 a,
        uint8 b,
        uint128 curveScaler,
        uint8 creatorFeeBasisPoints,
        address tokenCreatorAddress,
        uint256 tokenSplit,
        string calldata name,
        string calldata symbol,
        uint256 amount,
        IRobinhoodLaunchToken.Whitelist calldata whitelist,
        uint256 maxTotalCost,
        uint256 deadline
    ) external payable;
}

interface IRobinhoodArenaManagerHelper {
    function setNextLaunchHolderRewards(bool enabled) external;
    struct TokenParameters {
        uint128 curveScaler;
        uint32 a;
        uint8 b;
        bool lpDeployed;
        uint8 lpPercentage;
        uint8 salePercentage;
        uint8 creatorFeeBasisPoints;
        address creatorAddress;
        address pairAddress;
        address tokenContractAddress;
    }

    struct V4PoolInitParams {
        IArenaPoolDeployer.PoolInitParams poolInitParams;
        uint16 creatorFeePpm;
        uint160 invertedStartingPrice;
    }

    function ARENA_ADDRESS() external view returns (address);
    function tokenIdentifier() external view returns (uint256);
    function tokenSupply(uint256 tokenId) external view returns (uint256);
    function tokenBalanceOf(uint256 tokenId) external view returns (uint256);
    function tokenCreationBuyFeeAmount() external view returns (uint88);

    function allowedTotalSupplyWithParameters(
        uint32 a,
        uint8 b,
        uint128 curveScaler,
        uint256 tokenSplit
    ) external view returns (uint256);

    function getMaxTokensForSale(uint256 tokenId) external view returns (uint256);
    function getTokenParameters(uint256 tokenId)
        external
        view
        returns (TokenParameters memory);
    function getV4PoolInitParams() external view returns (V4PoolInitParams memory);

    function calculateCostWithFees(uint256 amountInToken, uint256 tokenId)
        external
        view
        returns (uint256);
    function calculateRewardWithFees(uint256 amountInToken, uint256 tokenId)
        external
        view
        returns (uint256);

    function calculateCostScaledParametric(
        uint256 amountInWei,
        uint256 supplyInWei,
        uint256 a,
        uint256 b,
        uint256 curveScaler
    ) external pure returns (uint256);

    function calculateCostScaledParametricWithFees(
        uint256 amountInWei,
        uint256 supplyInWei,
        uint256 a,
        uint256 b,
        uint256 curveScaler,
        uint256 creatorFeeBasisPoints
    ) external view returns (uint256);

    function createToken(
        uint32 a,
        uint8 b,
        uint128 curveScaler,
        uint8 creatorFeeBasisPoints,
        address tokenCreatorAddress,
        uint256 tokenSplit,
        string calldata name,
        string calldata symbol,
        uint256 amount
    ) external;

    function createTokenWithWL(
        uint32 a,
        uint8 b,
        uint128 curveScaler,
        uint8 creatorFeeBasisPoints,
        address tokenCreatorAddress,
        uint256 tokenSplit,
        string calldata name,
        string calldata symbol,
        uint256 amount,
        IRobinhoodLaunchToken.Whitelist calldata whitelist
    ) external;

    function buyAndCreateLpIfPossibleWithUser(
        uint256 amount,
        uint256 tokenId,
        address user,
        uint256 maxArenaToSpend
    ) external;

    function sellWithUser(
        uint256 amount,
        uint256 tokenId,
        address user,
        uint256 minArenaToReceive
    ) external returns (uint256 amountOut);
}

interface IRobinhoodHelperStateView {
    function poolManager() external view returns (IPoolManager);
    function getSlot0(PoolId poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
    function getLiquidity(PoolId poolId) external view returns (uint128 liquidity);
}
