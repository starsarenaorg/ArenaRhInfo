// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {IRobinhoodLaunchTokenFactory} from "./interfaces/IRobinhoodLaunchTokenFactory.sol";
import {IRobinhoodLaunchToken} from "./interfaces/IRobinhoodLaunchToken.sol";
import {IArenaPoolDeployer} from "./interfaces/IArenaPoolDeployer.sol";
import {IArenaFeeHelperMinimal} from "./interfaces/IArenaFeeHelperMinimal.sol";
import {ICreationFeeBuybackAdapter} from "./interfaces/ICreationFeeBuybackAdapter.sol";

interface IWETH9Parity {
    function deposit() external payable;
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IReferrerRegistryParity {
    function getReferrer(address referee) external view returns (address);
}

interface IFeeSwapRouterParity {
    function factory() external pure returns (address);
}

interface IOwnableLaunchToken {
    function renounceOwnership() external;
}

/// @notice Robinhood Chain native-pair launch-token manager.
/// @dev User, fee, whitelist, pause, owner, and curve behavior intentionally
/// follows the Arena launcher implementation. Chain-specific graduation is routed
/// through an IArenaPoolDeployer-compatible Robinhood Uniswap v4 adapter.
contract RobinhoodNativePairTokenManager is
    OwnableUpgradeable,
    UUPSUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    uint256 public constant GRANULARITY_SCALER = 1e18;
    uint8 public constant MAX_FEE_BASIS_POINT = 250;
    uint256 public constant INITIAL_TOKEN_ID = 1;
    uint256 public constant MAX_CREATOR_FEE_BASIS_POINT = 250;

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable STAKER_REWARD_TOKEN_VAULT;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable WETH_ADDRESS;

    uint256 public tokenIdentifier;
    address public protocolFeeDestination;
    uint8 public protocolFeeBasisPoint;
    uint8 public referralFeeBasisPoint;
    bool public canDeployLp;
    IFeeSwapRouterParity public uniswapV2Router02;
    IRobinhoodLaunchTokenFactory public tokenFactory;
    address public tokenCreationBuyFeeVault;
    uint88 public tokenCreationBuyFeeAmount;
    bool public transferTokenCreationBuyFeeToVault;
    uint256[99] private __gap;

    error InvalidFeeSetting();
    error InsufficentFunds();
    error CurveParametersNotAllowed();
    error TokenSplitNotAllowed();
    error DeadlineExpired();
    error SlippageExceeded();
    error InvalidWETH();
    error InvalidStakerRewardVault();
    error InvalidCreationFeeBuybackAdapter();
    error CreationFeeTransferFailed();

    struct TokenParameters {
        uint128 curveScaler;
        uint16 a;
        uint8 b;
        bool lpDeployed;
        uint8 lpPercentage;
        uint8 salePercentage;
        uint8 creatorFeeBasisPoints;
        address creatorAddress;
        address pairAddress;
        address tokenContractAddress;
    }

    struct FeeData {
        uint256 protocolFee;
        uint256 creatorFee;
        uint256 referralFee;
        uint256 totalFeeAmount;
        address tokenCreator;
        address referrerAddress;
    }

    struct V4PoolInitParams {
        IArenaPoolDeployer.PoolInitParams poolInitParams;
        uint16 creatorFeePpm;
        uint160 invertedStartingPrice;
    }

    mapping(uint256 => TokenParameters) public tokenParams;
    mapping(uint256 => uint256) public tokenBalanceOf;
    mapping(address => address) public referrers;
    mapping(bytes32 => uint256) public allowedTokenSupplyWithParameters;
    mapping(uint256 => uint256) public tokenSupply;
    address public LP_TOKEN_VAULT;
    IArenaPoolDeployer public arenaPoolDeployer;
    V4PoolInitParams public v4PoolInitParams;
    IReferrerRegistryParity public referrerRegistry;
    ICreationFeeBuybackAdapter public creationFeeBuybackAdapter;
    /// @notice Creator fee charged on every bonding-curve buy and sell.
    /// @dev Appended for UUPS storage compatibility with the deployed proxy.
    uint8 public bondingCreatorFeeBasisPoint;
    /// @dev Appended after all existing proxy state for storage compatibility.
    mapping(uint256 => uint8) private holderRewardsMode;
    mapping(address => bool) private nextLaunchHolderRewardsDisabled;

