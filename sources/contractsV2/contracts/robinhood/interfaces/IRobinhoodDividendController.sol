// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

interface IRobinhoodDividendController {
    function registerToken(
        uint256 tokenId,
        address launchToken,
        address rewardToken,
        address[] calldata defaultExcludedAccounts
    ) external;

    function registerPool(uint256 tokenId, PoolId poolId) external;

    function deposit(uint256 tokenId, address rewardToken, uint256 amount) external;

    function syncShare(uint256 tokenId, address account, uint256 rawBalance) external;

    function setDividendExcluded(uint256 tokenId, address account, bool excluded) external;

    function claim(uint256 tokenId) external returns (uint256 paid);

    function claimFor(uint256 tokenId, address account, address recipient)
        external
        returns (uint256 paid);

    function distribute(uint256 tokenId, address[] calldata accounts)
        external
        returns (uint256 totalPaid);

    function pendingReward(uint256 tokenId, address account)
        external
        view
        returns (uint256 pending);

    function shareOf(uint256 tokenId, address account) external view returns (uint256);

    function totalShares(uint256 tokenId) external view returns (uint256);

    function activeProcessor(uint256 tokenId) external view returns (address);

    function isExcludedFromDividends(uint256 tokenId, address account)
        external
        view
        returns (bool);
}
