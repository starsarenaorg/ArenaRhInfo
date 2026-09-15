// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IRobinhoodArenaManagerHelper} from "../helpers/RobinhoodHelperInterfaces.sol";
import {RobinhoodArenaPairPriceHelper} from "../helpers/RobinhoodArenaPairPriceHelper.sol";

/// @notice Pair-agnostic inverse curve helper for an Arena Prism manager.
contract RobinhoodPrismPriceHelper is RobinhoodArenaPairPriceHelper {
    constructor(IRobinhoodArenaManagerHelper manager)
        RobinhoodArenaPairPriceHelper(manager)
    {}
}
