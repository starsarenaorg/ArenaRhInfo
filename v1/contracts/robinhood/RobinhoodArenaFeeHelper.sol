// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IArenaFeeHelperMinimal} from "./interfaces/IArenaFeeHelperMinimal.sol";

interface IRobinhoodArenaReferralRegistry {
    function getReferrer(address referee) external view returns (address);
}

/// @notice Fee configuration helper for Robinhood Chain launch pools.
contract RobinhoodArenaFeeHelper is Ownable2Step, IArenaFeeHelperMinimal {
    uint256 public constant MAX_PROTOCOL_FEE_PPM = 10_000;
    uint256 public constant MAX_POOL_FEE_PPM = 10_000;
    uint256 public constant MAX_FEE_ARRAY_LENGTH = 5;

    error TotalFeePpmExceedsMaxFeePpm();
    error TotalFeePpmBelowMinFeePpm();
    error FeeRecipientNotFound();
    error FeeSetterOnly();
    error FeesAlreadyInitialized();
    error FeeArrayLengthExceedsMaxFeeArrayLength();
    error RecipientCantBeZeroAddress();
    error RecipientIndexOutOfBounds();
    error RecipientIndexDoesNotMatchRecipient();
    error ProtocolFeePpmMustBeGreaterThanReferralFeePpm();
    error ProtocolFeePpmMustBeGreaterThanZero();

    event FeeSetterSet(address indexed feeSetter, bool isFeeSetter);
    event ReferralRegistrySet(address referralRegistry);
    event FeeArraySet(PoolId indexed poolId, Fee[] fees);
    event ProtocolFeeSettingsSet(ProtocolFeeSettings settings);

    struct ProtocolFeeSettings {
        address recipient;
        uint16 protocolFeePpm;
        uint16 referralFeePpm;
    }

    mapping(PoolId => Fee[]) public poolIdToFees;
    mapping(PoolId => uint256) public poolIdToTotalFeePpm;
    mapping(address => bool) public isFeeSetter;
    IRobinhoodArenaReferralRegistry public referralRegistry;
    ProtocolFeeSettings public protocolFeeSettings;

    constructor(
        address owner_,
        address referralRegistry_,
        uint16 protocolFeePpm_,
        address protocolFeeRecipient_,
        uint16 referralFeePpm_
    ) Ownable(owner_) {
        referralRegistry =
            IRobinhoodArenaReferralRegistry(referralRegistry_);
        protocolFeeSettings = ProtocolFeeSettings({
            recipient: protocolFeeRecipient_,
            protocolFeePpm: protocolFeePpm_,
            referralFeePpm: referralFeePpm_
        });
        require(
            protocolFeePpm_ <= MAX_PROTOCOL_FEE_PPM,
            TotalFeePpmExceedsMaxFeePpm()
        );
        require(
            protocolFeePpm_ > referralFeePpm_,
            ProtocolFeePpmMustBeGreaterThanReferralFeePpm()
        );
        require(
            protocolFeeRecipient_ != address(0),
            RecipientCantBeZeroAddress()
        );
        require(
            protocolFeePpm_ > 0,
            ProtocolFeePpmMustBeGreaterThanZero()
        );
        emit ProtocolFeeSettingsSet(protocolFeeSettings);
        emit ReferralRegistrySet(referralRegistry_);
    }

    function setReferralRegistry(address referralRegistry_) public onlyOwner {
        referralRegistry =
            IRobinhoodArenaReferralRegistry(referralRegistry_);
        emit ReferralRegistrySet(referralRegistry_);
    }

    function setProtocolFeeSettings(
        address recipient,
        uint16 protocolFeePpm,
        uint16 referralFeePpm
    ) public onlyOwner {
        protocolFeeSettings = ProtocolFeeSettings({
            recipient: recipient,
            protocolFeePpm: protocolFeePpm,
            referralFeePpm: referralFeePpm
        });
        require(
            protocolFeePpm <= MAX_PROTOCOL_FEE_PPM,
            TotalFeePpmExceedsMaxFeePpm()
        );
        require(
            protocolFeePpm > referralFeePpm,
            ProtocolFeePpmMustBeGreaterThanReferralFeePpm()
        );
        require(recipient != address(0), RecipientCantBeZeroAddress());
        require(protocolFeePpm > 0, ProtocolFeePpmMustBeGreaterThanZero());
        emit ProtocolFeeSettingsSet(protocolFeeSettings);
    }

    function setFeeSetter(address feeSetter, bool authorized)
        external
        onlyOwner
    {
        isFeeSetter[feeSetter] = authorized;
    }

    function updateFeesForPool(PoolId poolId, Fee[] calldata fees)
        external
        onlyOwner
    {
        delete poolIdToFees[poolId];
        _setFeesForPool(poolId, fees);
    }

    function initializeFeesForPool(PoolId poolId, Fee[] calldata fees)
        external
    {
        require(isFeeSetter[msg.sender], FeeSetterOnly());
        require(poolIdToFees[poolId].length == 0, FeesAlreadyInitialized());
        _setFeesForPool(poolId, fees);
    }

    function getFeesForPool(PoolId poolId)
        external
        view
        returns (Fee[] memory feeRecipients)
    {
        address referrer = referralRegistry.getReferrer(tx.origin);
        ProtocolFeeSettings memory settings = protocolFeeSettings;
        bool hasReferrer =
            referrer != address(0) && settings.referralFeePpm > 0;
        uint256 feeRecipientsLength = hasReferrer
            ? poolIdToFees[poolId].length + 2
            : poolIdToFees[poolId].length + 1;
        uint256 protocolFeeIndex = feeRecipientsLength - 1;

        feeRecipients = new Fee[](feeRecipientsLength);
        Fee[] memory poolFees = poolIdToFees[poolId];
        uint256 poolFeesLength = poolFees.length;
        uint256 index;
        for (; index < poolFeesLength; ++index) {
            feeRecipients[index] = poolFees[index];
        }
        if (hasReferrer) {
            feeRecipients[index] = Fee({
                recipient: referrer,
                feePpm: settings.referralFeePpm
            });
            feeRecipients[protocolFeeIndex] = Fee({
                recipient: settings.recipient,
                feePpm: settings.protocolFeePpm - settings.referralFeePpm
            });
        } else {
            feeRecipients[protocolFeeIndex] = Fee({
                recipient: settings.recipient,
                feePpm: settings.protocolFeePpm
            });
        }
    }

    function _setFeesForPool(PoolId poolId, Fee[] memory fees) internal {
        Fee[] storage poolFees = poolIdToFees[poolId];
        uint256 total;
        for (uint256 i; i < fees.length; ++i) {
            require(
                fees[i].recipient != address(0),
                RecipientCantBeZeroAddress()
            );
            poolFees.push(fees[i]);
            total += fees[i].feePpm;
        }
        poolIdToTotalFeePpm[poolId] = total;
        if (total > MAX_POOL_FEE_PPM) revert TotalFeePpmExceedsMaxFeePpm();
        if (poolFees.length > MAX_FEE_ARRAY_LENGTH) {
            revert FeeArrayLengthExceedsMaxFeeArrayLength();
        }
        emit FeeArraySet(poolId, poolFees);
    }

    function getTotalFeePpm(PoolId poolId)
        external
        view
        returns (uint256)
    {
        return poolIdToTotalFeePpm[poolId]
            + protocolFeeSettings.protocolFeePpm;
    }

    function addFeeRecipient(
        PoolId poolId,
        address recipient,
        uint16 feePpm
    ) external onlyOwner {
        require(recipient != address(0), RecipientCantBeZeroAddress());
        poolIdToFees[poolId].push(
            Fee({recipient: recipient, feePpm: feePpm})
        );
        poolIdToTotalFeePpm[poolId] += feePpm;
        require(
            poolIdToTotalFeePpm[poolId] <= MAX_POOL_FEE_PPM,
            TotalFeePpmExceedsMaxFeePpm()
        );
        if (poolIdToFees[poolId].length > MAX_FEE_ARRAY_LENGTH) {
            revert FeeArrayLengthExceedsMaxFeeArrayLength();
        }
        emit FeeArraySet(poolId, poolIdToFees[poolId]);
    }

    function removeFeeRecipient(
        PoolId poolId,
        address recipient,
        uint256 recipientIndex
    ) external onlyOwner {
        Fee[] storage fees = poolIdToFees[poolId];
        require(recipientIndex < fees.length, RecipientIndexOutOfBounds());
        require(
            fees[recipientIndex].recipient == recipient,
            RecipientIndexDoesNotMatchRecipient()
        );
        poolIdToTotalFeePpm[poolId] -= fees[recipientIndex].feePpm;
        fees[recipientIndex] = fees[fees.length - 1];
        fees.pop();
        emit FeeArraySet(poolId, fees);
    }

    function updateRecipientAddress(
        PoolId poolId,
        address recipientToReplace,
        address newRecipient,
        uint256 recipientIndex
    ) external onlyOwner {
        require(newRecipient != address(0), RecipientCantBeZeroAddress());
        Fee[] storage fees = poolIdToFees[poolId];
        require(recipientIndex < fees.length, RecipientIndexOutOfBounds());
        require(
            fees[recipientIndex].recipient == recipientToReplace,
            RecipientIndexDoesNotMatchRecipient()
        );
        fees[recipientIndex].recipient = newRecipient;
        emit FeeArraySet(poolId, fees);
    }

    function updateRecipientFeePpm(
        PoolId poolId,
        address recipient,
        uint16 feePpm,
        uint256 recipientIndex
    ) external onlyOwner {
        Fee[] storage fees = poolIdToFees[poolId];
        require(recipientIndex < fees.length, RecipientIndexOutOfBounds());
        require(
            fees[recipientIndex].recipient == recipient,
            RecipientIndexDoesNotMatchRecipient()
        );
        poolIdToTotalFeePpm[poolId] += feePpm;
        poolIdToTotalFeePpm[poolId] -= fees[recipientIndex].feePpm;
        fees[recipientIndex].feePpm = feePpm;
        require(
            poolIdToTotalFeePpm[poolId] <= MAX_POOL_FEE_PPM,
            TotalFeePpmExceedsMaxFeePpm()
        );
        emit FeeArraySet(poolId, fees);
    }

    function getProtocolFeeSettings()
        external
        view
        returns (ProtocolFeeSettings memory)
    {
        return protocolFeeSettings;
    }
}
