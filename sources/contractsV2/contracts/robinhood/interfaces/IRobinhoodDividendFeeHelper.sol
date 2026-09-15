// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

interface IRobinhoodDividendFeeHelper {
    struct PoolFeeConfig {
        uint256 tokenId;
        address launchToken;
        address rewardToken;
        address dividendController;
        address creator;
        address creatorFeeRecipient;
        uint16 dividendFeePpm;
        uint16 creatorFeePpm;
    }

    struct SwapFeeInfo {
        uint256 tokenId;
        address rewardToken;
        address dividendController;
        uint16 dividendFeePpm;
        address creatorFeeRecipient;
        uint16 creatorFeePpm;
        address protocolFeeRecipient;
        uint16 protocolFeePpm;
        address referrer;
        uint16 referralFeePpm;
    }

    function initializePoolConfig(PoolId poolId, PoolFeeConfig calldata config)
        external;

    function getPoolConfig(PoolId poolId)
        external
        view
        returns (PoolFeeConfig memory);

    function getSwapFeeInfo(PoolId poolId)
        external
        view
        returns (SwapFeeInfo memory info);

    function getTotalFeePpm(PoolId poolId) external view returns (uint256);

    function creatorUpdateTokenFeeFromManager(
        uint256 tokenId,
        address caller,
        address newRecipient,
        uint16 newFeePpm
    ) external;

    function adminSetTokenCreatorFee(
        uint256 tokenId,
        address creator,
        address recipient,
        uint16 feePpm
    ) external;

    function setPoolDividendController(PoolId poolId, address controller)
        external;
}
