// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface IRobinhoodV2PrismManagerIdentity {
    function PAIR_TOKEN() external view returns (address);
}

/// @notice Independent registry for V2 Prism pair tokens and managers.
contract RobinhoodV2PrismRegistry is Ownable2Step {
    struct Pair {
        address manager;
        uint8 decimals;
        bool enabled;
        string label;
    }

    mapping(address pairToken => Pair pair) private _pairs;
    mapping(address manager => address pairToken) public pairTokenForManager;
    address[] private _pairTokens;

    error ZeroAddress();
    error NotContract(address account);
    error PairManagerMismatch(address expected, address actual);
    error ManagerAlreadyRegistered(address manager);
    error UnsupportedDecimals(uint8 decimals);
    error PairNotRegistered(address pairToken);

    event PairRegistered(
        address indexed pairToken,
        address indexed manager,
        uint8 decimals,
        string label
    );
    event PairStatusSet(address indexed pairToken, bool enabled);

    constructor(address initialOwner) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
    }

    function registerPair(address pairToken, address manager, string calldata label)
        external
        onlyOwner
    {
        if (pairToken == address(0) || manager == address(0)) revert ZeroAddress();
        if (pairToken.code.length == 0) revert NotContract(pairToken);
        if (manager.code.length == 0) revert NotContract(manager);

        address actual = IRobinhoodV2PrismManagerIdentity(manager).PAIR_TOKEN();
        if (actual != pairToken) revert PairManagerMismatch(pairToken, actual);
        address existingToken = pairTokenForManager[manager];
        if (existingToken != address(0) && existingToken != pairToken) {
            revert ManagerAlreadyRegistered(manager);
        }

        uint8 decimals = IERC20Metadata(pairToken).decimals();
        if (decimals != 18) revert UnsupportedDecimals(decimals);

        Pair storage existingPair = _pairs[pairToken];
        if (existingPair.manager == address(0)) {
            _pairTokens.push(pairToken);
        } else if (existingPair.manager != manager) {
            delete pairTokenForManager[existingPair.manager];
        }

        _pairs[pairToken] = Pair(manager, decimals, true, label);
        pairTokenForManager[manager] = pairToken;
        emit PairRegistered(pairToken, manager, decimals, label);
    }

    function setPairEnabled(address pairToken, bool enabled) external onlyOwner {
        Pair storage pair = _pairs[pairToken];
        if (pair.manager == address(0)) revert PairNotRegistered(pairToken);
        pair.enabled = enabled;
        emit PairStatusSet(pairToken, enabled);
    }

    function getPair(address pairToken) external view returns (Pair memory) {
        return _pairs[pairToken];
    }

    function isApprovedManager(address manager) external view returns (bool) {
        address pairToken = pairTokenForManager[manager];
        return pairToken != address(0) && _pairs[pairToken].enabled
            && _pairs[pairToken].manager == manager;
    }

    function pairCount() external view returns (uint256) {
        return _pairTokens.length;
    }

    function pairAt(uint256 index)
        external
        view
        returns (address pairToken, Pair memory pair)
    {
        pairToken = _pairTokens[index];
        pair = _pairs[pairToken];
    }

    function renounceOwnership() public view override onlyOwner {
        revert OwnableInvalidOwner(address(0));
    }
}
