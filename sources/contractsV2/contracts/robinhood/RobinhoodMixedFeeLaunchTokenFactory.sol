// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {RobinhoodMixedFeeLaunchToken} from "./RobinhoodMixedFeeLaunchToken.sol";

/// @notice Manager-compatible factory for mixed-fee-aware launch tokens.
contract RobinhoodMixedFeeLaunchTokenFactory {
    address public immutable poolManager;
    address public immutable dividendController;
    address public immutable postBondHook;

    constructor(
        address poolManager_,
        address dividendController_,
        address postBondHook_
    ) {
        require(poolManager_ != address(0), "Invalid pool manager");
        require(dividendController_ != address(0), "Invalid dividend controller");
        require(postBondHook_ != address(0), "Invalid post-bond hook");
        poolManager = poolManager_;
        dividendController = dividendController_;
        postBondHook = postBondHook_;
    }

    function deployToken(string memory name, string memory symbol, uint256 salt)
        external
        returns (address token)
    {
        bytes memory tokenBytecode = abi.encodePacked(
            type(RobinhoodMixedFeeLaunchToken).creationCode,
            abi.encode(
                name,
                symbol,
                msg.sender,
                poolManager,
                dividendController,
                postBondHook,
                salt
            )
        );
        token = Create2.deploy(0, bytes32(salt), tokenBytecode);
    }
}
