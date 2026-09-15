// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IRobinhoodDividendController} from "./interfaces/IRobinhoodDividendController.sol";
import {IRobinhoodDividendProcessor} from "./interfaces/IRobinhoodDividendProcessor.sol";

interface IRobinhoodDividendShareToken {
    function balanceOf(address account) external view returns (uint256);
    function POOL_MANAGER() external view returns (address);
}

/// @notice Stable registry and router for launch-token paired dividends.
contract RobinhoodDividendController is
    Ownable2Step,
    ReentrancyGuard,
    IRobinhoodDividendController
{
    using SafeERC20 for IERC20;

    struct TokenDividendState {
        address launchToken;
        address rewardToken;
        address registrar;
        PoolId poolId;
        bool registered;
    }

    address public defaultProcessor;

    mapping(address => bool) public isRegistrar;
    mapping(uint256 => TokenDividendState) public tokenDividendState;
    mapping(uint256 => mapping(address => bool)) public override isExcludedFromDividends;
    mapping(uint256 => mapping(address => uint256)) public override shareOf;
    mapping(uint256 => uint256) public override totalShares;

    mapping(uint256 => address) private _activeProcessor;
    mapping(uint256 => address[]) private _processors;
    mapping(uint256 => mapping(address => bool)) private _processorAdded;

    error RegistrarOnly();
    error TokenOnly();
    error TokenNotRegistered();
    error TokenAlreadyRegistered();
    error InvalidAddress();
    error InvalidProcessor();
    error InvalidRewardToken();
    error UnauthorizedClaimFor();

    event RegistrarSet(address indexed registrar, bool authorized);
    event DefaultProcessorSet(address indexed oldProcessor, address indexed newProcessor);
    event TokenRegistered(
        uint256 indexed tokenId,
        address indexed launchToken,
        address indexed rewardToken,
        address registrar
    );
    event PoolRegistered(uint256 indexed tokenId, PoolId indexed poolId);
    event ActiveProcessorSet(
        uint256 indexed tokenId,
        address indexed oldProcessor,
        address indexed newProcessor
    );
    event DividendExcludedSet(
        uint256 indexed tokenId,
        address indexed account,
        bool excluded
    );
    event ShareSynced(
        uint256 indexed tokenId,
        address indexed account,
        uint256 previousShare,
        uint256 newShare
    );
    event DividendDeposited(
        uint256 indexed tokenId,
        address indexed rewardToken,
        address indexed processor,
        uint256 amount
    );

    modifier onlyRegistrar() {
        if (msg.sender != owner() && !isRegistrar[msg.sender]) revert RegistrarOnly();
        _;
    }

    modifier onlyTokenRegistrar(uint256 tokenId) {
        if (
            msg.sender != owner()
                && msg.sender != tokenDividendState[tokenId].registrar
                && !isRegistrar[msg.sender]
        ) revert RegistrarOnly();
        _;
    }

    constructor(address owner_, address defaultProcessor_) Ownable(owner_) {
        defaultProcessor = defaultProcessor_;
        emit DefaultProcessorSet(address(0), defaultProcessor_);
    }

    function setRegistrar(address registrar, bool authorized) external onlyOwner {
        isRegistrar[registrar] = authorized;
        emit RegistrarSet(registrar, authorized);
    }

    function setDefaultProcessor(address newProcessor) external onlyOwner {
        address oldProcessor = defaultProcessor;
        defaultProcessor = newProcessor;
        emit DefaultProcessorSet(oldProcessor, newProcessor);
    }

    function registerToken(
        uint256 tokenId,
        address launchToken,
        address rewardToken,
        address[] calldata defaultExcludedAccounts
    ) external onlyRegistrar {
        if (tokenDividendState[tokenId].registered) {
            revert TokenAlreadyRegistered();
        }
        if (launchToken == address(0) || rewardToken == address(0)) {
            revert InvalidAddress();
        }

        tokenDividendState[tokenId] = TokenDividendState({
            launchToken: launchToken,
            rewardToken: rewardToken,
            registrar: msg.sender,
            poolId: PoolId.wrap(bytes32(0)),
            registered: true
        });

        _setExcludedFlag(tokenId, launchToken, true);
        _setExcludedFlag(tokenId, address(this), true);
        _setExcludedFlag(tokenId, msg.sender, true);

        address processor = defaultProcessor;
        if (processor != address(0)) {
            _setActiveProcessor(tokenId, processor);
            _setExcludedFlag(tokenId, processor, true);
        }

        try IRobinhoodDividendShareToken(launchToken).POOL_MANAGER()
            returns (address poolManager)
        {
            if (poolManager != address(0)) _setExcludedFlag(tokenId, poolManager, true);
        } catch {}

        for (uint256 i; i < defaultExcludedAccounts.length; ++i) {
            _setExcludedFlag(tokenId, defaultExcludedAccounts[i], true);
        }

        emit TokenRegistered(tokenId, launchToken, rewardToken, msg.sender);
    }

    function registerPool(uint256 tokenId, PoolId poolId)
        external
        onlyTokenRegistrar(tokenId)
    {
        if (!tokenDividendState[tokenId].registered) revert TokenNotRegistered();
        tokenDividendState[tokenId].poolId = poolId;
        emit PoolRegistered(tokenId, poolId);
    }

    function setActiveProcessor(uint256 tokenId, address processor)
        external
        onlyOwner
    {
        if (!tokenDividendState[tokenId].registered) revert TokenNotRegistered();
        _setActiveProcessor(tokenId, processor);
        _setDividendExcluded(tokenId, processor, true);
    }

    function setDividendExcluded(uint256 tokenId, address account, bool excluded)
        external
        onlyTokenRegistrar(tokenId)
    {
        _setDividendExcluded(tokenId, account, excluded);
    }

    function deposit(uint256 tokenId, address rewardToken, uint256 amount)
        external
        nonReentrant
    {
        TokenDividendState memory state = tokenDividendState[tokenId];
        if (!state.registered) revert TokenNotRegistered();
        if (rewardToken != state.rewardToken) revert InvalidRewardToken();
        if (amount == 0) return;

        address processor = _activeProcessor[tokenId];
        if (processor == address(0)) revert InvalidProcessor();

        IERC20(rewardToken).safeTransferFrom(msg.sender, processor, amount);
        IRobinhoodDividendProcessor(processor).recordDeposit(
            tokenId, rewardToken, amount, totalShares[tokenId]
        );
        emit DividendDeposited(tokenId, rewardToken, processor, amount);
    }

    function syncShare(uint256 tokenId, address account, uint256 rawBalance)
        external
    {
        TokenDividendState memory state = tokenDividendState[tokenId];
        if (!state.registered) revert TokenNotRegistered();
        if (msg.sender != state.launchToken) revert TokenOnly();
        uint256 newShare = isExcludedFromDividends[tokenId][account]
            ? 0
            : rawBalance;
        _syncShare(tokenId, account, newShare);
    }

    function claim(uint256 tokenId)
        external
        nonReentrant
        returns (uint256 paid)
    {
        paid = _claimTo(tokenId, msg.sender, msg.sender);
    }

    function claimFor(uint256 tokenId, address account, address recipient)
        external
        nonReentrant
        returns (uint256 paid)
    {
        if (
            msg.sender != account
                && msg.sender != owner()
                && recipient != account
        ) revert UnauthorizedClaimFor();
        paid = _claimTo(tokenId, account, recipient);
    }

    function distribute(uint256 tokenId, address[] calldata accounts)
        external
        nonReentrant
        returns (uint256 totalPaid)
    {
        for (uint256 i; i < accounts.length; ++i) {
            totalPaid += _claimTo(tokenId, accounts[i], accounts[i]);
        }
    }

    function pendingReward(uint256 tokenId, address account)
        external
        view
        returns (uint256 pending)
    {
        uint256 currentShare = shareOf[tokenId][account];
        address[] storage processors = _processors[tokenId];
        for (uint256 i; i < processors.length; ++i) {
            pending += IRobinhoodDividendProcessor(processors[i]).pendingReward(
                tokenId, account, currentShare
            );
        }
    }

    function activeProcessor(uint256 tokenId) external view returns (address) {
        return _activeProcessor[tokenId];
    }

    function processorCount(uint256 tokenId) external view returns (uint256) {
        return _processors[tokenId].length;
    }

    function processorAt(uint256 tokenId, uint256 index)
        external
        view
        returns (address)
    {
        return _processors[tokenId][index];
    }

    function _claimTo(uint256 tokenId, address account, address recipient)
        internal
        returns (uint256 paid)
    {
        if (!tokenDividendState[tokenId].registered) revert TokenNotRegistered();
        uint256 currentShare = shareOf[tokenId][account];
        address[] storage processors = _processors[tokenId];
        for (uint256 i; i < processors.length; ++i) {
            paid += IRobinhoodDividendProcessor(processors[i]).claim(
                tokenId, account, recipient, currentShare
            );
        }
    }

    function _setActiveProcessor(uint256 tokenId, address processor) internal {
        if (processor == address(0)) revert InvalidProcessor();
        address oldProcessor = _activeProcessor[tokenId];
        if (!_processorAdded[tokenId][processor]) {
            _processorAdded[tokenId][processor] = true;
            _processors[tokenId].push(processor);
        }
        _activeProcessor[tokenId] = processor;
        emit ActiveProcessorSet(tokenId, oldProcessor, processor);
    }

    function _setDividendExcluded(
        uint256 tokenId,
        address account,
        bool excluded
    ) internal {
        if (!tokenDividendState[tokenId].registered) revert TokenNotRegistered();
        _setExcludedFlag(tokenId, account, excluded);
        uint256 rawBalance =
            IRobinhoodDividendShareToken(tokenDividendState[tokenId].launchToken)
                .balanceOf(account);
        _syncShare(tokenId, account, excluded ? 0 : rawBalance);
    }

    function _setExcludedFlag(uint256 tokenId, address account, bool excluded)
        internal
    {
        if (account == address(0)) return;
        isExcludedFromDividends[tokenId][account] = excluded;
        emit DividendExcludedSet(tokenId, account, excluded);
    }

    function _syncShare(uint256 tokenId, address account, uint256 newShare)
        internal
    {
        if (account == address(0)) return;
        uint256 previousShare = shareOf[tokenId][account];
        if (previousShare == newShare) return;

        shareOf[tokenId][account] = newShare;
        if (newShare > previousShare) {
            totalShares[tokenId] += newShare - previousShare;
        } else {
            totalShares[tokenId] -= previousShare - newShare;
        }

        address[] storage processors = _processors[tokenId];
        for (uint256 i; i < processors.length; ++i) {
            IRobinhoodDividendProcessor(processors[i]).syncShare(
                tokenId, account, previousShare, newShare
            );
        }
        emit ShareSynced(tokenId, account, previousShare, newShare);
    }
}
