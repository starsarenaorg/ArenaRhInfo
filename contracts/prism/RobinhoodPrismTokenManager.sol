// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RobinhoodArenaPairTokenManager} from "../arena-pair/RobinhoodArenaPairTokenManager.sol";

/// @notice Arena Prism bonding manager for one approved ERC-20 numeraire.
/// @dev Each approved RWA receives a separate proxy backed by an implementation
///      constructed with that RWA as `pairToken_`. This deliberately preserves
///      the battle-tested WARENA curve, fee, whitelist, and v4 graduation flow
///      while isolating configuration and reserves between numeraires.
contract RobinhoodPrismTokenManager is RobinhoodArenaPairTokenManager {
    constructor(address pairToken_, address stakerRewardTokenVault_)
        RobinhoodArenaPairTokenManager(pairToken_, stakerRewardTokenVault_)
    {}

    function PAIR_TOKEN() external view returns (address) {
        return ARENA_ADDRESS;
    }
}
