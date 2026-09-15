// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IRobinhoodDividendProcessor {
    function recordDeposit(
        uint256 tokenId,
        address rewardToken,
        uint256 amount,
        uint256 totalShares
    ) external;

    function syncShare(
        uint256 tokenId,
        address account,
        uint256 previousShare,
        uint256 newShare
    ) external;

    function pendingReward(uint256 tokenId, address account, uint256 currentShare)
        external
        view
        returns (uint256);

    function claim(
        uint256 tokenId,
        address account,
        address recipient,
        uint256 currentShare
    ) external returns (uint256 paid);
}
