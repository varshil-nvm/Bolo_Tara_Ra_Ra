// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

/**
 * @title SimpleDEX
 * @dev A simple Automated Market Maker (AMM) DEX implementation
 * Supports token swapping and liquidity provision
 */
contract SimpleDEX {
    IERC20 public immutable tokenA;
    IERC20 public immutable tokenB;
    
    uint256 public reserveA;
    uint256 public reserveB;
    uint256 public totalLiquidity;
    
    mapping(address => uint256) public liquidity;
    
    uint256 private constant FEE_PERCENT = 3; // 0.3% fee
    uint256 private constant FEE_DENOMINATOR = 1000;
    
    event LiquidityAdded(address indexed provider, uint256 amountA, uint256 amountB, uint256 liquidityMinted);
    event LiquidityRemoved(address indexed provider, uint256 amountA, uint256 amountB, uint256 liquidityBurned);
    event Swap(address indexed user, address indexed tokenIn, uint256 amountIn, uint256 amountOut);
    
    constructor(address _tokenA, address _tokenB) {
        tokenA = IERC20(_tokenA);
        tokenB = IERC20(_tokenB);
    }
    
    /**
     * @dev Add liquidity to the pool
     * @param amountA Amount of token A to add
     * @param amountB Amount of token B to add
     */
    function addLiquidity(uint256 amountA, uint256 amountB) external returns (uint256 liquidityMinted) {
        require(amountA > 0 && amountB > 0, "Amounts must be greater than 0");
        
        // Transfer tokens from user
        require(tokenA.transferFrom(msg.sender, address(this), amountA), "Transfer A failed");
        require(tokenB.transferFrom(msg.sender, address(this), amountB), "Transfer B failed");
        
        if (totalLiquidity == 0) {
            // First liquidity provision
            liquidityMinted = sqrt(amountA * amountB);
            require(liquidityMinted > 0, "Invalid initial liquidity");
        } else {
            // Subsequent liquidity provision - maintain ratio
            uint256 liquidityA = (amountA * totalLiquidity) / reserveA;
            uint256 liquidityB = (amountB * totalLiquidity) / reserveB;
            liquidityMinted = liquidityA < liquidityB ? liquidityA : liquidityB;
        }
        
        liquidity[msg.sender] += liquidityMinted;
        totalLiquidity += liquidityMinted;
        
        // Update reserves
        reserveA += amountA;
        reserveB += amountB;
        
        emit LiquidityAdded(msg.sender, amountA, amountB, liquidityMinted);
    }
    
    /**
     * @dev Remove liquidity from the pool
     * @param liquidityAmount Amount of liquidity tokens to burn
     */
    function removeLiquidity(uint256 liquidityAmount) external returns (uint256 amountA, uint256 amountB) {
        require(liquidityAmount > 0, "Liquidity amount must be greater than 0");
        require(liquidity[msg.sender] >= liquidityAmount, "Insufficient liquidity");
        
        // Calculate amounts to return
        amountA = (liquidityAmount * reserveA) / totalLiquidity;
        amountB = (liquidityAmount * reserveB) / totalLiquidity;
        
        require(amountA > 0 && amountB > 0, "Insufficient liquidity amounts");
        
        // Update state
        liquidity[msg.sender] -= liquidityAmount;
        totalLiquidity -= liquidityAmount;
        reserveA -= amountA;
        reserveB -= amountB;
        
        // Transfer tokens back to user
        require(tokenA.transfer(msg.sender, amountA), "Transfer A failed");
        require(tokenB.transfer(msg.sender, amountB), "Transfer B failed");
        
        emit LiquidityRemoved(msg.sender, amountA, amountB, liquidityAmount);
    }
    
    /**
     * @dev Swap tokenA for tokenB
     * @param amountAIn Amount of token A to swap
     * @param minAmountBOut Minimum amount of token B expected (slippage protection)
     */
    function swapAForB(uint256 amountAIn, uint256 minAmountBOut) external returns (uint256 amountBOut) {
        require(amountAIn > 0, "Amount must be greater than 0");
        require(reserveA > 0 && reserveB > 0, "No liquidity");
        
        // Calculate output amount with fee
        uint256 amountAInWithFee = amountAIn * (FEE_DENOMINATOR - FEE_PERCENT);
        amountBOut = (amountAInWithFee * reserveB) / (reserveA * FEE_DENOMINATOR + amountAInWithFee);
        
        require(amountBOut >= minAmountBOut, "Slippage too high");
        require(amountBOut < reserveB, "Insufficient liquidity");
        
        // Transfer tokens
        require(tokenA.transferFrom(msg.sender, address(this), amountAIn), "Transfer A failed");
        require(tokenB.transfer(msg.sender, amountBOut), "Transfer B failed");
        
        // Update reserves
        reserveA += amountAIn;
        reserveB -= amountBOut;
        
        emit Swap(msg.sender, address(tokenA), amountAIn, amountBOut);
    }
    
    /**
     * @dev Swap tokenB for tokenA
     * @param amountBIn Amount of token B to swap
     * @param minAmountAOut Minimum amount of token A expected (slippage protection)
     */
    function swapBForA(uint256 amountBIn, uint256 minAmountAOut) external returns (uint256 amountAOut) {
        require(amountBIn > 0, "Amount must be greater than 0");
        require(reserveA > 0 && reserveB > 0, "No liquidity");
        
        // Calculate output amount with fee
        uint256 amountBInWithFee = amountBIn * (FEE_DENOMINATOR - FEE_PERCENT);
        amountAOut = (amountBInWithFee * reserveA) / (reserveB * FEE_DENOMINATOR + amountBInWithFee);
        
        require(amountAOut >= minAmountAOut, "Slippage too high");
        require(amountAOut < reserveA, "Insufficient liquidity");
        
        // Transfer tokens
        require(tokenB.transferFrom(msg.sender, address(this), amountBIn), "Transfer B failed");
        require(tokenA.transfer(msg.sender, amountAOut), "Transfer A failed");
        
        // Update reserves
        reserveB += amountBIn;
        reserveA -= amountAOut;
        
        emit Swap(msg.sender, address(tokenB), amountBIn, amountAOut);
    }
    
    /**
     * @dev Get swap quote for tokenA to tokenB
     * @param amountAIn Amount of token A to swap
     * @return amountBOut Expected amount of token B out
     */
    function getSwapQuoteAForB(uint256 amountAIn) external view returns (uint256 amountBOut) {
        require(amountAIn > 0, "Amount must be greater than 0");
        require(reserveA > 0 && reserveB > 0, "No liquidity");
        
        uint256 amountAInWithFee = amountAIn * (FEE_DENOMINATOR - FEE_PERCENT);
        amountBOut = (amountAInWithFee * reserveB) / (reserveA * FEE_DENOMINATOR + amountAInWithFee);
    }
    
    /**
     * @dev Get swap quote for tokenB to tokenA
     * @param amountBIn Amount of token B to swap
     * @return amountAOut Expected amount of token A out
     */
    function getSwapQuoteBForA(uint256 amountBIn) external view returns (uint256 amountAOut) {
        require(amountBIn > 0, "Amount must be greater than 0");
        require(reserveA > 0 && reserveB > 0, "No liquidity");
        
        uint256 amountBInWithFee = amountBIn * (FEE_DENOMINATOR - FEE_PERCENT);
        amountAOut = (amountBInWithFee * reserveA) / (reserveB * FEE_DENOMINATOR + amountBInWithFee);
    }
    
    /**
     * @dev Get current pool ratio
     * @return price Price of token A in terms of token B (scaled by 1e18)
     */
    function getPrice() external view returns (uint256 price) {
        require(reserveA > 0, "No liquidity");
        price = (reserveB * 1e18) / reserveA;
    }
    
    /**
     * @dev Simple square root implementation for initial liquidity calculation
     */
    function sqrt(uint256 x) private pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }
    
    /**
     * @dev Get reserves
     * @return _reserveA Current reserve of token A
     * @return _reserveB Current reserve of token B
     */
    function getReserves() external view returns (uint256 _reserveA, uint256 _reserveB) {
        _reserveA = reserveA;
        _reserveB = reserveB;
    }
}
