// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RobinhoodLaunchToken} from "./RobinhoodLaunchToken.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

/// @notice Robinhood deployment of Arena's permissionless CREATE2 token factory.
/// @dev The PoolManager constructor argument is the only chain-specific addition.
contract RobinhoodLaunchTokenFactory {
    address public immutable poolManager;

    constructor(address poolManager_) {
        poolManager = poolManager_;
    }

    function deployToken(string memory name, string memory symbol, uint256 salt)
        external
        returns (address token)
    {
        bytes memory tokenBytecode = abi.encodePacked(
            type(RobinhoodLaunchToken).creationCode,
            abi.encode(name, symbol, msg.sender, poolManager)
        );
        token = Create2.deploy(0, bytes32(salt), tokenBytecode);
    }
}
