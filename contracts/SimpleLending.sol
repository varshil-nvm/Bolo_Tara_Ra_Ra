// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface IPriceOracle {
    function getPrice(address token) external view returns (uint256);
}

/**
 * @title SimpleLending
 * @dev A basic lending protocol with collateral management
 * Users can deposit collateral and borrow against it
 */
contract SimpleLending {
    struct Market {
        IERC20 token;
        uint256 totalDeposits;
        uint256 totalBorrows;
        uint256 collateralFactor; // Basis points (e.g., 7500 = 75%)
        uint256 borrowRate;       // Annual borrow rate in basis points
        uint256 supplyRate;       // Annual supply rate in basis points
        bool active;
    }
    
    struct UserAccount {
        mapping(address => uint256) deposits;     // token => amount deposited
        mapping(address => uint256) borrows;      // token => amount borrowed
        uint256 totalCollateralValue;            // USD value of collateral (scaled by 1e18)
        uint256 totalBorrowValue;                // USD value of borrows (scaled by 1e18)
    }
    
    mapping(address => Market) public markets;
    mapping(address => UserAccount) private userAccounts;
    mapping(address => bool) public supportedTokens;
    
    address[] public tokenList;
    address public owner;
    address public priceOracle;
    
    // Constants
    uint256 private constant BASIS_POINTS = 10000;
    uint256 private constant LIQUIDATION_THRESHOLD = 8500; // 85% - when liquidation can occur
    uint256 private constant LIQUIDATION_BONUS = 500;     // 5% bonus for liquidators
    uint256 private constant PRICE_SCALE = 1e18;
    
    event MarketListed(address indexed token, uint256 collateralFactor);
    event Deposit(address indexed user, address indexed token, uint256 amount);
    event Withdraw(address indexed user, address indexed token, uint256 amount);
    event Borrow(address indexed user, address indexed token, uint256 amount);
    event Repay(address indexed user, address indexed token, uint256 amount);
    event Liquidation(
        address indexed liquidator,
        address indexed borrower,
        address indexed collateralToken,
        address borrowToken,
        uint256 repayAmount,
        uint256 seizeAmount
    );
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Not the owner");
        _;
    }
    
    modifier marketExists(address token) {
        require(supportedTokens[token], "Market does not exist");
        _;
    }
    
    constructor() {
        owner = msg.sender;
    }
    
    /**
     * @dev List a new token market
     * @param token The token to list
     * @param collateralFactor Collateral factor in basis points (e.g., 7500 = 75%)
     * @param borrowRate Annual borrow rate in basis points
     * @param supplyRate Annual supply rate in basis points
     */
    function listMarket(
        address token,
        uint256 collateralFactor,
        uint256 borrowRate,
        uint256 supplyRate
    ) external onlyOwner {
        require(!supportedTokens[token], "Market already exists");
        require(collateralFactor <= BASIS_POINTS, "Invalid collateral factor");
        require(borrowRate <= 5000, "Borrow rate too high"); // Max 50% APY
        
        markets[token] = Market({
            token: IERC20(token),
            totalDeposits: 0,
            totalBorrows: 0,
            collateralFactor: collateralFactor,
            borrowRate: borrowRate,
            supplyRate: supplyRate,
            active: true
        });
        
        supportedTokens[token] = true;
        tokenList.push(token);
        
        emit MarketListed(token, collateralFactor);
    }
    
    /**
     * @dev Deposit tokens as collateral
     * @param token The token to deposit
     * @param amount Amount to deposit
     */
    function deposit(address token, uint256 amount) external marketExists(token) {
        require(amount > 0, "Amount must be greater than 0");
        require(markets[token].active, "Market is not active");
        
        Market storage market = markets[token];
        UserAccount storage account = userAccounts[msg.sender];
        
        // Transfer tokens from user
        require(market.token.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        
        // Update user deposits
        account.deposits[token] += amount;
        market.totalDeposits += amount;
        
        // Update collateral value
        _updateAccountValues(msg.sender);
        
        emit Deposit(msg.sender, token, amount);
    }
    
    /**
     * @dev Withdraw deposited tokens
     * @param token The token to withdraw
     * @param amount Amount to withdraw
     */
    function withdraw(address token, uint256 amount) external marketExists(token) {
        require(amount > 0, "Amount must be greater than 0");
        
        Market storage market = markets[token];
        UserAccount storage account = userAccounts[msg.sender];
        
        require(account.deposits[token] >= amount, "Insufficient deposits");
        
        // Update state first
        account.deposits[token] -= amount;
        market.totalDeposits -= amount;
        
        // Update account values
        _updateAccountValues(msg.sender);
        
        // Check if withdrawal maintains health factor
        require(_isAccountHealthy(msg.sender), "Withdrawal would make account unhealthy");
        
        // Transfer tokens to user
        require(market.token.transfer(msg.sender, amount), "Transfer failed");
        
        emit Withdraw(msg.sender, token, amount);
    }
    
    /**
     * @dev Borrow tokens against collateral
     * @param token The token to borrow
     * @param amount Amount to borrow
     */
    function borrow(address token, uint256 amount) external marketExists(token) {
        require(amount > 0, "Amount must be greater than 0");
        require(markets[token].active, "Market is not active");
        
        Market storage market = markets[token];
        UserAccount storage account = userAccounts[msg.sender];
        
        // Check if there's enough liquidity
        uint256 availableLiquidity = market.token.balanceOf(address(this)) - market.totalDeposits + market.totalBorrows;
        require(amount <= availableLiquidity, "Insufficient liquidity");
        
        // Update borrow state
        account.borrows[token] += amount;
        market.totalBorrows += amount;
        
        // Update account values
        _updateAccountValues(msg.sender);
        
        // Check if borrow maintains health factor
        require(_isAccountHealthy(msg.sender), "Insufficient collateral for borrow");
        
        // Transfer tokens to user
        require(market.token.transfer(msg.sender, amount), "Transfer failed");
        
        emit Borrow(msg.sender, token, amount);
    }
    
    /**
     * @dev Repay borrowed tokens
     * @param token The token to repay
     * @param amount Amount to repay
     */
    function repay(address token, uint256 amount) external marketExists(token) {
        require(amount > 0, "Amount must be greater than 0");
        
        Market storage market = markets[token];
        UserAccount storage account = userAccounts[msg.sender];
        
        uint256 borrowBalance = account.borrows[token];
        uint256 repayAmount = amount > borrowBalance ? borrowBalance : amount;
        
        require(repayAmount > 0, "No debt to repay");
        
        // Transfer tokens from user
        require(market.token.transferFrom(msg.sender, address(this), repayAmount), "Transfer failed");
        
        // Update state
        account.borrows[token] -= repayAmount;
        market.totalBorrows -= repayAmount;
        
        // Update account values
        _updateAccountValues(msg.sender);
        
        emit Repay(msg.sender, token, repayAmount);
    }
    
    /**
     * @dev Liquidate an unhealthy account
     * @param borrower The account to liquidate
     * @param borrowToken The token being repaid
     * @param collateralToken The collateral token to seize
     * @param repayAmount Amount of borrow token to repay
     */
    function liquidate(
        address borrower,
        address borrowToken,
        address collateralToken,
        uint256 repayAmount
    ) external marketExists(borrowToken) marketExists(collateralToken) {
        require(borrower != msg.sender, "Cannot liquidate yourself");
        require(!_isAccountHealthy(borrower), "Account is healthy");
        
        UserAccount storage borrowerAccount = userAccounts[borrower];
        require(borrowerAccount.borrows[borrowToken] >= repayAmount, "Repay amount too high");
        
        // Calculate collateral to seize (with liquidation bonus)
        uint256 borrowValue = _getTokenValue(borrowToken, repayAmount);
        uint256 seizeValue = borrowValue * (BASIS_POINTS + LIQUIDATION_BONUS) / BASIS_POINTS;
        uint256 seizeAmount = _getTokenAmount(collateralToken, seizeValue);
        
        require(borrowerAccount.deposits[collateralToken] >= seizeAmount, "Insufficient collateral");
        
        // Transfer repay amount from liquidator
        require(markets[borrowToken].token.transferFrom(msg.sender, address(this), repayAmount), "Repay transfer failed");
        
        // Update borrower's debt
        borrowerAccount.borrows[borrowToken] -= repayAmount;
        markets[borrowToken].totalBorrows -= repayAmount;
        
        // Transfer collateral to liquidator
        borrowerAccount.deposits[collateralToken] -= seizeAmount;
        markets[collateralToken].totalDeposits -= seizeAmount;
        require(markets[collateralToken].token.transfer(msg.sender, seizeAmount), "Collateral transfer failed");
        
        // Update account values
        _updateAccountValues(borrower);
        
        emit Liquidation(msg.sender, borrower, collateralToken, borrowToken, repayAmount, seizeAmount);
    }
    
    /**
     * @dev Get user's account information
     * @param user The user address
     * @return totalCollateral Total collateral value in USD
     * @return totalBorrow Total borrow value in USD
     * @return healthFactor Health factor (1e18 = 100%)
     */
    function getAccountInfo(address user) 
        external 
        view 
        returns (uint256 totalCollateral, uint256 totalBorrow, uint256 healthFactor) 
    {
        UserAccount storage account = userAccounts[user];
        totalCollateral = account.totalCollateralValue;
        totalBorrow = account.totalBorrowValue;
        
        if (totalBorrow == 0) {
            healthFactor = type(uint256).max; // Infinite health factor
        } else {
            healthFactor = (totalCollateral * PRICE_SCALE) / totalBorrow;
        }
    }
    
    /**
     * @dev Get user's balance for a specific token
     * @param user The user address
     * @param token The token address
     * @return deposits Amount deposited
     * @return borrows Amount borrowed
     */
    function getUserBalance(address user, address token) 
        external 
        view 
        returns (uint256 deposits, uint256 borrows) 
    {
        UserAccount storage account = userAccounts[user];
        deposits = account.deposits[token];
        borrows = account.borrows[token];
    }
    
    /**
     * @dev Set price oracle (only owner)
     * @param _priceOracle The price oracle address
     */
    function setPriceOracle(address _priceOracle) external onlyOwner {
        priceOracle = _priceOracle;
    }
    
    /**
     * @dev Update market parameters (only owner)
     * @param token The token market to update
     * @param collateralFactor New collateral factor
     * @param borrowRate New borrow rate
     * @param supplyRate New supply rate
     */
    function updateMarket(
        address token,
        uint256 collateralFactor,
        uint256 borrowRate,
        uint256 supplyRate
    ) external onlyOwner marketExists(token) {
        require(collateralFactor <= BASIS_POINTS, "Invalid collateral factor");
        require(borrowRate <= 5000, "Borrow rate too high");
        
        Market storage market = markets[token];
        market.collateralFactor = collateralFactor;
        market.borrowRate = borrowRate;
        market.supplyRate = supplyRate;
    }
    
    /**
     * @dev Toggle market active status (only owner)
     */
    function toggleMarket(address token) external onlyOwner marketExists(token) {
        markets[token].active = !markets[token].active;
    }
    
    /**
     * @dev Update account collateral and borrow values
     */
    function _updateAccountValues(address user) private {
        UserAccount storage account = userAccounts[user];
        
        uint256 totalCollateralValue = 0;
        uint256 totalBorrowValue = 0;
        
        // Calculate total collateral value (with collateral factors)
        for (uint256 i = 0; i < tokenList.length; i++) {
            address token = tokenList[i];
            Market storage market = markets[token];
            
            if (account.deposits[token] > 0) {
                uint256 depositValue = _getTokenValue(token, account.deposits[token]);
                uint256 collateralValue = (depositValue * market.collateralFactor) / BASIS_POINTS;
                totalCollateralValue += collateralValue;
            }
            
            if (account.borrows[token] > 0) {
                uint256 borrowValue = _getTokenValue(token, account.borrows[token]);
                totalBorrowValue += borrowValue;
            }
        }
        
        account.totalCollateralValue = totalCollateralValue;
        account.totalBorrowValue = totalBorrowValue;
    }
    
    /**
     * @dev Check if an account is healthy (collateral > borrows)
     */
    function _isAccountHealthy(address user) private view returns (bool) {
        UserAccount storage account = userAccounts[user];
        
        if (account.totalBorrowValue == 0) return true;
        
        uint256 healthFactor = (account.totalCollateralValue * PRICE_SCALE) / account.totalBorrowValue;
        return healthFactor >= (LIQUIDATION_THRESHOLD * PRICE_SCALE) / BASIS_POINTS;
    }
    
    /**
     * @dev Get USD value of a token amount
     * @param token The token address
     * @param amount The token amount
     * @return value USD value (scaled by 1e18)
     */
    function _getTokenValue(address token, uint256 amount) private view returns (uint256 value) {
        if (priceOracle == address(0)) {
            // Fallback: assume all tokens worth $1 for testing
            return amount;
        }
        
        uint256 price = IPriceOracle(priceOracle).getPrice(token);
        uint8 decimals = IERC20(token).decimals();
        value = (amount * price) / (10 ** decimals);
    }
    
    /**
     * @dev Get token amount from USD value
     * @param token The token address
     * @param value USD value (scaled by 1e18)
     * @return amount Token amount
     */
    function _getTokenAmount(address token, uint256 value) private view returns (uint256 amount) {
        if (priceOracle == address(0)) {
            // Fallback: assume all tokens worth $1 for testing
            return value;
        }
        
        uint256 price = IPriceOracle(priceOracle).getPrice(token);
        uint8 decimals = IERC20(token).decimals();
        amount = (value * (10 ** decimals)) / price;
    }
    
    /**
     * @dev Get market utilization rate
     * @param token The token market
     * @return utilization Utilization rate (scaled by 1e18)
     */
    function getUtilizationRate(address token) external view marketExists(token) returns (uint256 utilization) {
        Market storage market = markets[token];
        if (market.totalDeposits == 0) return 0;
        utilization = (market.totalBorrows * PRICE_SCALE) / market.totalDeposits;
    }
    
    /**
     * @dev Get available liquidity for borrowing
     * @param token The token market
     * @return available Available amount to borrow
     */
    function getAvailableLiquidity(address token) external view marketExists(token) returns (uint256 available) {
        Market storage market = markets[token];
        uint256 totalBalance = market.token.balanceOf(address(this));
        
        if (totalBalance > market.totalBorrows) {
            available = totalBalance - market.totalBorrows;
        } else {
            available = 0;
        }
    }
    
    /**
     * @dev Get maximum borrowable amount for a user
     * @param user The user address
     * @param token The token to borrow
     * @return maxBorrow Maximum borrowable amount
     */
    function getMaxBorrowAmount(address user, address token) 
        external 
        view 
        marketExists(token) 
        returns (uint256 maxBorrow) 
    {
        UserAccount storage account = userAccounts[user];
        
        if (account.totalCollateralValue == 0) return 0;
        
        uint256 maxBorrowValue = (account.totalCollateralValue * LIQUIDATION_THRESHOLD) / BASIS_POINTS;
        uint256 availableBorrowValue = maxBorrowValue > account.totalBorrowValue ? 
            maxBorrowValue - account.totalBorrowValue : 0;
            
        maxBorrow = _getTokenAmount(token, availableBorrowValue);
        
        // Also check available liquidity
        uint256 availableLiquidity = this.getAvailableLiquidity(token);
        if (maxBorrow > availableLiquidity) {
            maxBorrow = availableLiquidity;
        }
    }
    
    /**
     * @dev Emergency pause/unpause (only owner)
     * @param token The token market to pause/unpause
     */
    function toggleMarketActive(address token) external onlyOwner marketExists(token) {
        markets[token].active = !markets[token].active;
    }
    
    /**
     * @dev Transfer ownership (only owner)
     * @param newOwner The new owner address
     */
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "New owner cannot be zero address");
        owner = newOwner;
    }
}
