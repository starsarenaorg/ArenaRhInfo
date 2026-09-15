// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IRobinhoodLaunchToken} from "../../../../contracts/contracts/robinhood/interfaces/IRobinhoodLaunchToken.sol";
import {IArenaPoolDeployer} from "../../../../contracts/contracts/robinhood/interfaces/IArenaPoolDeployer.sol";
import {IRobinhoodDividendController} from "./IRobinhoodDividendController.sol";

interface IRobinhoodV2FeeHelperQuote {
    struct ProtocolFeeSettings {
        address recipient;
        uint16 protocolFeePpm;
        uint16 referralFeePpm;
    }

    function getProtocolFeeSettings()
        external
        view
        returns (ProtocolFeeSettings memory);
}

interface IRobinhoodV2NativeManager {
    struct TokenParameters {
        uint128 curveScaler;
        uint16 a;
        uint8 b;
        bool lpDeployed;
        uint8 lpPercentage;
        uint8 salePercentage;
        uint8 creatorFeeBasisPoints;
        uint16 dividendFeeBasisPoints;
        address creatorAddress;
        address creatorFeeRecipient;
        address postBondCreatorFeeRecipient;
        address pairAddress;
        address tokenContractAddress;
        uint16 postBondCreatorFeePpm;
    }

    struct V4PoolInitParams {
        IArenaPoolDeployer.PoolInitParams poolInitParams;
        uint160 invertedStartingPrice;
    }

    function WETH_ADDRESS() external view returns (address);
    function tokenIdentifier() external view returns (uint256);
    function tokenCreationBuyFeeAmount() external view returns (uint88);
    function dividendController()
        external
        view
        returns (IRobinhoodDividendController);
    function dividendFeeHelper() external view returns (address);
    function getMaxTokensForSale(uint256 tokenId) external view returns (uint256);
    function getTokenParameters(uint256 tokenId)
        external
        view
        returns (TokenParameters memory);
    function getV4PoolInitParams()
        external
        view
        returns (V4PoolInitParams memory);
    function allowedTotalSupplyWithParameters(
        uint16 a,
        uint8 b,
        uint128 curveScaler,
        uint256 tokenSplit
    ) external view returns (uint256);
    function calculateCostWithFees(uint256 amountInToken, uint256 tokenId)
        external
        view
        returns (uint256);
    function calculateRewardWithFees(uint256 amount, uint256 tokenId)
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
        uint256 creatorFeeBasisPoints,
        uint256 dividendFeeBasisPoints
    ) external view returns (uint256);
    function createToken(
        uint16 a,
        uint8 b,
        uint128 curveScaler,
        uint8 creatorFeeBasisPoints,
        uint16 dividendFeeBasisPoints,
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
        uint16 dividendFeeBasisPoints,
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

interface IRobinhoodV2PrismManager {
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
        uint16 dividendFeeBasisPoints;
        address creatorFeeRecipient;
        address postBondCreatorFeeRecipient;
        uint16 postBondCreatorFeePpm;
    }

    struct V4PoolInitParams {
        IArenaPoolDeployer.PoolInitParams poolInitParams;
        uint16 creatorFeePpm;
        uint160 invertedStartingPrice;
    }

    function PAIR_TOKEN() external view returns (address);
    function ARENA_ADDRESS() external view returns (address);
    function NATIVE_HELPER() external view returns (address);
    function tokenIdentifier() external view returns (uint256);
    function tokenCreationBuyFeeAmount() external view returns (uint88);
    function dividendController()
        external
        view
        returns (IRobinhoodDividendController);
    function dividendFeeHelper() external view returns (address);
    function getMaxTokensForSale(uint256 tokenId) external view returns (uint256);
    function getTokenParameters(uint256 tokenId)
        external
        view
        returns (TokenParameters memory);
    function getV4PoolInitParams()
        external
        view
        returns (V4PoolInitParams memory);
    function allowedTotalSupplyWithParameters(
        uint32 a,
        uint8 b,
        uint128 curveScaler,
        uint256 tokenSplit
    ) external view returns (uint256);
    function calculateCostWithFees(uint256 amountInToken, uint256 tokenId)
        external
        view
        returns (uint256);
    function calculateRewardWithFees(uint256 amount, uint256 tokenId)
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
        uint256 creatorFeeBasisPoints,
        uint256 dividendFeeBasisPoints
    ) external view returns (uint256);
    function createToken(
        uint32 a,
        uint8 b,
        uint128 curveScaler,
        uint8 creatorFeeBasisPoints,
        uint16 dividendFeeBasisPoints,
        address tokenCreatorAddress,
        uint256 tokenSplit,
        string calldata name,
        string calldata symbol,
        uint256 amount,
        uint256 maxTotalCost,
        uint256 deadline
    ) external;
    function createTokenWithWL(
        uint32 a,
        uint8 b,
        uint128 curveScaler,
        uint8 creatorFeeBasisPoints,
        uint16 dividendFeeBasisPoints,
        address tokenCreatorAddress,
        uint256 tokenSplit,
        string calldata name,
        string calldata symbol,
        uint256 amount,
        IRobinhoodLaunchToken.Whitelist calldata whitelist,
        uint256 maxTotalCost,
        uint256 deadline
    ) external;
    function buyAndCreateLpIfPossibleWithUser(
        uint256 amount,
        uint256 tokenId,
        address user,
        uint256 maxPairTokenToSpend
    ) external;
    function sellWithUser(
        uint256 amount,
        uint256 tokenId,
        address user,
        uint256 minPairTokenToReceive
    ) external returns (uint256 amountOut);
}

interface IRobinhoodV2PrismRegistry {
    function isApprovedManager(address manager) external view returns (bool);
    function pairTokenForManager(address manager)
        external
        view
        returns (address);
}

interface IRobinhoodV2PrismBuyer {
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
