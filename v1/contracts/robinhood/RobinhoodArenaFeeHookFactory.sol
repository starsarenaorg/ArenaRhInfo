// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {IArenaFeeHelperMinimal} from "./interfaces/IArenaFeeHelperMinimal.sol";
import {RobinhoodArenaFeeHook} from "./RobinhoodArenaFeeHook.sol";

/// @notice CREATE2 factory for the permission-encoded Robinhood fee hook.
contract RobinhoodArenaFeeHookFactory {
    event HookDeployed(
        address indexed hook,
        bytes32 indexed salt,
        address indexed owner,
        address feeHelper
    );

    function deployHook(
        bytes32 salt,
        address owner,
        IArenaFeeHelperMinimal feeHelper,
        IPoolManager poolManager
    ) external returns (RobinhoodArenaFeeHook hook) {
        hook = new RobinhoodArenaFeeHook{salt: salt}(
            owner, address(feeHelper), poolManager
        );
        emit HookDeployed(address(hook), salt, owner, address(feeHelper));
    }
}
