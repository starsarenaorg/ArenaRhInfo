// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {IRobinhoodDividendFeeHelper} from "./interfaces/IRobinhoodDividendFeeHelper.sol";
import {RobinhoodDividendFeeHook} from "./RobinhoodDividendFeeHook.sol";

/// @notice CREATE2 factory for the permission-encoded V2 dividend fee hook.
contract RobinhoodDividendFeeHookFactory {
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
    ) external returns (RobinhoodDividendFeeHook hook) {
        hook = new RobinhoodDividendFeeHook{salt: salt}(
            owner, address(feeHelper), poolManager
        );
        emit HookDeployed(address(hook), salt, owner, address(feeHelper));
    }
}
