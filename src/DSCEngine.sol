//SPDX-Licencse-Identifier: MIT
pragma solidity 0.8.20;

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

/**
 * @title DSCEngine
 * @author Lionel Djouhan
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 * This is a stablecoin with the properties:
 * - Exogenously Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of
 * all collateral < the $ backed value of all the DSC.
 *
 * @notice This contract is the core of the Decentralized Stablecoin system. It handles all the logic
 * for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS system
 */
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AggregatorV3Interface} from
    "lib/chainlink-brownie-contracts/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract DSCEngine is ReentrancyGuard {
    ///////////////
    // ERRORS    //
    ///////////////

    error DSCEngine__NeedMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAdressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactorealthFactor);
    error DSCEngine_MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    ////////////////////
    // SATE VARIABLES //
    ////////////////////

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;

    mapping(address token => address priceFeed) private s_priceFeeds; // tokenToPrcieFeed
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralTokens;
    uint256 private constant LIQUIDATION_TRESHOLD = 50; //200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    DecentralizedStableCoin private immutable i_dsc;
    uint256 private constant MIN_HEALTH_FACTOR = 1;
    uint256 private constant LIQUIDATION_BONUS = 10; // THis mean 10% bonus

    ///////////////
    // EVENTS    //
    ///////////////

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event collateralRedeemed(
        address indexed redeemFrom, address indexed redeemTo, address indexed token, uint256 amount
    );

    ///////////////
    // MODIFIERS //
    ///////////////

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    ///////////////
    // FUNCTIONS //
    ///////////////

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddress, address dscAdress) {
        //USD Price Feeds
        if (tokenAddresses.length != priceFeedAddress.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAdressesMustBeSameLength();
        }
        // For example ETH / USD, BTC / USD , MKR /USD , etc ...
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddress[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_dsc = DecentralizedStableCoin(dscAdress);
    }

    /////////////////////////
    // EXTERNAL FUNCTIONS  //
    /////////////////////////

    /**
     * @notice  follows CEI
     * @param tokenCollateralAddress, The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     * @param amountDscToMint The amount of DSC to mint
     * @notice this function will deposit collateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @notice  follows CEI
     * @param tokenCollaterlAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(address tokenCollaterlAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollaterlAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollaterlAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollaterlAddress, amountCollateral);
        bool success = IERC20(tokenCollaterlAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) revert DSCEngine__NeedMoreThanZero();
    }

    //in order to redeem collateral;
    //1.health factor must be over 1 AFTER collateral pulled
    //DRY dont repeat yourself
    //CEI: check effects interactions
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     *
     * @param tokenCollateralAddress Tthe collateral address to redeem
     * @param amountCollateral The amount of collateral to redeem
     * @param amountDscToburn The amount of DSC to burn
     * @notice this function will burn DSC and redeems underlying  collateral  in one transaction
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToburn)
        external
    {
        burnDsc(amountDscToburn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        //redeemCollateral already checks health factor
    }

    // Check if the collateral value is > DSC amount .Price feeds, value

    /**
     * @notice follows CEI
     * @param amountDscToMint  The amount of DSC to mint
     * @notice they must have more collateral value than the minimum threshold
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;

        // if they minted too much ($150 DSC, $100 ETH)
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine_MintFailed();
        }
    }
    //Do we need to check if this break health factor ?

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(msg.sender, msg.sender, amount);

        _revertIfHealthFactorIsBroken(msg.sender); // i dont think yhis would ever hit
    }

    // If we do start nearing unedercollateralization , we need someone to liquidate positions
    //100 ETH backing 50$
    //20$ back 50$ <- DSC isn't worth 1$
    // 75$ backing 50 DSC
    //lIQUIDATOR TAkE 75$ bancking and burns off the 50 DSC
    //IF SOMEONE IS ALMOST UNDERCOLLATERALIZED , we will pay you to LIQUIDATE THEM

    /**
     * @param collateral The erc20 collateral address to liquidate from user.
     * @param user  The user who has broken the health factor. Their _healthFactor should be
     * @param debtToCover The amount of DSC you want to burn to improve  the users health.
     * @notice you can Partially liquidata user.
     * @notice you will gate a liquidation bonus for taking the users funds
     * @notice THis function working assumes the protocol willsl be roughly 200%
     * Overcollaterlized in order for this work.
     * @notice A known bug would be if the protocol were 100% or less collateralized, then
     * we wouldn't be able to incentive the liquidators
     * for example , if the price of the collateral plummeted before anyone could be liquidated
     * FOllows CEI: checks, Effects, Interactions
     *
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        //NEED TO CHECK FACTOR OF THE USER

        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }

        //we want to burn their DSC"debt"
        //and take their collateral
        //Bad Ueser:$140 eth, $100 DSC
        //debtToCover = $100
        //$100 of DSC == ??? ETH?
        //0.05 ETH
        uint256 tokenAMountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        //GIVE THEM A 10 % Bonus
        //so we are giving te liquidator $110 of WETH for 100DSC
        // We should implement a feature to liquidate  in the event the protocol is insolvent
        //and sweep extra amounts into treasury
        //0.05 *0.1 = 0.005  Getting 0.055
        uint256 bonusCollateral = (tokenAMountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAMountFromDebtCovered + bonusCollateral;

        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        _burnDsc(user, msg.sender, debtToCover);
        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external {}

    ////////////////////////////////////////
    // PRIVATE & INTERNAL  VIEW FUNCTIONS //
    ////////////////////////////////////////

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit collateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) revert DSCEngine__TransferFailed();
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     *
     * Returns how close to liquidation  a user is
     * If a user goes below 1, then can get liquidated
     */
    function _healthFactor(address user) private view returns (uint256) {
        // total DSC minted
        // total collateral VALUE

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedFoThreshold = (collateralValueInUsd * LIQUIDATION_TRESHOLD) / LIQUIDATION_PRECISION; //100/100
        return (collateralAdjustedFoThreshold * LIQUIDATION_PRECISION / totalDscMinted);
        //100ETH * 50  = 50000 /100 = 500
        //150ETH / 100 DSC = 150 / 100 = 1.5

        //$1000 ETH / 100 DSC
        //1000 * 50  = 50000 / 100 = (500/100) = 5 > 1
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        //1. Check health factor (do they have enough collateral?)
        //2  Revert if they don't have enough collateral

        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    ///////////////////////////////////////
    // PUBLIC & EXTERNAL VIEW FUNCTIONS //
    ///////////////////////////////////////

    /**
     *
     * @dev low-level internal function, do not call unless the function calling it is
     * cheking for health factor being broken
     */
    function _burnDsc(address onBehalfOf, address dscFrom, uint256 amountDscToBurn) public nonReentrant {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        //this condition id hypothtically reachable
        if (!success) revert DSCEngine__TransferFailed();
        i_dsc.burn(amountDscToBurn);
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        //price of ETH (token)
        // $/ETH ETH ??
        //$2000 / ETH. $1000 = 0.5 eth
        AggregatorV3Interface priceFreed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFreed.latestRoundData(); //($10e18 * 1e18) / ($2000e8 * 1e10)
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // Loop through each collateral token, get the amount they have deposited, and map it to
        // the price, to get the USD Value

        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFreed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFreed.latestRoundData();
        //1 ETH = $ 10000
        // The returned value from CL will be 1000 * 1e8

        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }
}
