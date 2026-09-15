// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IRobinhoodLaunchTokenFactory} from "../../../contracts/contracts/robinhood/interfaces/IRobinhoodLaunchTokenFactory.sol";
import {IRobinhoodLaunchToken} from "../../../contracts/contracts/robinhood/interfaces/IRobinhoodLaunchToken.sol";
import {IArenaPoolDeployer} from "../../../contracts/contracts/robinhood/interfaces/IArenaPoolDeployer.sol";
import {IRobinhoodDividendController} from "./interfaces/IRobinhoodDividendController.sol";
import {IRobinhoodDividendFeeHelper} from "./interfaces/IRobinhoodDividendFeeHelper.sol";
import {IRobinhoodDividendFeePoolDeployer} from "./interfaces/IRobinhoodDividendFeePoolDeployer.sol";

interface IPrismReferrerRegistryV2 {
    function getReferrer(address referee) external view returns (address);
}

interface IOwnableLaunchTokenV2 {
    function renounceOwnership() external;
}

/// @notice Fresh V2 Prism manager for one ERC-20 paired token.
/// @dev This contract is intended for a new V2 manager proxy. Existing V1
/// launches should stay on the old manager.
contract RobinhoodPrismTokenManagerV2 is
    OwnableUpgradeable,
    UUPSUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    uint256 public constant GRANULARITY_SCALER = 1e18;
    uint8 public constant MAX_FEE_BASIS_POINT = 250;
    uint256 public constant TOKEN_ID_RANGE_SIZE = 100_000_000_000;
    uint8 public constant MAX_CREATOR_FEE_BASIS_POINT = 100;
    uint16 public constant MAX_DIVIDEND_FEE_BASIS_POINT = 500;

    address public PAIR_TOKEN;
    address public NATIVE_HELPER;
    uint256 public tokenIdentifier;
    uint256 public tokenIdRangeEnd;
    address public protocolFeeDestination;
    uint8 public protocolFeeBasisPoint;
    uint8 public referralFeeBasisPoint;
    bool public canDeployLp;
    IRobinhoodLaunchTokenFactory public tokenFactory;
    address public tokenCreationBuyFeeVault;
    uint88 public tokenCreationBuyFeeAmount;

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
        uint16 dividendFeeBasisPoints;
        address creatorFeeRecipient;
        address postBondCreatorFeeRecipient;
        uint16 postBondCreatorFeePpm;
    }

    struct FeeData {
        uint256 protocolFee;
        uint256 creatorFee;
        uint256 referralFee;
        uint256 dividendFee;
        uint256 totalFeeAmount;
        address creatorFeeRecipient;
        address referrerAddress;
    }

    struct V4PoolInitParams {
        IArenaPoolDeployer.PoolInitParams poolInitParams;
        // Kept in the return tuple so existing Prism trade routers can decode
        // poolInitParams. V2 creator fees are configured per launch instead.
        uint16 creatorFeePpm;
        uint160 invertedStartingPrice;
    }

    mapping(uint256 => TokenParameters) public tokenParams;
    mapping(uint256 => uint256) public tokenBalanceOf;
    mapping(bytes32 => uint256) public allowedTokenSupplyWithParameters;
    mapping(uint256 => uint256) public tokenSupply;

    address public LP_TOKEN_VAULT;
    IRobinhoodDividendFeePoolDeployer public arenaPoolDeployer;
    V4PoolInitParams public v4PoolInitParams;
    IPrismReferrerRegistryV2 public referrerRegistry;
    IRobinhoodDividendController public dividendController;
    IRobinhoodDividendFeeHelper public dividendFeeHelper;

    uint256[50] private __gap;

    error InvalidFeeSetting();
    error CurveParametersNotAllowed();
    error TokenSplitNotAllowed();
    error DeadlineExpired();
    error SlippageExceeded();
    error InvalidPairToken();
    error UnsupportedPairTokenDecimals(uint8 decimals);
    error UnsupportedPairTokenTransfer();
    error InvalidTokenIdRange();
    error TokenIdRangeExhausted();
    error InvalidLpTokenVault();
    error InvalidCreationFeeVault();
    error InvalidDividendController();
    error InvalidDividendFeeHelper();
    error InvalidTokenFactory();
    error InvalidPoolDeployer();
    error CreatorOnly();
    error CreatorFeeCanOnlyDecrease();

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
        uint256 protocolFee,
        uint256 dividendFee
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
        uint256 protocolFee,
        uint256 dividendFee
    );
    event TokenLPCreated(uint256 tokenId, uint256 amountToken, uint256 amountPair, uint256 liquidity);
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
        uint88 tokenCreationBuyFeeAmount
    );
    event NativeHelperSet(address indexed oldHelper, address indexed newHelper);
    event DividendControllerSet(address indexed oldController, address indexed newController);
    event DividendFeeHelperSet(address indexed oldHelper, address indexed newHelper);
    event ArenaPoolDeployerSet(address indexed oldPoolDeployer, address indexed newPoolDeployer);
    event CreatorFeeConfigSet(
        uint256 indexed tokenId,
        address indexed creator,
        address indexed recipient,
        uint8 feeBasisPoints,
        uint16 postBondFeePpm
    );
    event DividendFeeCollected(uint256 indexed tokenId, uint256 amount);

    modifier lpNotDeployed(uint256 tokenId) {
        require(!tokenParams[tokenId].lpDeployed, "LP already deployed!");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address ownerAddress,
        address pairTokenAddress,
        address tokenFactoryContractAddress,
        address dividendControllerAddress,
        address dividendFeeHelperAddress,
        address poolDeployerAddress,
        uint256 initialTokenId
    ) public initializer {
        __Ownable_init(ownerAddress);
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        if (pairTokenAddress == address(0) || pairTokenAddress.code.length == 0) {
            revert InvalidPairToken();
        }
        uint8 pairDecimals = IERC20Metadata(pairTokenAddress).decimals();
        if (pairDecimals != 18) revert UnsupportedPairTokenDecimals(pairDecimals);
        PAIR_TOKEN = pairTokenAddress;
        if (
            initialTokenId < TOKEN_ID_RANGE_SIZE
                || initialTokenId % TOKEN_ID_RANGE_SIZE != 0
        ) {
            revert InvalidTokenIdRange();
        }
        tokenIdentifier = initialTokenId;
        tokenIdRangeEnd = initialTokenId + TOKEN_ID_RANGE_SIZE;
        _setTokenFactory(tokenFactoryContractAddress);
        _setDividendController(dividendControllerAddress);
        _setDividendFeeHelper(dividendFeeHelperAddress);
        _setArenaPoolDeployer(poolDeployerAddress);
        _pause();
        canDeployLp = false;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function setReferralFeeBasisPoint(uint8 feeBasisPoint) external onlyOwner {
        if (feeBasisPoint > MAX_FEE_BASIS_POINT) revert InvalidFeeSetting();
        uint8 oldFeeBasisPoint = referralFeeBasisPoint;
        referralFeeBasisPoint = feeBasisPoint;
        emit ReferralFeeBasisPointSet(oldFeeBasisPoint, feeBasisPoint);
    }

    function setDividendController(address controller) external onlyOwner {
        _setDividendController(controller);
    }

    function setDividendFeeHelper(address helper) external onlyOwner {
        _setDividendFeeHelper(helper);
    }

    function setLpTokenVault(address lpTokenVault) external onlyOwner {
        if (lpTokenVault == address(0) || lpTokenVault.code.length == 0) {
            revert InvalidLpTokenVault();
        }
        LP_TOKEN_VAULT = lpTokenVault;
    }

    function setArenaPoolDeployer(address poolDeployer) external onlyOwner {
        _setArenaPoolDeployer(poolDeployer);
    }

    function setReferrerRegistry(address registry) external onlyOwner {
        referrerRegistry = IPrismReferrerRegistryV2(registry);
    }

    /// @notice Compatibility getter used by existing Prism routers.
    function ARENA_ADDRESS() external view returns (address) {
        return PAIR_TOKEN;
    }

    function setNativeHelper(address newNativeHelper) external onlyOwner {
        address oldNativeHelper = NATIVE_HELPER;
        NATIVE_HELPER = newNativeHelper;
        emit NativeHelperSet(oldNativeHelper, newNativeHelper);
    }

    function setPoolInitParams(
        IArenaPoolDeployer.PoolInitParams calldata poolInitParams,
        uint160 invertedStartingPrice
    ) external onlyOwner {
        v4PoolInitParams.poolInitParams = poolInitParams;
        v4PoolInitParams.invertedStartingPrice = invertedStartingPrice;
        require(
            invertedStartingPrice < v4PoolInitParams.poolInitParams.startingPrice,
            "Inverted starting price must be greater than starting price"
        );
    }

    function setAllowedTokenSupplyForParameters(
        uint32 a,
        uint8 b,
        uint128 c,
        uint256 allowedTokenSupply,
        uint256 tokenSplit
    ) external onlyOwner {
        if (c == 0 || (a > 0 && b > 0) || (a == 0 && b == 0)) {
            revert CurveParametersNotAllowed();
        }
        if (
            tokenSplit > 80 || tokenSplit < 60
                || allowedTokenSupply % 1e18 != 0
        ) revert TokenSplitNotAllowed();
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
        _setTokenFactory(newTokenFactory);
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
        uint88 tokenCreationBuyFeeAmount_
    ) external onlyOwner {
        if (tokenCreationBuyFeeVault_ == address(0)) {
            revert InvalidCreationFeeVault();
        }
        tokenCreationBuyFeeAmount = tokenCreationBuyFeeAmount_;
        tokenCreationBuyFeeVault = tokenCreationBuyFeeVault_;
        emit TokenCreationBuyFeeParamsSet(
            tokenCreationBuyFeeVault_, tokenCreationBuyFeeAmount_
        );
    }

    function createTokenWithWL(
        uint32 a,
        uint8 b,
        uint128 curveScaler,
        uint8 creatorFeeBasisPoints,
        uint16 dividendFeeBasisPoints,
        address tokenCreatorAddress,
        uint256 tokenSplit,
        string memory name,
        string memory symbol,
        uint256 amount,
        IRobinhoodLaunchToken.Whitelist calldata whitelist,
        uint256 maxTotalCost,
        uint256 deadline
    ) external whenNotPaused nonReentrant {
        _checkDeadline(deadline);
        uint256 tokenId = _createToken(
            a,
            b,
            curveScaler,
            creatorFeeBasisPoints,
            dividendFeeBasisPoints,
            tokenCreatorAddress,
            tokenSplit,
            name,
            symbol
        );
        address tokenContractAddress = tokenParams[tokenId].tokenContractAddress;
        IRobinhoodLaunchToken(tokenContractAddress).setWhitelistedAddresses(whitelist);
        IRobinhoodLaunchToken(tokenContractAddress).setCreator(tokenParams[tokenId].creatorAddress);
        _afterCreate(tokenId, amount, maxTotalCost);
    }

    function createToken(
        uint32 a,
        uint8 b,
        uint128 curveScaler,
        uint8 creatorFeeBasisPoints,
        uint16 dividendFeeBasisPoints,
        address tokenCreatorAddress,
        uint256 tokenSplit,
        string memory name,
        string memory symbol,
        uint256 amount,
        uint256 maxTotalCost,
        uint256 deadline
    ) public whenNotPaused nonReentrant {
        _checkDeadline(deadline);
        uint256 tokenId = _createToken(
            a,
            b,
            curveScaler,
            creatorFeeBasisPoints,
            dividendFeeBasisPoints,
            tokenCreatorAddress,
            tokenSplit,
            name,
            symbol
        );
        _afterCreate(tokenId, amount, maxTotalCost);
    }

    function creatorUpdateCreatorFee(
        uint256 tokenId,
        uint8 newFeeBasisPoints,
        address newRecipient
    ) external {
        TokenParameters storage params = tokenParams[tokenId];
        if (msg.sender != params.creatorAddress) revert CreatorOnly();
        if (newFeeBasisPoints > params.creatorFeeBasisPoints) {
            revert CreatorFeeCanOnlyDecrease();
        }
        _setCreatorFeeConfig(tokenId, params.creatorAddress, newRecipient, newFeeBasisPoints);
        if (params.lpDeployed) {
            dividendFeeHelper.creatorUpdateTokenFeeFromManager(
                tokenId,
                msg.sender,
                newRecipient,
                uint16(newFeeBasisPoints) * 100
            );
        }
    }

    function adminSetCreatorFeeConfig(
        uint256 tokenId,
        address creator,
        address recipient,
        uint8 feeBasisPoints
    ) external onlyOwner {
        _setCreatorFeeConfig(tokenId, creator, recipient, feeBasisPoints);
        if (tokenParams[tokenId].lpDeployed) {
            dividendFeeHelper.adminSetTokenCreatorFee(
                tokenId,
                creator,
                recipient,
                uint16(feeBasisPoints) * 100
            );
        }
    }

    function _afterCreate(uint256 tokenId, uint256 amount, uint256 maxTotalCost) internal {
        if (amount > 0) {
            _buy(amount, tokenId, msg.sender, maxTotalCost, true);
            if (_isLpTokenThresholdReached(tokenId)) _createLp(tokenId);
        }
    }

    function _createToken(
        uint32 a,
        uint8 b,
        uint128 curveScaler,
        uint8 creatorFeeBasisPoints,
        uint16 dividendFeeBasisPoints,
        address tokenCreatorAddress,
        uint256 tokenSplit,
        string memory name,
        string memory symbol
    ) internal returns (uint256 tokenId) {
        require(tokenCreatorAddress != address(0), "Token creator address must be set");
        if (creatorFeeBasisPoints > MAX_CREATOR_FEE_BASIS_POINT) revert InvalidFeeSetting();
        if (dividendFeeBasisPoints > MAX_DIVIDEND_FEE_BASIS_POINT) revert InvalidFeeSetting();
        uint256 allowedSupply = allowedTotalSupplyWithParameters(a, b, curveScaler, tokenSplit);
        require(allowedSupply != 0, "There is no registered token supply");
        tokenId = tokenIdentifier;
        if (tokenId >= tokenIdRangeEnd) revert TokenIdRangeExhausted();
        tokenSupply[tokenId] = allowedSupply;

        address tokenContractAddress = tokenFactory.deployToken(name, symbol, tokenId);
        address[] memory excludedAccounts = new address[](3);
        excludedAccounts[0] = address(this);
        excludedAccounts[1] = address(arenaPoolDeployer);
        excludedAccounts[2] = LP_TOKEN_VAULT;
        dividendController.registerToken(
            tokenId, tokenContractAddress, PAIR_TOKEN, excludedAccounts
        );

        TokenParameters storage params = tokenParams[tokenId];
        params.a = a;
        params.b = b;
        params.curveScaler = curveScaler;
        params.creatorFeeBasisPoints = creatorFeeBasisPoints;
        params.dividendFeeBasisPoints = dividendFeeBasisPoints;
        params.tokenContractAddress = tokenContractAddress;
        params.pairAddress = address(0);
        params.creatorAddress = tokenCreatorAddress;
        params.creatorFeeRecipient = tokenCreatorAddress;
        params.postBondCreatorFeeRecipient = tokenCreatorAddress;
        params.postBondCreatorFeePpm = uint16(creatorFeeBasisPoints) * 100;
        params.lpPercentage = 100 - uint8(tokenSplit);
        params.salePercentage = uint8(tokenSplit);

        emit TokenCreated(tokenId, params, allowedSupply);
        ++tokenIdentifier;
    }

    function _buy(
        uint256 amount,
        uint256 tokenId,
        address user,
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
        FeeData memory feeData = getFeeData(tokenId, costs, user);
        uint256 creationFee = initialBuy ? tokenCreationBuyFeeAmount : 0;
        totalCost = feeData.totalFeeAmount + costs + creationFee;
        if (totalCost > maxTotalCost) revert SlippageExceeded();
        _collectPairToken(totalCost);
        IRobinhoodLaunchToken(tokenParams[tokenId].tokenContractAddress).mint(
            msg.sender, amount * GRANULARITY_SCALER
        );
        tokenBalanceOf[tokenId] += costs;
        _handleFeeTransfers(tokenId, feeData, creationFee);
        emit Buy(
            user,
            tokenId,
            amount,
            totalCost,
            currentSupply + amount,
            feeData.referrerAddress,
            feeData.referralFee,
            feeData.creatorFee,
            feeData.protocolFee,
            feeData.dividendFee
        );
    }

    function _collectPairToken(uint256 amount) internal {
        IERC20 pairToken = IERC20(PAIR_TOKEN);
        uint256 balanceBefore = pairToken.balanceOf(address(this));
        pairToken.safeTransferFrom(msg.sender, address(this), amount);
        unchecked {
            if (pairToken.balanceOf(address(this)) - balanceBefore != amount) {
                revert UnsupportedPairTokenTransfer();
            }
        }
    }

    function buyAndCreateLpIfPossible(
        uint256 amount,
        uint256 tokenId,
        uint256 maxTotalCost,
        uint256 deadline
    ) public nonReentrant {
        _checkDeadline(deadline);
        _buy(amount, tokenId, msg.sender, maxTotalCost, false);
        if (_isLpTokenThresholdReached(tokenId)) _createLp(tokenId);
    }

    function _sell(
        uint256 amount,
        uint256 tokenId,
        address user,
        uint256 minNetReward
    )
        internal
        whenNotPaused
        lpNotDeployed(tokenId)
        returns (uint256 netReward)
    {
        require(amount % GRANULARITY_SCALER == 0, "Amount must be a multiple of GRANULARITY_SCALER");
        amount /= GRANULARITY_SCALER;
        require(amount > 0, "amount must be greater than zero");
        (uint256 reward, uint256 currentSupply) = calculateRewardAndSupply(amount, tokenId);
        FeeData memory feeData = getFeeData(tokenId, reward, user);
        netReward = reward - feeData.totalFeeAmount;
        if (netReward < minNetReward) revert SlippageExceeded();
        IRobinhoodLaunchToken(tokenParams[tokenId].tokenContractAddress).burn(
            msg.sender, amount * GRANULARITY_SCALER
        );
        tokenBalanceOf[tokenId] -= reward;
        _handleFeeTransfers(tokenId, feeData, 0);
        IERC20(PAIR_TOKEN).safeTransfer(msg.sender, netReward);
        emit Sell(
            user,
            tokenId,
            amount,
            reward,
            currentSupply - amount,
            feeData.referrerAddress,
            feeData.referralFee,
            feeData.creatorFee,
            feeData.protocolFee,
            feeData.dividendFee
        );
    }

    function sell(uint256 amount, uint256 tokenId, uint256 minNetReward, uint256 deadline)
        public
        whenNotPaused
        nonReentrant
        lpNotDeployed(tokenId)
        returns (uint256 netReward)
    {
        _checkDeadline(deadline);
        netReward = _sell(amount, tokenId, msg.sender, minNetReward);
    }

    function buyAndCreateLpIfPossibleWithUser(
        uint256 amount,
        uint256 tokenId,
        address user,
        uint256 maxPairTokenToSpend
    ) external nonReentrant {
        require(msg.sender == NATIVE_HELPER, "Only NativeHelper can buy");
        _buy(amount, tokenId, user, maxPairTokenToSpend, false);
        if (_isLpTokenThresholdReached(tokenId)) _createLp(tokenId);
    }

    function sellWithUser(
        uint256 amount,
        uint256 tokenId,
        address user,
        uint256 minPairTokenToReceive
    ) external nonReentrant returns (uint256 amountOut) {
        require(msg.sender == NATIVE_HELPER, "Only NativeHelper can sell");
        amountOut = _sell(amount, tokenId, user, minPairTokenToReceive);
    }

    function _createLp(uint256 tokenId) internal {
        require(canDeployLp, "Lp deploy not allowed right now!");
        TokenParameters memory paramsCached = tokenParams[tokenId];
        require(!paramsCached.lpDeployed, "Lp already deployed");
        tokenParams[tokenId].lpDeployed = true;

        uint256 allowedMaxSupply = tokenSupply[tokenId];
        uint256 onePercent = allowedMaxSupply / 100;
        uint256 tokenAmount = onePercent * paramsCached.lpPercentage;
        uint256 pairAmount = tokenBalanceOf[tokenId];
        tokenBalanceOf[tokenId] = 0;
        if (paramsCached.pairAddress != address(0)) {
            IRobinhoodLaunchToken(paramsCached.tokenContractAddress).setBlacklistStatus(
                paramsCached.pairAddress, false
            );
        }

        IRobinhoodDividendController controller = dividendController;
        controller.setDividendExcluded(tokenId, address(this), true);
        controller.setDividendExcluded(tokenId, address(arenaPoolDeployer), true);
        controller.setDividendExcluded(tokenId, LP_TOKEN_VAULT, true);

        V4PoolInitParams memory poolConfig = v4PoolInitParams;
        controller.setDividendExcluded(
            tokenId, poolConfig.poolInitParams.hookContract, true
        );

        IRobinhoodLaunchToken token = IRobinhoodLaunchToken(paramsCached.tokenContractAddress);
        token.mint(address(this), tokenAmount);

        IERC20(address(token)).forceApprove(address(arenaPoolDeployer), tokenAmount);
        IERC20(PAIR_TOKEN).forceApprove(address(arenaPoolDeployer), pairAmount);

        poolConfig.poolInitParams.recipient = LP_TOKEN_VAULT;
        poolConfig.poolInitParams.hookData = abi.encode(tokenId);
        if (PAIR_TOKEN > paramsCached.tokenContractAddress) {
            poolConfig.poolInitParams.startingPrice = poolConfig.invertedStartingPrice;
            int24 tickLowerCached = poolConfig.poolInitParams.tickLower;
            poolConfig.poolInitParams.tickLower = -poolConfig.poolInitParams.tickUpper;
            poolConfig.poolInitParams.tickUpper = -tickLowerCached;
            poolConfig.poolInitParams.token0Amount = tokenAmount;
            poolConfig.poolInitParams.token1Amount = pairAmount;
            poolConfig.poolInitParams.token0 = paramsCached.tokenContractAddress;
            poolConfig.poolInitParams.token1 = PAIR_TOKEN;
        } else {
            poolConfig.poolInitParams.token0Amount = pairAmount;
            poolConfig.poolInitParams.token1Amount = tokenAmount;
            poolConfig.poolInitParams.token0 = PAIR_TOKEN;
            poolConfig.poolInitParams.token1 = paramsCached.tokenContractAddress;
        }

        IRobinhoodDividendFeeHelper.PoolFeeConfig memory feeConfig =
            IRobinhoodDividendFeeHelper.PoolFeeConfig({
                tokenId: tokenId,
                launchToken: paramsCached.tokenContractAddress,
                rewardToken: PAIR_TOKEN,
                dividendController: address(controller),
                creator: paramsCached.creatorAddress,
                creatorFeeRecipient: paramsCached.postBondCreatorFeeRecipient,
                dividendFeePpm: uint16(paramsCached.dividendFeeBasisPoints * 100),
                creatorFeePpm: paramsCached.postBondCreatorFeePpm
            });

        arenaPoolDeployer.initPoolAndSetFees(poolConfig.poolInitParams, feeConfig);
        IOwnableLaunchTokenV2(paramsCached.tokenContractAddress).renounceOwnership();
        require(token.totalSupply() == allowedMaxSupply, "total supply mismatch");
        emit TokenLPCreated(tokenId, tokenAmount, pairAmount, 0);
    }

    function getFeeData(uint256 tokenId, uint256 rawCosts, address user)
        public
        view
        returns (FeeData memory feeData)
    {
        TokenParameters memory params = tokenParams[tokenId];
        if (address(referrerRegistry) != address(0)) {
            feeData.referrerAddress = referrerRegistry.getReferrer(user);
        }
        feeData.creatorFeeRecipient = params.creatorFeeRecipient;
        feeData.protocolFee = (rawCosts * protocolFeeBasisPoint + 5000) / 10000;
        feeData.creatorFee =
            (rawCosts * params.creatorFeeBasisPoints + 5000) / 10000;
        feeData.dividendFee =
            (rawCosts * params.dividendFeeBasisPoints + 5000) / 10000;
        feeData.referralFee = (rawCosts * referralFeeBasisPoint + 5000) / 10000;
        if (feeData.referrerAddress == address(0)) {
            feeData.protocolFee += feeData.referralFee;
            feeData.referralFee = 0;
        }
        feeData.totalFeeAmount = feeData.protocolFee + feeData.creatorFee
            + feeData.referralFee + feeData.dividendFee;
    }

    function _handleFeeTransfers(
        uint256 tokenId,
        FeeData memory feeData,
        uint256 creationFee
    ) internal {
        IERC20 pairToken = IERC20(PAIR_TOKEN);
        uint256 protocolFeeAmount = feeData.protocolFee;
        if (feeData.referrerAddress != address(0) && feeData.referralFee > 0) {
            pairToken.safeTransfer(
                feeData.referrerAddress, feeData.referralFee
            );
        }
        if (feeData.creatorFeeRecipient != address(0) && feeData.creatorFee > 0) {
            pairToken.safeTransfer(
                feeData.creatorFeeRecipient, feeData.creatorFee
            );
        } else {
            protocolFeeAmount += feeData.creatorFee;
        }
        if (feeData.dividendFee > 0) {
            _depositDividendFee(tokenId, feeData.dividendFee);
        }
        if (protocolFeeAmount > 0) {
            pairToken.safeTransfer(protocolFeeDestination, protocolFeeAmount);
        }
        if (creationFee > 0) {
            pairToken.safeTransfer(tokenCreationBuyFeeVault, creationFee);
        }
    }

    function _depositDividendFee(uint256 tokenId, uint256 amount) internal {
        IERC20(PAIR_TOKEN).forceApprove(address(dividendController), amount);
        dividendController.deposit(tokenId, PAIR_TOKEN, amount);
        emit DividendFeeCollected(tokenId, amount);
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
        uint256 creatorFeeBasisPoints,
        uint256 dividendFeeBasisPoints
    ) public view returns (uint256) {
        uint256 rawCosts =
            calculateCostScaledParametric(amountInWei, supplyInWei, a, b, curveScaler);
        return rawCosts + ((rawCosts * protocolFeeBasisPoint + 5000) / 10000)
            + ((rawCosts * creatorFeeBasisPoints + 5000) / 10000)
            + ((rawCosts * dividendFeeBasisPoints + 5000) / 10000)
            + ((rawCosts * referralFeeBasisPoint + 5000) / 10000);
    }

    function calculateInitialBuyCostScaledParametricWithFees(
        uint256 amountInWei,
        uint256 supplyInWei,
        uint256 a,
        uint256 b,
        uint256 curveScaler,
        uint256 creatorFeeBasisPoints,
        uint256 dividendFeeBasisPoints
    ) external view returns (uint256) {
        if (amountInWei == 0) return 0;
        return calculateCostScaledParametricWithFees(
            amountInWei,
            supplyInWei,
            a,
            b,
            curveScaler,
            creatorFeeBasisPoints,
            dividendFeeBasisPoints
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

    function allowedTotalSupplyWithParameters(uint32 a, uint8 b, uint128 c, uint256 tokenSplit)
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
        return tokenParams[tokenId];
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

    function _setCreatorFeeConfig(
        uint256 tokenId,
        address creator,
        address recipient,
        uint8 feeBasisPoints
    ) internal {
        if (creator == address(0) || recipient == address(0)) revert InvalidFeeSetting();
        if (feeBasisPoints > MAX_CREATOR_FEE_BASIS_POINT) revert InvalidFeeSetting();
        TokenParameters storage params = tokenParams[tokenId];
        params.creatorAddress = creator;
        params.creatorFeeRecipient = recipient;
        params.postBondCreatorFeeRecipient = recipient;
        params.creatorFeeBasisPoints = feeBasisPoints;
        params.postBondCreatorFeePpm = uint16(feeBasisPoints) * 100;
        if (params.tokenContractAddress != address(0) && !params.lpDeployed) {
            IRobinhoodLaunchToken(params.tokenContractAddress).setCreator(creator);
        }
        emit CreatorFeeConfigSet(
            tokenId,
            creator,
            recipient,
            feeBasisPoints,
            params.postBondCreatorFeePpm
        );
    }

    function _setTokenFactory(address newTokenFactory) internal {
        if (newTokenFactory == address(0)) revert InvalidTokenFactory();
        address oldTokenFactory = address(tokenFactory);
        tokenFactory = IRobinhoodLaunchTokenFactory(newTokenFactory);
        emit TokenFactorySet(oldTokenFactory, newTokenFactory);
    }

    function _setDividendController(address controller) internal {
        if (controller == address(0)) revert InvalidDividendController();
        address oldController = address(dividendController);
        dividendController = IRobinhoodDividendController(controller);
        emit DividendControllerSet(oldController, controller);
    }

    function _setDividendFeeHelper(address helper) internal {
        if (helper == address(0)) revert InvalidDividendFeeHelper();
        address oldHelper = address(dividendFeeHelper);
        dividendFeeHelper = IRobinhoodDividendFeeHelper(helper);
        emit DividendFeeHelperSet(oldHelper, helper);
    }

    function _setArenaPoolDeployer(address poolDeployer) internal {
        if (poolDeployer == address(0)) revert InvalidPoolDeployer();
        address oldPoolDeployer = address(arenaPoolDeployer);
        arenaPoolDeployer = IRobinhoodDividendFeePoolDeployer(poolDeployer);
        emit ArenaPoolDeployerSet(oldPoolDeployer, poolDeployer);
    }

    function _checkDeadline(uint256 deadline) internal view {
        if (block.timestamp > deadline) revert DeadlineExpired();
    }
}
