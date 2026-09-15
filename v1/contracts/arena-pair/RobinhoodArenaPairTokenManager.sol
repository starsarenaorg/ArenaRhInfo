// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IArenaPoolDeployer} from "../robinhood/interfaces/IArenaPoolDeployer.sol";
import {IArenaFeeHelperMinimal} from "../robinhood/interfaces/IArenaFeeHelperMinimal.sol";
import {IRobinhoodLaunchTokenFactory} from "../robinhood/interfaces/IRobinhoodLaunchTokenFactory.sol";
import {IRobinhoodLaunchToken} from "../robinhood/interfaces/IRobinhoodLaunchToken.sol";

interface IRobinhoodArenaPairRouter {
    function factory() external pure returns (address);
}

interface IRobinhoodArenaPairReferrerRegistry {
    function getReferrer(address referee) external view returns (address);
}

/// @notice Robinhood Chain port of Arena's ERC-20 ARENA-pair launcher.
/// @dev Curve math, fee math, supply behavior and graduation flow intentionally
///      follow Arena's TokenManagerERC20. ARENA_ADDRESS is the canonical wrapped
///      ARENA representation selected when this implementation is deployed.
contract RobinhoodArenaPairTokenManager is
    OwnableUpgradeable,
    UUPSUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    uint256 public constant GRANULARITY_SCALER = 1e18;
    uint8 public constant MAX_FEE_BASIS_POINT = 250;
    uint256 public constant INITIAL_TOKEN_ID = 100_000_000_000;
    uint256 public constant MAX_CREATOR_FEE_BASIS_POINT = 250;

    address public immutable ARENA_ADDRESS;
    IERC20 public immutable ARENA_CONTRACT;
    address public immutable STAKER_REWARD_TOKEN_VAULT;

    address public NATIVE_HELPER;
    uint256 public tokenIdentifier;
    address public protocolFeeDestination;
    uint8 public protocolFeeBasisPoint;
    uint8 public referralFeeBasisPoint;
    bool public canDeployLp;
    IRobinhoodArenaPairRouter public uniswapV2Router02;
    IRobinhoodLaunchTokenFactory public tokenFactory;
    address public tokenCreationBuyFeeVault;
    uint88 public tokenCreationBuyFeeAmount;
    bool public transferTokenCreationBuyFeeToVault;
    uint256[99] private __gap;

    error InvalidFeeSetting();
    error InvalidArenaToken();
    error InvalidStakerRewardVault();

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
    event TokenLPCreated(uint256 tokenId, uint256 amountToken, uint256 amountARENA, uint256 liquidity);
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
    event TokenFactorySet(address oldTokenFactoryAddress, address newTokenFactory);
    event TokenCreationBuyFeeParamsSet(
        address tokenCreationBuyFeeVault,
        uint88 tokenCreationBuyFeeAmount,
        bool transferTokenCreationBuyFeeToVault
    );
    event BondingCreatorFeeBasisPointSet(uint256 oldBasisPoint, uint256 newBasisPoint);

    struct TokenParameters {
        uint128 curveScaler;
        uint32 a;
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

    struct TokenInfo {
        uint8 protocolFee;
        uint8 creatorFee;
        uint8 referralFee;
        uint88 tokenCreationBuyFee;
        uint128 curveScaler;
        uint32 a;
        address tokenAddress;
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
    IRobinhoodArenaPairReferrerRegistry public referrerRegistry;
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

    modifier lpNotDeployed(uint256 tokenId) {
        require(!tokenParams[tokenId].lpDeployed, "LP already deployed!");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address arenaAddress_, address stakerRewardTokenVault_) {
        if (arenaAddress_ == address(0)) revert InvalidArenaToken();
        if (stakerRewardTokenVault_ == address(0)) revert InvalidStakerRewardVault();
        ARENA_ADDRESS = arenaAddress_;
        ARENA_CONTRACT = IERC20(arenaAddress_);
        STAKER_REWARD_TOKEN_VAULT = stakerRewardTokenVault_;
        _disableInitializers();
    }

    function initialize(address routerAddress, address ownerAddress, address tokenFactoryAddress)
        public
        initializer
    {
        __Ownable_init(ownerAddress);
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        uniswapV2Router02 = IRobinhoodArenaPairRouter(routerAddress);
        tokenIdentifier = INITIAL_TOKEN_ID;
        tokenFactory = IRobinhoodLaunchTokenFactory(tokenFactoryAddress);
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

    function setAllowedTokenSupplyForParameters(
        uint32 a,
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
        address oldTokenFactoryAddress = address(tokenFactory);
        tokenFactory = IRobinhoodLaunchTokenFactory(newTokenFactory);
        emit TokenFactorySet(oldTokenFactoryAddress, newTokenFactory);
    }

    function setNativeHelper(address newNativeHelper) external onlyOwner {
        NATIVE_HELPER = newNativeHelper;
    }

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    function setLpTokenVault(address lpTokenVault) external onlyOwner {
        LP_TOKEN_VAULT = lpTokenVault;
    }

    function setArenaPoolDeployer(address newArenaPoolDeployer) external onlyOwner {
        arenaPoolDeployer = IArenaPoolDeployer(newArenaPoolDeployer);
    }

    function setReferrerRegistry(address newReferrerRegistry) external onlyOwner {
        referrerRegistry = IRobinhoodArenaPairReferrerRegistry(newReferrerRegistry);
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

    function renounceOwnership() public override onlyOwner {}

    function setTokenCreationBuyFeeParams(
        address creationFeeVault,
        uint88 creationFeeAmount,
        bool transferCreationFeeToVault
    ) external onlyOwner {
        require(creationFeeVault != address(0), "Invalid token creation buy fee vault");
        tokenCreationBuyFeeAmount = creationFeeAmount;
        transferTokenCreationBuyFeeToVault = transferCreationFeeToVault;
        tokenCreationBuyFeeVault = creationFeeVault;
        emit TokenCreationBuyFeeParamsSet(
            creationFeeVault, creationFeeAmount, transferCreationFeeToVault
        );
    }

    function createToken(
        uint32 a,
        uint8 b,
        uint128 curveScaler,
        uint8 creatorFeeBasisPoints,
        address tokenCreatorAddress,
        uint256 tokenSplit,
        string memory name,
        string memory symbol,
        uint256 amount
    ) public whenNotPaused nonReentrant {
        _createToken(
            a,
            b,
            curveScaler,
            creatorFeeBasisPoints,
            tokenCreatorAddress,
            tokenSplit,
            name,
            symbol,
            amount,
            false
        );
    }

    function _createToken(
        uint32 a,
        uint8 b,
        uint128 curveScaler,
        uint8,
        address tokenCreatorAddress,
        uint256 tokenSplit,
        string memory name,
        string memory symbol,
        uint256 amount,
        bool whitelistLaunch
    ) internal {
        require(tokenCreatorAddress != address(0), "Token creator address must be set");

        uint256 allowedSupply =
            allowedTotalSupplyWithParameters(a, b, curveScaler, tokenSplit);
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
        if (amount > 0) {
            _handleInitialBuyFee();
            if (whitelistLaunch) {
                _buy(amount, tokenIdentifier, tokenCreatorAddress, type(uint256).max);
            } else {
                _buyAndCreateLpIfPossible(
                    amount, tokenIdentifier, tokenCreatorAddress, type(uint256).max
                );
            }
        }
        ++tokenIdentifier;
    }

    function createTokenWithWL(
        uint32 a,
        uint8 b,
        uint128 curveScaler,
        uint8 creatorFeeBasisPoints,
        address tokenCreatorAddress,
        uint256 tokenSplit,
        string memory name,
        string memory symbol,
        uint256 amount,
        IRobinhoodLaunchToken.Whitelist calldata whitelist
    ) external whenNotPaused nonReentrant {
        _createToken(
            a,
            b,
            curveScaler,
            creatorFeeBasisPoints,
            tokenCreatorAddress,
            tokenSplit,
            name,
            symbol,
            amount,
            true
        );
        uint256 tokenId = tokenIdentifier - 1;
        IRobinhoodLaunchToken token = IRobinhoodLaunchToken(tokenParams[tokenId].tokenContractAddress);
        token.setWhitelistedAddresses(whitelist);
        token.setCreator(tokenParams[tokenId].creatorAddress);
        if (_isLpTokenThresholdReached(tokenId)) _createLp(tokenId);
    }

    function _buy(uint256 amount, uint256 tokenId, address user, uint256 maxArenaToSpend)
        internal
        whenNotPaused
        lpNotDeployed(tokenId)
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
            if (amount > maxBuyableAmount) amount = maxBuyableAmount;
            currentSupply = currentSupplyInWei / GRANULARITY_SCALER;
            require(currentSupply + amount <= maxTokensForSale, "supply mismatch in buy");
        }
        require(amount > 0, "amount must be greater than 0");
        uint256 costs = calculateCostWithSupply(amount, tokenId, currentSupply);
        FeeData memory feeData = getFeeData(tokenId, costs, user);
        uint256 totalCost = feeData.totalFeeAmount + costs;
        require(totalCost <= maxArenaToSpend, "Insufficient arena to spend");
        ARENA_CONTRACT.safeTransferFrom(msg.sender, address(this), totalCost);
        IRobinhoodLaunchToken(tokenParams[tokenId].tokenContractAddress).mint(
            msg.sender, amount * GRANULARITY_SCALER
        );
        tokenBalanceOf[tokenId] += costs;
        _handleFeeTransfers(feeData);
        emit Buy(
            user,
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
        uint256 maxArenaToSpend
    ) public nonReentrant {
        _buyAndCreateLpIfPossible(amount, tokenId, msg.sender, maxArenaToSpend);
    }

    function _buyAndCreateLpIfPossible(
        uint256 amount,
        uint256 tokenId,
        address user,
        uint256 maxArenaToSpend
    ) internal {
        _buy(amount, tokenId, user, maxArenaToSpend);
        if (_isLpTokenThresholdReached(tokenId)) _createLp(tokenId);
    }

    function _sell(uint256 amount, uint256 tokenId, address user, uint256 minArenaToReceive)
        internal
        whenNotPaused
        lpNotDeployed(tokenId)
        returns (uint256 amountOut)
    {
        require(amount % GRANULARITY_SCALER == 0, "Amount must be a multiple of GRANULARITY_SCALER");
        amount /= GRANULARITY_SCALER;
        require(amount > 0, "amount must be greater than zero");
        (uint256 reward, uint256 currentSupply) = calculateRewardAndSupply(amount, tokenId);
        FeeData memory feeData = getFeeData(tokenId, reward, user);
        IRobinhoodLaunchToken(tokenParams[tokenId].tokenContractAddress).burn(
            msg.sender, amount * GRANULARITY_SCALER
        );
        tokenBalanceOf[tokenId] -= reward;
        _handleFeeTransfers(feeData);
        ARENA_CONTRACT.safeTransfer(msg.sender, reward - feeData.totalFeeAmount);
        emit Sell(
            user,
            tokenId,
            amount,
            reward,
            currentSupply - amount,
            feeData.referrerAddress,
            feeData.referralFee,
            feeData.creatorFee,
            feeData.protocolFee
        );
        amountOut = reward - feeData.totalFeeAmount;
        require(amountOut >= minArenaToReceive, "Insufficient arena to receive");
    }

    function sell(uint256 amount, uint256 tokenId, uint256 minArenaToReceive)
        public
        whenNotPaused
        lpNotDeployed(tokenId)
        nonReentrant
        returns (uint256 amountOut)
    {
        amountOut = _sell(amount, tokenId, msg.sender, minArenaToReceive);
    }

    function _createLp(uint256 tokenId) internal {
        require(canDeployLp, "Lp deploy not allowed right now!");
        TokenParameters memory paramsCached = tokenParams[tokenId];
        require(!paramsCached.lpDeployed, "Lp already deployed");
        tokenParams[tokenId].lpDeployed = true;

        uint256 allowedMaxSupply = tokenSupply[tokenId];
        uint256 onePercent = allowedMaxSupply / 100;
        uint256 tokenAmount = onePercent * paramsCached.lpPercentage;
        uint256 arenaAmount = tokenBalanceOf[tokenId];
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
        IERC20(address(token)).forceApprove(address(arenaPoolDeployer), tokenAmount);
        ARENA_CONTRACT.forceApprove(address(arenaPoolDeployer), arenaAmount);

        poolConfig.poolInitParams.recipient = LP_TOKEN_VAULT;
        poolConfig.poolInitParams.hookData = bytes("");
        if (ARENA_ADDRESS > paramsCached.tokenContractAddress) {
            poolConfig.poolInitParams.startingPrice = poolConfig.invertedStartingPrice;
            int24 tickLowerCached = poolConfig.poolInitParams.tickLower;
            poolConfig.poolInitParams.tickLower = -poolConfig.poolInitParams.tickUpper;
            poolConfig.poolInitParams.tickUpper = -tickLowerCached;
            poolConfig.poolInitParams.token0Amount = tokenAmount;
            poolConfig.poolInitParams.token1Amount = arenaAmount;
            poolConfig.poolInitParams.token0 = paramsCached.tokenContractAddress;
            poolConfig.poolInitParams.token1 = ARENA_ADDRESS;
        } else {
            poolConfig.poolInitParams.token0Amount = arenaAmount;
            poolConfig.poolInitParams.token1Amount = tokenAmount;
            poolConfig.poolInitParams.token0 = ARENA_ADDRESS;
            poolConfig.poolInitParams.token1 = paramsCached.tokenContractAddress;
        }
        arenaPoolDeployer.initPoolAndSetFees(poolConfig.poolInitParams, fees);
        OwnableUpgradeable(paramsCached.tokenContractAddress).renounceOwnership();
        require(token.totalSupply() == allowedMaxSupply, "total supply mismatch");
        emit TokenLPCreated(tokenId, tokenAmount, arenaAmount, 0);
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

    function _handleFeeTransfers(FeeData memory feeData) internal {
        if (feeData.referrerAddress != address(0)) {
            ARENA_CONTRACT.safeTransfer(feeData.referrerAddress, feeData.referralFee);
        }
        if (feeData.tokenCreator != address(0) && feeData.creatorFee > 0) {
            ARENA_CONTRACT.safeTransfer(feeData.tokenCreator, feeData.creatorFee);
        }
        ARENA_CONTRACT.safeTransfer(protocolFeeDestination, feeData.protocolFee);
    }

    function calculateCost(uint256 amountInToken, uint256 tokenId)
        public
        view
        returns (uint256)
    {
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
    ) external view returns (uint256) {
        uint256 rawCosts =
            calculateCostScaledParametric(amountInWei, supplyInWei, a, b, curveScaler);
        return rawCosts + ((rawCosts * protocolFeeBasisPoint + 5000) / 10000)
            + ((rawCosts * bondingCreatorFeeBasisPoint + 5000) / 10000)
            + ((rawCosts * referralFeeBasisPoint + 5000) / 10000);
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
        uint256 upperSum = ((2 * (upperBound ** 3)) * params.a)
            + (3 * (upperBound ** 2) * params.b);
        uint256 lowerSum = ((2 * (lowerBound ** 3)) * params.a)
            + (3 * (lowerBound ** 2) * params.b);
        return (upperSum - lowerSum) / (uint256(params.curveScaler) * 6);
    }

    function _integralCeil(uint256 tokenId, uint256 upperBound, uint256 lowerBound)
        internal
        view
        returns (uint256)
    {
        TokenParameters memory params = tokenParams[tokenId];
        uint256 upperSum = (2 * (upperBound ** 3) * params.a)
            + (3 * (upperBound ** 2) * params.b);
        uint256 lowerSum = (2 * (lowerBound ** 3) * params.a)
            + (3 * (lowerBound ** 2) * params.b);
        uint256 denominator = uint256(params.curveScaler) * 6;
        return ((upperSum - lowerSum) + (denominator - 1)) / denominator;
    }

    function allowedTotalSupplyWithParameters(
        uint32 a,
        uint8 b,
        uint128 c,
        uint256 tokenSplit
    ) public view returns (uint256 allowedSupply) {
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

    function _handleInitialBuyFee() internal {
        if (tokenCreationBuyFeeAmount > 0) {
            ARENA_CONTRACT.safeTransferFrom(
                msg.sender, tokenCreationBuyFeeVault, tokenCreationBuyFeeAmount
            );
        }
    }

    function buyAndCreateLpIfPossibleWithUser(
        uint256 amount,
        uint256 tokenId,
        address user,
        uint256 maxArenaToSpend
    ) external nonReentrant {
        require(msg.sender == NATIVE_HELPER, "Only NativeHelper can buy and create lp");
        _buyAndCreateLpIfPossible(amount, tokenId, user, maxArenaToSpend);
    }

    function sellWithUser(
        uint256 amount,
        uint256 tokenId,
        address user,
        uint256 minArenaToReceive
    ) external nonReentrant returns (uint256 amountOut) {
        require(msg.sender == NATIVE_HELPER, "Only NativeHelper can sell");
        amountOut = _sell(amount, tokenId, user, minArenaToReceive);
    }

    function getFeeInfoAndCurrentTokenIdentifier(uint256 tokenId)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256)
    {
        return (
            protocolFeeBasisPoint,
            referralFeeBasisPoint,
            bondingCreatorFeeBasisPoint,
            tokenCreationBuyFeeAmount,
            tokenIdentifier
        );
    }

    function getTokenInfo(uint256 tokenId) external view returns (TokenInfo memory) {
        return TokenInfo({
            protocolFee: protocolFeeBasisPoint,
            creatorFee: bondingCreatorFeeBasisPoint,
            referralFee: referralFeeBasisPoint,
            tokenCreationBuyFee: tokenCreationBuyFeeAmount,
            curveScaler: tokenParams[tokenId].curveScaler,
            a: tokenParams[tokenId].a,
            tokenAddress: tokenParams[tokenId].tokenContractAddress
        });
    }

    receive() external payable {
        require(
            msg.sender == address(uniswapV2Router02),
            "Only Uniswap V2 Router can send Ether to this contract"
        );
        payable(owner()).transfer(msg.value);
    }
}
