// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IRobinhoodDividendController} from "./interfaces/IRobinhoodDividendController.sol";

interface IRobinhoodMixedFeeTokenManagerState {
    function arenaPoolDeployer() external view returns (address);
}

/// @notice Dividend-aware launch token that exempts its post-bond fee hook.
contract RobinhoodMixedFeeLaunchToken is ERC20, Ownable {
    struct Whitelist {
        address[] addresses;
        uint256 startTsOffset;
        uint256 duration;
        uint256 transferLimit;
        uint256 balanceLimit;
    }

    address public creator;
    Whitelist public whitelist;
    address public immutable POOL_MANAGER;
    address public immutable POST_BOND_HOOK;
    address public immutable ArenaTokenManager;
    IRobinhoodDividendController public immutable DIVIDEND_CONTROLLER;
    uint256 public immutable TOKEN_ID;

    mapping(address => bool) public blacklistedAddresses;
    mapping(address => bool) public whitelistedAddresses;
    mapping(address => uint256) public whitelistReceivedAmount;

    uint256 public whitelistStartTimestamp;
    uint256 public whiteListOffTimestamp;
    uint256 public whitelistLimit;
    uint256 public whitelistBalanceLimit;
    uint256 public constant MAX_NAME_BYTE_LENGTH = 50;
    uint256 public constant MAX_SYMBOL_BYTE_LENGTH = 30;

    event ArenaTokenTransfer(address indexed from, address indexed to, uint256 value);

    constructor(
        string memory name_,
        string memory symbol_,
        address admin_,
        address poolManager_,
        address dividendController_,
        address postBondHook_,
        uint256 tokenId_
    ) ERC20(name_, symbol_) Ownable(admin_) {
        require(bytes(name_).length <= MAX_NAME_BYTE_LENGTH, "Name string length exceeds max byte size");
        require(bytes(symbol_).length <= MAX_SYMBOL_BYTE_LENGTH, "Symbol string length exceeds max byte size");
        require(dividendController_ != address(0), "Invalid dividend controller");
        require(postBondHook_ != address(0), "Invalid post-bond hook");
        ArenaTokenManager = admin_;
        POOL_MANAGER = poolManager_;
        POST_BOND_HOOK = postBondHook_;
        DIVIDEND_CONTROLLER = IRobinhoodDividendController(dividendController_);
        TOKEN_ID = tokenId_;
    }

    function setWhitelistedAddresses(Whitelist calldata whitelist_) external onlyOwner {
        require(whitelist_.duration <= 3 days, "Duration must be less or equal to 3 day");
        require(whitelist_.transferLimit > 0, "Transfer limit must be greater than 0");
        require(whitelist_.balanceLimit > 0, "Balance limit must be greater than 0");
        require(whitelist_.balanceLimit >= whitelist_.transferLimit, "Balance limit must be >= transfer limit");
        require(whitelist_.startTsOffset < 2 weeks, "Start timestamp offset must be less than 2 weeks");
        require(whitelist_.addresses.length <= 620, "Addresses array must not be greater than 620");
        require(whitelist_.addresses.length > 0, "Addresses array must not be empty");
        for (uint256 i; i < whitelist_.addresses.length; ++i) {
            whitelistedAddresses[whitelist_.addresses[i]] = true;
        }
        whitelistStartTimestamp = block.timestamp + whitelist_.startTsOffset;
        whiteListOffTimestamp = whitelistStartTimestamp + whitelist_.duration;
        whitelistLimit = whitelist_.transferLimit;
        whitelistBalanceLimit = whitelist_.balanceLimit;
    }

    function setCreator(address creator_) external onlyOwner {
        creator = creator_;
    }

    function extendWhitelist(address[] calldata addresses) external {
        require(msg.sender == creator, "Only creator can extend whitelist");
        require(whiteListOffTimestamp > 0, "Whitelist is not set");
        require(whiteListOffTimestamp > block.timestamp, "Whitelist is off");
        require(addresses.length > 0, "Addresses array must not be empty");
        require(addresses.length <= 620, "Addresses array must not be greater than 620");
        for (uint256 i; i < addresses.length; ++i) {
            whitelistedAddresses[addresses[i]] = true;
        }
    }

    function removeWhitelistAddresses(address[] calldata addresses) external onlyOwner {
        for (uint256 i; i < addresses.length; ++i) {
            whitelistedAddresses[addresses[i]] = false;
        }
    }

    function getWhiteListInformation(address user)
        external
        view
        returns (
            bool isWhitelisted,
            uint256 whiteListOffTs,
            uint256 maxAmount,
            uint256 maxBalance,
            uint256 receivedAmount,
            uint256 startTimestamp
        )
    {
        return (
            whitelistedAddresses[user],
            whiteListOffTimestamp,
            whitelistLimit,
            whitelistBalanceLimit,
            whitelistReceivedAmount[user],
            whitelistStartTimestamp
        );
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function burn(address account, uint256 value) external onlyOwner {
        _burn(account, value);
    }

    function setBlacklistStatus(address account, bool blacklisted) external onlyOwner {
        blacklistedAddresses[account] = blacklisted;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blacklistedAddresses[to], "Sender is blacklisted");
        if (whitelistStartTimestamp > block.timestamp) {
            revert("Trade not allowed");
        }
        if (whiteListOffTimestamp > block.timestamp) {
            address poolDeployer = IRobinhoodMixedFeeTokenManagerState(
                ArenaTokenManager
            ).arenaPoolDeployer();
            if (tx.origin != creator) {
                require(whitelistedAddresses[tx.origin], "tx.origin is not whitelisted");
                bool exempted = to == ArenaTokenManager
                    || from == ArenaTokenManager || to == poolDeployer
                    || from == poolDeployer || to == POST_BOND_HOOK
                    || from == POST_BOND_HOOK;
                if (!exempted) {
                    require(value <= whitelistLimit, "Whitelist transfer limit exceeded");
                    if (to != address(0)) {
                        require(
                            balanceOf(to) + value <= whitelistBalanceLimit,
                            "Whitelist balance limit exceeded"
                        );
                    }
                    if (from == address(0) || from == POOL_MANAGER) {
                        require(
                            whitelistReceivedAmount[tx.origin] + value <= whitelistBalanceLimit,
                            "Whitelist balance limit exceeded"
                        );
                        whitelistReceivedAmount[tx.origin] += value;
                    }
                }
            }
        }

        super._update(from, to, value);

        if (from != address(0)) {
            DIVIDEND_CONTROLLER.syncShare(TOKEN_ID, from, balanceOf(from));
        }
        if (to != address(0) && to != from) {
            DIVIDEND_CONTROLLER.syncShare(TOKEN_ID, to, balanceOf(to));
        }

        emit ArenaTokenTransfer(from, to, value);
    }
}
