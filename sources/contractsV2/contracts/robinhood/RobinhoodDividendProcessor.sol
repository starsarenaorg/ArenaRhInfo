// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {IRobinhoodDividendProcessor} from "./interfaces/IRobinhoodDividendProcessor.sol";

/// @notice Rotatable paired-token dividend accounting bucket.
/// @dev The controller owns canonical share updates and can swap processors
/// without changing launch-token, manager, or hook addresses.
contract RobinhoodDividendProcessor is
    Initializable,
    Ownable2StepUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    IRobinhoodDividendProcessor
{
    using SafeERC20 for IERC20;

    uint256 public constant ACC_SCALE = 1e36;

    struct TokenState {
        address rewardToken;
        uint256 accDividendPerShare;
        uint256 undistributed;
        uint256 totalDeposited;
        uint256 totalPaid;
    }

    struct AccountState {
        uint256 shares;
        uint256 rewardDebt;
        uint256 unpaid;
        bool initialized;
    }

    address public controller;

    mapping(uint256 => TokenState) public tokenState;
    mapping(uint256 => mapping(address => AccountState)) public accountState;

    uint256[49] private __gap;

    error ControllerOnly();
    error InvalidController();
    error InvalidRewardToken();

    event ControllerSet(address indexed oldController, address indexed newController);
    event DividendDeposited(
        uint256 indexed tokenId,
        address indexed rewardToken,
        uint256 amount,
        uint256 totalShares
    );
    event ShareSynced(
        uint256 indexed tokenId,
        address indexed account,
        uint256 previousShare,
        uint256 newShare
    );
    event DividendClaimed(
        uint256 indexed tokenId,
        address indexed account,
        address indexed recipient,
        uint256 amount
    );

    modifier onlyController() {
        if (msg.sender != controller) revert ControllerOnly();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, address controller_) external initializer {
        __Ownable_init(owner_);
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        _setController(controller_);
    }

    function setController(address newController) external onlyOwner {
        _setController(newController);
    }

    function _setController(address newController) internal {
        if (newController == address(0)) revert InvalidController();
        address oldController = controller;
        controller = newController;
        emit ControllerSet(oldController, newController);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function recordDeposit(
        uint256 tokenId,
        address rewardToken,
        uint256 amount,
        uint256 totalShares
    ) external onlyController {
        if (amount == 0) return;
        TokenState storage state = tokenState[tokenId];
        if (state.rewardToken == address(0)) {
            state.rewardToken = rewardToken;
        } else if (state.rewardToken != rewardToken) {
            revert InvalidRewardToken();
        }

        state.totalDeposited += amount;
        uint256 distributable = amount + state.undistributed;
        if (totalShares == 0) {
            state.undistributed = distributable;
            emit DividendDeposited(tokenId, rewardToken, amount, totalShares);
            return;
        }

        uint256 deltaAcc = Math.mulDiv(distributable, ACC_SCALE, totalShares);
        state.accDividendPerShare += deltaAcc;
        // The division remainder is already represented by accDividendPerShare
        // at sub-wei precision. Carrying it again as whole reward-token units
        // would create liabilities exceeding the processor balance.
        state.undistributed = 0;

        emit DividendDeposited(tokenId, rewardToken, amount, totalShares);
    }

    function syncShare(
        uint256 tokenId,
        address account,
        uint256 previousShare,
        uint256 newShare
    ) external onlyController {
        _settle(tokenId, account, previousShare, newShare);
        emit ShareSynced(tokenId, account, previousShare, newShare);
    }

    function pendingReward(uint256 tokenId, address account, uint256 currentShare)
        external
        view
        returns (uint256)
    {
        TokenState storage state = tokenState[tokenId];
        AccountState storage accountData = accountState[tokenId][account];
        uint256 shares = accountData.initialized ? accountData.shares : currentShare;
        uint256 accumulated =
            Math.mulDiv(shares, state.accDividendPerShare, ACC_SCALE);
        if (accumulated <= accountData.rewardDebt) return accountData.unpaid;
        return accountData.unpaid + accumulated - accountData.rewardDebt;
    }

    function claim(
        uint256 tokenId,
        address account,
        address recipient,
        uint256 currentShare
    ) external onlyController nonReentrant returns (uint256 paid) {
        _settle(tokenId, account, currentShare, currentShare);
        AccountState storage accountData = accountState[tokenId][account];
        paid = accountData.unpaid;
        if (paid == 0) return 0;

        address rewardToken = tokenState[tokenId].rewardToken;
        uint256 processorBalance = IERC20(rewardToken).balanceOf(address(this));
        if (paid > processorBalance) {
            paid = processorBalance;
        }
        if (paid == 0) return 0;

        accountData.unpaid -= paid;
        tokenState[tokenId].totalPaid += paid;
        IERC20(rewardToken).safeTransfer(recipient, paid);
        emit DividendClaimed(tokenId, account, recipient, paid);
    }

    function _settle(
        uint256 tokenId,
        address account,
        uint256 fallbackPreviousShare,
        uint256 newShare
    ) internal {
        TokenState storage state = tokenState[tokenId];
        AccountState storage accountData = accountState[tokenId][account];
        uint256 previousShare =
            accountData.initialized ? accountData.shares : fallbackPreviousShare;
        uint256 accumulated =
            Math.mulDiv(previousShare, state.accDividendPerShare, ACC_SCALE);
        if (accumulated > accountData.rewardDebt) {
            accountData.unpaid += accumulated - accountData.rewardDebt;
        }
        accountData.shares = newShare;
        accountData.rewardDebt =
            Math.mulDiv(newShare, state.accDividendPerShare, ACC_SCALE);
        accountData.initialized = true;
    }
}
