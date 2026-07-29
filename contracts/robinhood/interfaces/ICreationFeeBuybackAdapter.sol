// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Robinhood launch creation-fee adapter interface.
interface ICreationFeeBuybackAdapter {
    function depositCreationFee() external payable;
}