    /// @notice Retained for ABI compatibility. Holder rewards are permanently disabled.
    function setNextLaunchHolderRewards(bool enabled) external {
        enabled;
        delete nextLaunchHolderRewardsDisabled[msg.sender];
    }

    /// @notice Retained for ABI compatibility and always returns false.
    function holderRewardsEnabled(uint256 tokenId) public view returns (bool) {
        tokenId;
        return false;
    }

    event TokenCreated(uint256 tokenId, TokenParameters params, uint256 tokenSupply);
    event Sell(
        address user,
        uint256 tokenId,
        uint256 tokenAmount,
        uint256 reward,
        uint256 tokenSupply,
        address referrerAddress,
        uint256 referralFee,
        uint256 creatorFee,
        uint256 protocolFee
    );
    event Buy(
        address user,
        uint256 tokenId,
        uint256 tokenAmount,
        uint256 cost,
        uint256 tokenSupply,
        address referrerAddress,
        uint256 referralFee,
        uint256 creatorFee,
        uint256 protocolFee
    );
    event TokenLPCreated(uint256 tokenId, uint256 amountToken, uint256 amountNative, uint256 liquidity);
    event ProtocolFeeBasisPointSet(uint256 oldBasisPoint, uint256 newBasisPoint);
    event ReferralFeeBasisPointSet(uint256 oldBasisPoint, uint256 newBasisPoint);
    event AllowedTokenSupplyForParamsSet(
        uint256 a,
        uint256 b,
        uint256 curveScaler,
        uint256 tokenSupply,
        uint256 tokenSplit
    );
    event ProtocolFeeDestinationSet(address oldDestination, address newDestination);
    event LPDeployPermissionSet(bool value);
    event ReferrerSet(address user, address referrer);
    event TokenFactorySet(address oldTokenFactoryAddress, address newTokenFactory);
    event TokenCreationBuyFeeParamsSet(
        address tokenCreationBuyFeeVault,
        uint88 tokenCreationBuyFeeAmount,
        bool transferTokenCreationBuyFeeToVault
    );
    event CreationFeeBuybackAdapterSet(address oldAdapter, address newAdapter);
    event BondingCreatorFeeBasisPointSet(uint256 oldBasisPoint, uint256 newBasisPoint);

    modifier lpNotDeployed(uint256 tokenId) {
        require(!tokenParams[tokenId].lpDeployed, "LP already deployed!");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address weth_, address stakerRewardVault_) {
        if (weth_ == address(0)) revert InvalidWETH();
        if (stakerRewardVault_ == address(0)) revert InvalidStakerRewardVault();
        WETH_ADDRESS = weth_;
        STAKER_REWARD_TOKEN_VAULT = stakerRewardVault_;
        _disableInitializers();
    }

