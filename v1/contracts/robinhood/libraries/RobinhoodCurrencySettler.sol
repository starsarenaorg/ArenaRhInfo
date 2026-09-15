// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice Currency settlement helpers used by the Robinhood fee hook.
/// @dev Ported from OpenZeppelin Uniswap Hooks' CurrencySettler, which is the
/// helper used by the original compatible Arena hook implementation.
library RobinhoodCurrencySettler {
    using SafeERC20 for IERC20;

    function settle(
        Currency currency,
        IPoolManager poolManager,
        address payer,
        uint256 amount,
        bool burn
    ) internal {
        if (amount == 0) return;
        if (burn) {
            poolManager.burn(payer, currency.toId(), amount);
        } else if (currency.isAddressZero()) {
            poolManager.sync(currency);
            poolManager.settle{value: amount}();
        } else {
            poolManager.sync(currency);
            if (payer != address(this)) {
                IERC20(Currency.unwrap(currency)).safeTransferFrom(
                    payer, address(poolManager), amount
                );
            } else {
                IERC20(Currency.unwrap(currency)).safeTransfer(
                    address(poolManager), amount
                );
            }
            poolManager.settle();
        }
    }

    function take(
        Currency currency,
        IPoolManager poolManager,
        address recipient,
        uint256 amount,
        bool claims
    ) internal {
        if (amount == 0) return;
        if (claims) {
            poolManager.mint(recipient, currency.toId(), amount);
        } else {
            poolManager.take(currency, recipient, amount);
        }
    }
}
