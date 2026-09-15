// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IRobinhoodDividendFeeHelper} from "./interfaces/IRobinhoodDividendFeeHelper.sol";

interface IRobinhoodDividendReferralRegistry {
    function getReferrer(address referee) external view returns (address);
}

/// @notice V2 post-bond fee config for paired-token dividends.
contract RobinhoodDividendFeeHelper is Ownable2Step, IRobinhoodDividendFeeHelper {
    uint256 public constant MAX_DIVIDEND_FEE_PPM = 50_000;
    uint256 public constant MAX_CREATOR_FEE_PPM = 10_000;
    uint256 public constant MAX_PROTOCOL_FEE_PPM = 10_000;
    uint256 public constant MAX_TOTAL_FEE_PPM = 70_000;

    struct ProtocolFeeSettings {
        address recipient;
        uint16 protocolFeePpm;
        uint16 referralFeePpm;
    }

    mapping(address => bool) public isFeeSetter;
    mapping(PoolId => PoolFeeConfig) private _poolConfig;
    mapping(PoolId => bool) public poolInitialized;
    mapping(uint256 => PoolId) public tokenIdToPoolId;

    IRobinhoodDividendReferralRegistry public referralRegistry;
    ProtocolFeeSettings public protocolFeeSettings;

    error FeeSetterOnly();
    error PoolAlreadyInitialized();
    error PoolNotInitialized();
    error InvalidAddress();
    error InvalidFee();
    error CreatorOnly();
    error FeeCanOnlyDecrease();

    event FeeSetterSet(address indexed feeSetter, bool authorized);
    event ReferralRegistrySet(address indexed referralRegistry);
    event ProtocolFeeSettingsSet(ProtocolFeeSettings settings);
    event PoolConfigInitialized(PoolId indexed poolId, PoolFeeConfig config);
    event CreatorFeeSet(
        uint256 indexed tokenId,
        PoolId indexed poolId,
        address indexed creator,
        address recipient,
        uint16 feePpm
    );
    event PoolDividendControllerSet(
        uint256 indexed tokenId,
        PoolId indexed poolId,
        address indexed controller
    );

    modifier onlyFeeSetter() {
        if (msg.sender != owner() && !isFeeSetter[msg.sender]) {
            revert FeeSetterOnly();
        }
        _;
    }

    constructor(
        address owner_,
        address referralRegistry_,
        uint16 protocolFeePpm_,
        address protocolFeeRecipient_,
        uint16 referralFeePpm_
    ) Ownable(owner_) {
        referralRegistry = IRobinhoodDividendReferralRegistry(referralRegistry_);
        _setProtocolFeeSettings(
            protocolFeeRecipient_, protocolFeePpm_, referralFeePpm_
        );
        emit ReferralRegistrySet(referralRegistry_);
    }

    function setFeeSetter(address feeSetter, bool authorized) external onlyOwner {
        isFeeSetter[feeSetter] = authorized;
        emit FeeSetterSet(feeSetter, authorized);
    }

    function setReferralRegistry(address referralRegistry_) external onlyOwner {
        referralRegistry = IRobinhoodDividendReferralRegistry(referralRegistry_);
        emit ReferralRegistrySet(referralRegistry_);
    }

    function setProtocolFeeSettings(
        address recipient,
        uint16 protocolFeePpm,
        uint16 referralFeePpm
    ) external onlyOwner {
        _setProtocolFeeSettings(recipient, protocolFeePpm, referralFeePpm);
    }

    function initializePoolConfig(PoolId poolId, PoolFeeConfig calldata config)
        external
        onlyFeeSetter
    {
        if (poolInitialized[poolId]) revert PoolAlreadyInitialized();
        _validatePoolConfig(config);
        poolInitialized[poolId] = true;
        _poolConfig[poolId] = config;
        tokenIdToPoolId[config.tokenId] = poolId;
        _validateTotalFee(uint256(config.dividendFeePpm) + config.creatorFeePpm);
        emit PoolConfigInitialized(poolId, config);
    }

    function getPoolConfig(PoolId poolId)
        external
        view
        returns (PoolFeeConfig memory)
    {
        if (!poolInitialized[poolId]) revert PoolNotInitialized();
        return _poolConfig[poolId];
    }

    function getSwapFeeInfo(PoolId poolId)
        external
        view
        returns (SwapFeeInfo memory info)
    {
        if (!poolInitialized[poolId]) revert PoolNotInitialized();
        PoolFeeConfig memory config = _poolConfig[poolId];
        ProtocolFeeSettings memory protocol = protocolFeeSettings;
        address referrer;
        uint16 referralFeePpm;
        uint16 protocolFeePpm = protocol.protocolFeePpm;

        if (address(referralRegistry) != address(0) && protocol.referralFeePpm > 0) {
            referrer = referralRegistry.getReferrer(tx.origin);
            if (referrer != address(0)) {
                referralFeePpm = protocol.referralFeePpm;
                protocolFeePpm = protocol.protocolFeePpm - referralFeePpm;
            }
        }

        info = SwapFeeInfo({
            tokenId: config.tokenId,
            rewardToken: config.rewardToken,
            dividendController: config.dividendController,
            dividendFeePpm: config.dividendFeePpm,
            creatorFeeRecipient: config.creatorFeeRecipient,
            creatorFeePpm: config.creatorFeePpm,
            protocolFeeRecipient: protocol.recipient,
            protocolFeePpm: protocolFeePpm,
            referrer: referrer,
            referralFeePpm: referralFeePpm
        });
    }

    function getTotalFeePpm(PoolId poolId) external view returns (uint256) {
        if (!poolInitialized[poolId]) revert PoolNotInitialized();
        PoolFeeConfig memory config = _poolConfig[poolId];
        return config.dividendFeePpm + config.creatorFeePpm
            + protocolFeeSettings.protocolFeePpm;
    }

    function creatorUpdateTokenFeeFromManager(
        uint256 tokenId,
        address caller,
        address newRecipient,
        uint16 newFeePpm
    ) external onlyFeeSetter {
        PoolId poolId = tokenIdToPoolId[tokenId];
        if (!poolInitialized[poolId]) revert PoolNotInitialized();
        PoolFeeConfig storage config = _poolConfig[poolId];
        if (caller != config.creator) revert CreatorOnly();
        _creatorSetFee(config, poolId, newRecipient, newFeePpm);
    }

    function creatorUpdateTokenFee(
        uint256 tokenId,
        address newRecipient,
        uint16 newFeePpm
    ) external {
        PoolId poolId = tokenIdToPoolId[tokenId];
        if (!poolInitialized[poolId]) revert PoolNotInitialized();
        PoolFeeConfig storage config = _poolConfig[poolId];
        if (msg.sender != config.creator) revert CreatorOnly();
        _creatorSetFee(config, poolId, newRecipient, newFeePpm);
    }

    function adminSetTokenCreatorFee(
        uint256 tokenId,
        address creator,
        address recipient,
        uint16 feePpm
    ) external onlyFeeSetter {
        if (feePpm > MAX_CREATOR_FEE_PPM) revert InvalidFee();
        if (creator == address(0) || recipient == address(0)) revert InvalidAddress();
        PoolId poolId = tokenIdToPoolId[tokenId];
        if (!poolInitialized[poolId]) revert PoolNotInitialized();
        PoolFeeConfig storage config = _poolConfig[poolId];
        config.creator = creator;
        config.creatorFeeRecipient = recipient;
        config.creatorFeePpm = feePpm;
        _validateTotalFee(uint256(config.dividendFeePpm) + feePpm);
        emit CreatorFeeSet(tokenId, poolId, creator, recipient, feePpm);
    }

    function setPoolDividendController(PoolId poolId, address controller)
        external
        onlyOwner
    {
        _setPoolDividendController(poolId, controller);
    }

    function setTokenDividendController(uint256 tokenId, address controller)
        external
        onlyOwner
    {
        PoolId poolId = tokenIdToPoolId[tokenId];
        if (!poolInitialized[poolId]) revert PoolNotInitialized();
        _setPoolDividendController(poolId, controller);
    }

    function getProtocolFeeSettings()
        external
        view
        returns (ProtocolFeeSettings memory)
    {
        return protocolFeeSettings;
    }

    function _creatorSetFee(
        PoolFeeConfig storage config,
        PoolId poolId,
        address newRecipient,
        uint16 newFeePpm
    ) internal {
        if (newRecipient == address(0)) revert InvalidAddress();
        if (newFeePpm > config.creatorFeePpm) revert FeeCanOnlyDecrease();
        config.creatorFeeRecipient = newRecipient;
        config.creatorFeePpm = newFeePpm;
        _validateTotalFee(uint256(config.dividendFeePpm) + newFeePpm);
        emit CreatorFeeSet(
            config.tokenId, poolId, config.creator, newRecipient, newFeePpm
        );
    }

    function _setPoolDividendController(PoolId poolId, address controller)
        internal
    {
        if (controller == address(0)) revert InvalidAddress();
        if (!poolInitialized[poolId]) revert PoolNotInitialized();
        PoolFeeConfig storage config = _poolConfig[poolId];
        config.dividendController = controller;
        emit PoolDividendControllerSet(config.tokenId, poolId, controller);
    }

    function _setProtocolFeeSettings(
        address recipient,
        uint16 protocolFeePpm,
        uint16 referralFeePpm
    ) internal {
        if (recipient == address(0)) revert InvalidAddress();
        if (
            protocolFeePpm == 0 || protocolFeePpm > MAX_PROTOCOL_FEE_PPM
                || referralFeePpm > protocolFeePpm
        ) revert InvalidFee();
        protocolFeeSettings = ProtocolFeeSettings({
            recipient: recipient,
            protocolFeePpm: protocolFeePpm,
            referralFeePpm: referralFeePpm
        });
        emit ProtocolFeeSettingsSet(protocolFeeSettings);
    }

    function _validatePoolConfig(PoolFeeConfig calldata config) internal pure {
        if (
            config.tokenId == 0 || config.launchToken == address(0)
                || config.rewardToken == address(0)
                || config.dividendController == address(0)
                || config.creator == address(0)
                || config.creatorFeeRecipient == address(0)
        ) revert InvalidAddress();
        if (
            config.dividendFeePpm > MAX_DIVIDEND_FEE_PPM
                || config.creatorFeePpm > MAX_CREATOR_FEE_PPM
        ) revert InvalidFee();
    }

    function _validateTotalFee(uint256 poolFeePpm) internal view {
        if (poolFeePpm + protocolFeeSettings.protocolFeePpm > MAX_TOTAL_FEE_PPM) {
            revert InvalidFee();
        }
    }
}
