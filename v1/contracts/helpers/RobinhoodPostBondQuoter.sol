// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {V4Quoter} from "@uniswap/v4-periphery/src/lens/V4Quoter.sol";

/// @notice Exact Uniswap v4 quotes for Robinhood post-graduation pools.
/// @dev V4Quoter simulates PoolManager.swap and intentionally reverts inside the
/// unlock callback, so eth_call quotes include initialized-tick crossings and
/// the Robinhood afterSwap fee hook without changing chain state.
contract RobinhoodPostBondQuoter is V4Quoter {
    constructor(IPoolManager poolManager_) V4Quoter(poolManager_) {}
}