    function initialize(
        address uniswapV2RouterAddress,
        address ownerAddress,
        address tokenFactoryContractAddress
    ) public initializer {
        __Ownable_init(ownerAddress);
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        uniswapV2Router02 = IFeeSwapRouterParity(uniswapV2RouterAddress);
        tokenIdentifier = INITIAL_TOKEN_ID;
        tokenFactory = IRobinhoodLaunchTokenFactory(tokenFactoryContractAddress);
        canDeployLp = true;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function setReferralFeeBasisPoint(uint8 feeBasisPoint) external onlyOwner {
        if (feeBasisPoint > MAX_FEE_BASIS_POINT) revert InvalidFeeSetting();
        uint8 oldFeeBasisPoint = referralFeeBasisPoint;
        referralFeeBasisPoint = feeBasisPoint;
        emit ReferralFeeBasisPointSet(oldFeeBasisPoint, feeBasisPoint);
    }

    function setBondingCreatorFeeBasisPoint(uint8 feeBasisPoint) external onlyOwner {
        if (feeBasisPoint > MAX_CREATOR_FEE_BASIS_POINT) revert InvalidFeeSetting();
        uint8 oldFeeBasisPoint = bondingCreatorFeeBasisPoint;
        bondingCreatorFeeBasisPoint = feeBasisPoint;
        emit BondingCreatorFeeBasisPointSet(oldFeeBasisPoint, feeBasisPoint);
    }

    function setLpTokenVault(address lpTokenVault) external onlyOwner {
        LP_TOKEN_VAULT = lpTokenVault;
    }

    function setArenaPoolDeployer(address poolDeployer) external onlyOwner {
        arenaPoolDeployer = IArenaPoolDeployer(poolDeployer);
    }

    function setReferrerRegistry(address registry) external onlyOwner {
        referrerRegistry = IReferrerRegistryParity(registry);
    }

    function setCreationFeeBuybackAdapter(address adapter) external onlyOwner {
        if (adapter == address(0) || adapter.code.length == 0) {
            revert InvalidCreationFeeBuybackAdapter();
        }
        address oldAdapter = address(creationFeeBuybackAdapter);
        creationFeeBuybackAdapter = ICreationFeeBuybackAdapter(adapter);
        emit CreationFeeBuybackAdapterSet(oldAdapter, adapter);
    }

    function setPoolInitParams(
        IArenaPoolDeployer.PoolInitParams calldata poolInitParams,
        uint16 creatorFeePpm,
        uint160 invertedStartingPrice
    ) external onlyOwner {
        v4PoolInitParams.poolInitParams = poolInitParams;
        v4PoolInitParams.creatorFeePpm = creatorFeePpm;
        v4PoolInitParams.invertedStartingPrice = invertedStartingPrice;
        require(
            invertedStartingPrice < v4PoolInitParams.poolInitParams.startingPrice,
            "Inverted starting price must be greater than starting price"
        );
    }

    function setAllowedTokenSupplyForParameters(
        uint16 a,
        uint8 b,
        uint128 c,
        uint256 allowedTokenSupply,
        uint256 tokenSplit
    ) external onlyOwner {
        require(c != 0, "Invalid c coefficient");
        require(!(a > 0 && b > 0), "Invalid parameters");
        require(!(a == 0 && b == 0), "Both a and b are zero, should revert");
        require(tokenSplit <= 80 && tokenSplit >= 60, "Token split must be smaller");
        require(allowedTokenSupply % 1e18 == 0, "allowedtokenSupply must be divisible by 1e18");
        bytes32 parametersAndSupplyHash = keccak256(abi.encodePacked(a, b, c, tokenSplit));
        allowedTokenSupplyWithParameters[parametersAndSupplyHash] = allowedTokenSupply;
        emit AllowedTokenSupplyForParamsSet(a, b, c, allowedTokenSupply, tokenSplit);
    }

    function setLpDeployPermission(bool value) external onlyOwner {
        canDeployLp = value;
        emit LPDeployPermissionSet(value);
    }

    function setProtocolFeeBasisPoint(uint8 feeBasisPoint) external onlyOwner {
        if (feeBasisPoint > MAX_FEE_BASIS_POINT) revert InvalidFeeSetting();
        uint8 oldFeeBasisPoint = protocolFeeBasisPoint;
        protocolFeeBasisPoint = feeBasisPoint;
        emit ProtocolFeeBasisPointSet(oldFeeBasisPoint, feeBasisPoint);
    }

    function setFeeDestination(address feeDestination) external onlyOwner {
        require(feeDestination != address(0), "Invalid fee destination");
        address oldDestination = protocolFeeDestination;
        protocolFeeDestination = feeDestination;
        emit ProtocolFeeDestinationSet(oldDestination, feeDestination);
    }

    function setTokenFactory(address newTokenFactory) external onlyOwner {
        address oldTokenFactory = address(tokenFactory);
        tokenFactory = IRobinhoodLaunchTokenFactory(newTokenFactory);
        emit TokenFactorySet(oldTokenFactory, newTokenFactory);
    }

    function setRouter02(address newRouter02) external onlyOwner {
        uniswapV2Router02 = IFeeSwapRouterParity(newRouter02);
    }

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    function renounceOwnership() public override onlyOwner {}

    function setTokenCreationBuyFeeParams(
        address tokenCreationBuyFeeVault_,
        uint88 tokenCreationBuyFeeAmount_,
        bool transferTokenCreationBuyFeeToVault_
    ) external onlyOwner {
        require(tokenCreationBuyFeeVault_ != address(0), "Invalid token creation buy fee vault");
        tokenCreationBuyFeeAmount = tokenCreationBuyFeeAmount_;
        transferTokenCreationBuyFeeToVault = transferTokenCreationBuyFeeToVault_;
        tokenCreationBuyFeeVault = tokenCreationBuyFeeVault_;
        emit TokenCreationBuyFeeParamsSet(
            tokenCreationBuyFeeVault_,
            tokenCreationBuyFeeAmount_,
            transferTokenCreationBuyFeeToVault_
        );
    }

    function createTokenWithWL(
        uint16 a,
        uint8 b,
        uint128 curveScaler,
        uint8 creatorFeeBasisPoints,
        address tokenCreatorAddress,
        uint256 tokenSplit,
        string memory name,
        string memory symbol,
        uint256 amount,
        IRobinhoodLaunchToken.Whitelist calldata whitelist,
        uint256 maxTotalCost,
        uint256 deadline
    ) external payable whenNotPaused nonReentrant {
        _checkDeadline(deadline);
        _createToken(
            a,
            b,
            curveScaler,
            creatorFeeBasisPoints,
            tokenCreatorAddress,
            tokenSplit,
            name,
            symbol,
            amount
        );
        uint256 tokenId = tokenIdentifier - 1;
        address tokenContractAddress = tokenParams[tokenId].tokenContractAddress;
        IRobinhoodLaunchToken(tokenContractAddress).setWhitelistedAddresses(whitelist);
        IRobinhoodLaunchToken(tokenContractAddress).setCreator(tokenParams[tokenId].creatorAddress);
        if (amount > 0) {
            _handleInitialBuyFee();
            _buy(amount, tokenId, maxTotalCost, true);
        }
        if (_isLpTokenThresholdReached(tokenId)) _createLp(tokenId);
    }

    function createToken(
        uint16 a,
        uint8 b,
        uint128 curveScaler,
        uint8 creatorFeeBasisPoints,
        address tokenCreatorAddress,
        uint256 tokenSplit,
        string memory name,
        string memory symbol,
        uint256 amount,
        uint256 maxTotalCost,
        uint256 deadline
    ) public payable whenNotPaused nonReentrant {
        _checkDeadline(deadline);
        _createToken(
            a,
            b,
            curveScaler,
            creatorFeeBasisPoints,
            tokenCreatorAddress,
            tokenSplit,
            name,
            symbol,
            amount
        );
        if (amount > 0) {
            uint256 tokenId = tokenIdentifier - 1;
            _handleInitialBuyFee();
            _buy(amount, tokenId, maxTotalCost, true);
            if (_isLpTokenThresholdReached(tokenId)) _createLp(tokenId);
        }
    }

    function _createToken(
        uint16 a,
        uint8 b,
        uint128 curveScaler,
        uint8,
        address tokenCreatorAddress,
        uint256 tokenSplit,
        string memory name,
        string memory symbol,
        uint256 amount
    ) internal {
        require(tokenCreatorAddress != address(0), "Token creator address must be set");
        if (amount == 0) require(msg.value == 0, "Invalid msg.value");

        uint256 allowedSupply = allowedTotalSupplyWithParameters(a, b, curveScaler, tokenSplit);
        require(allowedSupply != 0, "There is no registered token supply");
        tokenSupply[tokenIdentifier] = allowedSupply;

        address tokenContractAddress = tokenFactory.deployToken(name, symbol, tokenIdentifier);
        TokenParameters storage params = tokenParams[tokenIdentifier];
        params.a = a;
        params.b = b;
        params.curveScaler = curveScaler;
        params.creatorFeeBasisPoints = bondingCreatorFeeBasisPoint;
        params.tokenContractAddress = tokenContractAddress;
        params.pairAddress = address(0);
        params.creatorAddress = tokenCreatorAddress;
        params.lpPercentage = 100 - uint8(tokenSplit);
        params.salePercentage = uint8(tokenSplit);
        holderRewardsMode[tokenIdentifier] = 2;
        delete nextLaunchHolderRewardsDisabled[msg.sender];

        emit TokenCreated(tokenIdentifier, params, allowedSupply);
        // The public entry points perform an optional initial buy only after
        // all launch configuration (including a whitelist) is active.
        ++tokenIdentifier;
    }

    function _buy(
        uint256 amount,
        uint256 tokenId,
        uint256 maxTotalCost,
        bool initialBuy
    )
        internal
        whenNotPaused
        lpNotDeployed(tokenId)
        returns (uint256 totalCost)
    {
        require(amount % GRANULARITY_SCALER == 0, "Amount must be a multiple of GRANULARITY_SCALER");
        amount /= GRANULARITY_SCALER;
        uint256 currentSupply;
        {
            uint256 currentSupplyInWei =
                IRobinhoodLaunchToken(tokenParams[tokenId].tokenContractAddress).totalSupply();
            (uint256 maxBuyableAmountInWei, uint256 maxTokensForSaleInWei) =
                _getMaxTokensForSaleWithSupply(tokenId, currentSupplyInWei);
            uint256 maxBuyableAmount = maxBuyableAmountInWei / GRANULARITY_SCALER;
            uint256 maxTokensForSale = maxTokensForSaleInWei / GRANULARITY_SCALER;
            if (amount > maxBuyableAmount) revert SlippageExceeded();
            currentSupply = currentSupplyInWei / GRANULARITY_SCALER;
            require(currentSupply + amount <= maxTokensForSale, "supply mismatch in buy");
        }
        require(amount > 0, "amount must be greater than 0");
        uint256 costs = calculateCostWithSupply(amount, tokenId, currentSupply);
        FeeData memory feeData = getFeeData(tokenId, costs, msg.sender);
        if (initialBuy) feeData.totalFeeAmount += tokenCreationBuyFeeAmount;
        totalCost = feeData.totalFeeAmount + costs;
        if (totalCost > maxTotalCost) revert SlippageExceeded();
        if (totalCost > msg.value) revert InsufficentFunds();
        IRobinhoodLaunchToken(tokenParams[tokenId].tokenContractAddress).mint(
            msg.sender, amount * GRANULARITY_SCALER
        );
        tokenBalanceOf[tokenId] += costs;
        _handleFeeTransfers(feeData, totalCost);
        emit Buy(
            msg.sender,
            tokenId,
            amount,
            totalCost,
            currentSupply + amount,
            feeData.referrerAddress,
            feeData.referralFee,
            feeData.creatorFee,
            feeData.protocolFee
        );
    }

    function buyAndCreateLpIfPossible(
        uint256 amount,
        uint256 tokenId,
        uint256 maxTotalCost,
        uint256 deadline
    ) public payable nonReentrant {
        _checkDeadline(deadline);
        _buy(amount, tokenId, maxTotalCost, false);
        if (_isLpTokenThresholdReached(tokenId)) _createLp(tokenId);
    }

    function sell(uint256 amount, uint256 tokenId, uint256 minNetReward, uint256 deadline)
        public
        whenNotPaused
        nonReentrant
        lpNotDeployed(tokenId)
    {
        _checkDeadline(deadline);
        require(amount % GRANULARITY_SCALER == 0, "Amount must be a multiple of GRANULARITY_SCALER");
        amount /= GRANULARITY_SCALER;
        require(amount > 0, "amount must be greater than zero");
        (uint256 reward, uint256 currentSupply) = calculateRewardAndSupply(amount, tokenId);
        FeeData memory feeData = getFeeData(tokenId, reward, msg.sender);
        uint256 netReward = reward - feeData.totalFeeAmount;
        if (netReward < minNetReward) revert SlippageExceeded();
        IRobinhoodLaunchToken(tokenParams[tokenId].tokenContractAddress).burn(
            msg.sender, amount * GRANULARITY_SCALER
        );
        tokenBalanceOf[tokenId] -= reward;
        _handleFeeTransfers(feeData, 0);
        payable(msg.sender).transfer(netReward);
        emit Sell(
            msg.sender,
            tokenId,
            amount,
            reward,
            currentSupply - amount,
            feeData.referrerAddress,
            feeData.referralFee,
            feeData.creatorFee,
            feeData.protocolFee
        );
    }

    function _createLp(uint256 tokenId) internal {
        require(canDeployLp, "Lp deploy not allowed right now!");
        TokenParameters memory paramsCached = tokenParams[tokenId];
        require(!paramsCached.lpDeployed, "Lp already deployed");
        tokenParams[tokenId].lpDeployed = true;

        uint256 allowedMaxSupply = tokenSupply[tokenId];
        uint256 onePercent = allowedMaxSupply / 100;
        uint256 tokenAmount = onePercent * paramsCached.lpPercentage;
        uint256 nativeAmount = tokenBalanceOf[tokenId];
        tokenBalanceOf[tokenId] = 0;
        if (paramsCached.pairAddress != address(0)) {
            IRobinhoodLaunchToken(paramsCached.tokenContractAddress).setBlacklistStatus(
                paramsCached.pairAddress, false
            );
        }

        IRobinhoodLaunchToken token = IRobinhoodLaunchToken(paramsCached.tokenContractAddress);
        token.mint(address(this), tokenAmount);

        IArenaFeeHelperMinimal.Fee[] memory fees = new IArenaFeeHelperMinimal.Fee[](1);
        V4PoolInitParams memory poolConfig = v4PoolInitParams;
        fees[0] = IArenaFeeHelperMinimal.Fee({
            recipient: paramsCached.creatorAddress,
            feePpm: poolConfig.creatorFeePpm
        });

        IWETH9Parity(WETH_ADDRESS).deposit{value: nativeAmount}();
        token.approve(address(arenaPoolDeployer), tokenAmount);
        IWETH9Parity(WETH_ADDRESS).approve(address(arenaPoolDeployer), nativeAmount);

        poolConfig.poolInitParams.recipient = LP_TOKEN_VAULT;
        poolConfig.poolInitParams.hookData = bytes("");
        if (WETH_ADDRESS > paramsCached.tokenContractAddress) {
            poolConfig.poolInitParams.startingPrice = poolConfig.invertedStartingPrice;
            int24 tickLowerCached = poolConfig.poolInitParams.tickLower;
            poolConfig.poolInitParams.tickLower = -poolConfig.poolInitParams.tickUpper;
            poolConfig.poolInitParams.tickUpper = -tickLowerCached;
            poolConfig.poolInitParams.token0Amount = tokenAmount;
            poolConfig.poolInitParams.token1Amount = nativeAmount;
            poolConfig.poolInitParams.token0 = paramsCached.tokenContractAddress;
            poolConfig.poolInitParams.token1 = WETH_ADDRESS;
        } else {
            poolConfig.poolInitParams.token0Amount = nativeAmount;
            poolConfig.poolInitParams.token1Amount = tokenAmount;
            poolConfig.poolInitParams.token0 = WETH_ADDRESS;
            poolConfig.poolInitParams.token1 = paramsCached.tokenContractAddress;
        }

        arenaPoolDeployer.initPoolAndSetFees(poolConfig.poolInitParams, fees);
        IOwnableLaunchToken(paramsCached.tokenContractAddress).renounceOwnership();
        require(token.totalSupply() == allowedMaxSupply, "total supply mismatch");
        emit TokenLPCreated(tokenId, tokenAmount, nativeAmount, 0);
    }

    function getFeeData(uint256 tokenId, uint256 rawCosts, address user)
        public
        view
        returns (FeeData memory feeData)
    {
        feeData.tokenCreator = tokenParams[tokenId].creatorAddress;
        feeData.referrerAddress = referrerRegistry.getReferrer(user);
        feeData.protocolFee = (rawCosts * protocolFeeBasisPoint + 5000) / 10000;
        feeData.creatorFee =
            (rawCosts * bondingCreatorFeeBasisPoint + 5000) / 10000;
        feeData.referralFee = (rawCosts * referralFeeBasisPoint + 5000) / 10000;
        if (feeData.referrerAddress == address(0)) {
            feeData.protocolFee += feeData.referralFee;
            feeData.referralFee = 0;
        }
        feeData.totalFeeAmount =
            feeData.protocolFee + feeData.creatorFee + feeData.referralFee;
    }

    function _handleFeeTransfers(FeeData memory feeData, uint256 totalCost) internal {
        uint256 protocolFeeAmount = feeData.protocolFee;
        if (feeData.referrerAddress != address(0)) {
            (bool success,) = payable(feeData.referrerAddress).call{
                value: feeData.referralFee,
                gas: 2300
            }("");
            if (!success) protocolFeeAmount += feeData.referralFee;
        }
        if (msg.value > totalCost) payable(msg.sender).transfer(msg.value - totalCost);
        if (feeData.tokenCreator != address(0) && feeData.creatorFee > 0) {
            (bool success,) = payable(feeData.tokenCreator).call{
                value: feeData.creatorFee,
                gas: 2300
            }("");
            if (!success) protocolFeeAmount += feeData.creatorFee;
        }
        (bool sentSuccess,) = payable(protocolFeeDestination).call{value: protocolFeeAmount}("");
        require(sentSuccess, "Failed to send protocol fee");
    }

    function calculateCost(uint256 amountInToken, uint256 tokenId) public view returns (uint256) {
        if (amountInToken == 0) return 0;
        uint256 totalSupply =
            IRobinhoodLaunchToken(tokenParams[tokenId].tokenContractAddress).totalSupply()
                / GRANULARITY_SCALER;
        return _integralCeil(tokenId, totalSupply + amountInToken, totalSupply);
    }

    function calculateCostWithFees(uint256 amountInToken, uint256 tokenId)
        public
        view
        returns (uint256)
    {
        if (amountInToken == 0) return 0;
        uint256 costs = calculateCost(amountInToken, tokenId);
        FeeData memory feeData = getFeeData(tokenId, costs, address(0));
        return costs + feeData.totalFeeAmount;
    }

    function calculateCostWithSupply(uint256 amountInToken, uint256 tokenId, uint256 totalSupply)
        public
        view
        returns (uint256)
    {
        if (amountInToken == 0) return 0;
        return _integralCeil(tokenId, totalSupply + amountInToken, totalSupply);
    }

    function calculateCostScaledParametric(
        uint256 amountInWei,
        uint256 supplyInWei,
        uint256 a,
        uint256 b,
        uint256 curveScaler
    ) public pure returns (uint256) {
        uint256 amountInTokens = amountInWei / GRANULARITY_SCALER;
        uint256 supplyInTokens = supplyInWei / GRANULARITY_SCALER;
        uint256 upperBound = supplyInTokens + amountInTokens;
        uint256 lowerBound = supplyInTokens;
        uint256 upperSum = (2 * (upperBound ** 3) * a) + (3 * (upperBound ** 2) * b);
        uint256 lowerSum = (2 * (lowerBound ** 3) * a) + (3 * (lowerBound ** 2) * b);
        return ((upperSum - lowerSum) + (curveScaler * 6 - 1)) / (curveScaler * 6);
    }

    function calculateCostScaledParametricWithFees(
        uint256 amountInWei,
        uint256 supplyInWei,
        uint256 a,
        uint256 b,
        uint256 curveScaler,
        uint256
    ) public view returns (uint256) {
        uint256 rawCosts =
            calculateCostScaledParametric(amountInWei, supplyInWei, a, b, curveScaler);
        return rawCosts + ((rawCosts * protocolFeeBasisPoint + 5000) / 10000)
            + (rawCosts * bondingCreatorFeeBasisPoint + 5000) / 10000
            + (rawCosts * referralFeeBasisPoint + 5000) / 10000;
    }

    /// @notice Pre-creation quote for an optional initial buy. Unlike the
    /// tokenId-based quote, this can be called before the launch token exists.
    /// A zero initial buy remains free, matching existing launcher behavior.
    function calculateInitialBuyCostScaledParametricWithFees(
        uint256 amountInWei,
        uint256 supplyInWei,
        uint256 a,
        uint256 b,
        uint256 curveScaler,
        uint256 creatorFeeBasisPoints
    ) external view returns (uint256) {
        if (amountInWei == 0) return 0;
        return calculateCostScaledParametricWithFees(
            amountInWei,
            supplyInWei,
            a,
            b,
            curveScaler,
            creatorFeeBasisPoints
        ) + tokenCreationBuyFeeAmount;
    }

    function calculateReward(uint256 amount, uint256 tokenId) public view returns (uint256) {
        if (amount == 0) return 0;
        uint256 totalSupply =
            IRobinhoodLaunchToken(tokenParams[tokenId].tokenContractAddress).totalSupply()
                / GRANULARITY_SCALER;
        return _integralFloor(tokenId, totalSupply, totalSupply - amount);
    }

    function calculateRewardWithFees(uint256 amount, uint256 tokenId)
        external
        view
        returns (uint256)
    {
        if (amount == 0) return 0;
        uint256 reward = calculateReward(amount, tokenId);
        FeeData memory feeData = getFeeData(tokenId, reward, address(0));
        return reward - feeData.totalFeeAmount;
    }

    function calculateRewardAndSupply(uint256 amount, uint256 tokenId)
        public
        view
        returns (uint256, uint256)
    {
        uint256 totalSupply =
            IRobinhoodLaunchToken(tokenParams[tokenId].tokenContractAddress).totalSupply()
                / GRANULARITY_SCALER;
        if (amount == 0) return (0, totalSupply);
        return (_integralFloor(tokenId, totalSupply, totalSupply - amount), totalSupply);
    }

    function _integralFloor(uint256 tokenId, uint256 upperBound, uint256 lowerBound)
        internal
        view
        returns (uint256)
    {
        TokenParameters memory params = tokenParams[tokenId];
        uint256 upperSum = ((2 * (upperBound ** 3)) * params.a) + (3 * (upperBound ** 2) * params.b);
        uint256 lowerSum = ((2 * (lowerBound ** 3)) * params.a) + (3 * (lowerBound ** 2) * params.b);
        return (upperSum - lowerSum) / (uint256(params.curveScaler) * 6);
    }

    function _integralCeil(uint256 tokenId, uint256 upperBound, uint256 lowerBound)
        internal
        view
        returns (uint256)
    {
        TokenParameters memory params = tokenParams[tokenId];
        uint256 upperSum = (2 * (upperBound ** 3) * params.a) + (3 * (upperBound ** 2) * params.b);
        uint256 lowerSum = (2 * (lowerBound ** 3) * params.a) + (3 * (lowerBound ** 2) * params.b);
        uint256 denominator = uint256(params.curveScaler) * 6;
        return ((upperSum - lowerSum) + (denominator - 1)) / denominator;
    }

    function allowedTotalSupplyWithParameters(uint16 a, uint8 b, uint128 c, uint256 tokenSplit)
        public
        view
        returns (uint256)
    {
        bytes32 parametersHash = keccak256(abi.encodePacked(a, b, c, tokenSplit));
        return allowedTokenSupplyWithParameters[parametersHash];
    }

    function getMaxTokensForSale(uint256 tokenId) public view returns (uint256 buyLimit) {
        uint256 currentSupply =
            IRobinhoodLaunchToken(tokenParams[tokenId].tokenContractAddress).totalSupply();
        (buyLimit,) = _getMaxTokensForSaleWithSupply(tokenId, currentSupply);
    }

    function getTokenParameters(uint256 tokenId)
        external
        view
        returns (TokenParameters memory params)
    {
        params = tokenParams[tokenId];
        params.creatorFeeBasisPoints = bondingCreatorFeeBasisPoint;
    }

    function getV4PoolInitParams() external view returns (V4PoolInitParams memory) {
        return v4PoolInitParams;
    }

    function _getMaxTokensForSaleWithSupply(uint256 tokenId, uint256 currentSupplyInWei)
        internal
        view
        returns (uint256 buyLimit, uint256 maxTokensForSale)
    {
        uint256 maxSupplyForSale =
            tokenSupply[tokenId] * tokenParams[tokenId].salePercentage / 100;
        if (maxSupplyForSale >= currentSupplyInWei) {
            return (maxSupplyForSale - currentSupplyInWei, maxSupplyForSale);
        }
        return (0, maxSupplyForSale);
    }

    function _isLpTokenThresholdReached(uint256 tokenId) internal view returns (bool) {
        return tokenSupply[tokenId] * tokenParams[tokenId].salePercentage
            == IRobinhoodLaunchToken(tokenParams[tokenId].tokenContractAddress).totalSupply() * 100;
    }

    receive() external payable {
        require(msg.sender == address(uniswapV2Router02), "Only Uniswap V2 Router can send Ether to this contract");
        payable(owner()).transfer(msg.value);
    }

    function _handleInitialBuyFee() internal {
        if (tokenCreationBuyFeeAmount == 0) return;
        if (transferTokenCreationBuyFeeToVault) {
            (bool success,) = payable(tokenCreationBuyFeeVault).call{
                value: tokenCreationBuyFeeAmount
            }("");
            if (!success) revert CreationFeeTransferFailed();
        } else {
            ICreationFeeBuybackAdapter adapter = creationFeeBuybackAdapter;
            if (address(adapter) == address(0)) revert InvalidCreationFeeBuybackAdapter();
            adapter.depositCreationFee{value: tokenCreationBuyFeeAmount}();
        }
    }

    function _checkDeadline(uint256 deadline) internal view {
        if (block.timestamp > deadline) revert DeadlineExpired();
    }
}
