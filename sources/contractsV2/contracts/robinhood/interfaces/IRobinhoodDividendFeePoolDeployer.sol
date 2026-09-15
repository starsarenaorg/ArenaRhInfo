// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IArenaPoolDeployer} from "../../../../contracts/contracts/robinhood/interfaces/IArenaPoolDeployer.sol";
import {IRobinhoodDividendFeeHelper} from "./IRobinhoodDividendFeeHelper.sol";

interface IRobinhoodDividendFeePoolDeployer {
    function initPoolAndSetFees(
        IArenaPoolDeployer.PoolInitParams memory params,
        IRobinhoodDividendFeeHelper.PoolFeeConfig calldata feeConfig
    ) external returns (uint256);
}
