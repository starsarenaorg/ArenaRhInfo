// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";

/// @notice Referral registry retained for Robinhood launcher ABI compatibility.
contract RobinhoodArenaReferralRegistry is AccessControlEnumerable {
    bytes32 public constant REFERER_ADMIN_ROLE =
        keccak256("REFERER_ADMIN_ROLE");

    mapping(address => address) public referrer;

    event ReferrerSet(address referrer, address referee);
    event ReferrerSetBatch(address[] referrers, address[] referees);

    error ReferrerCantBeSelf();
    error ReferrersAndRefereesLengthMismatch();

    constructor(address owner_) {
        _grantRole(DEFAULT_ADMIN_ROLE, owner_);
    }

    function setReferrerWithAdmin(address referrer_, address referee)
        public
        onlyRole(REFERER_ADMIN_ROLE)
    {
        referrer[referee] = referrer_;
        emit ReferrerSet(referrer_, referee);
    }

    function setReferrerBatchWithAdmin(
        address[] calldata referrers,
        address[] calldata referees
    ) public onlyRole(REFERER_ADMIN_ROLE) {
        require(
            referrers.length == referees.length,
            ReferrersAndRefereesLengthMismatch()
        );
        for (uint256 i; i < referrers.length; ++i) {
            referrer[referees[i]] = referrers[i];
        }
        emit ReferrerSetBatch(referrers, referees);
    }

    function getReferrer(address referee) public view returns (address) {
        return referrer[referee];
    }
}
