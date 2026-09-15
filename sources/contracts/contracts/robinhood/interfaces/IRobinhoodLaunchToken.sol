// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IRobinhoodLaunchToken {
    struct Whitelist {
        address[] addresses;
        uint256 startTsOffset;
        uint256 duration;
        uint256 transferLimit;
        uint256 balanceLimit;
    }

    function mint(address to, uint256 amount) external;
    function burn(address account, uint256 value) external;
    function setBlacklistStatus(address account, bool blacklisted) external;
    function totalSupply() external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function setWhitelistedAddresses(Whitelist calldata whitelist) external;
    function setCreator(address creator) external;
}
