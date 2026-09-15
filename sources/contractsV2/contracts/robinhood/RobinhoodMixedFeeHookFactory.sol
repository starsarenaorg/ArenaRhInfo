// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {IRobinhoodDividendFeeHelper} from "./interfaces/IRobinhoodDividendFeeHelper.sol";
import {RobinhoodMixedFeeHook} from "./RobinhoodMixedFeeHook.sol";

/// @notice CREATE2 factory for the permission-encoded V2 mixed fee hook.
contract RobinhoodMixedFeeHookFactory {
    event HookDeployed(
        address indexed hook,
        bytes32 indexed salt,
        address indexed owner,
        address feeHelper
    );

    function deployHook(
        bytes32 salt,
        address owner,
        IRobinhoodDividendFeeHelper feeHelper,
        IPoolManager poolManager
    ) external returns (RobinhoodMixedFeeHook hook) {
        hook = new RobinhoodMixedFeeHook{salt: salt}(
            owner, address(feeHelper), poolManager
        );
        emit HookDeployed(address(hook), salt, owner, address(feeHelper));
    }
}
