// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title TokenStaking
 * @dev A staking contract that allows users to stake tokens and earn rewards
 * Features time-locked staking with different reward rates
 */
contract TokenStaking {
    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardToken;
    
    address public owner;
    
    // Staking pools with different lock periods and reward rates
    struct StakingPool {
        uint256 lockPeriod;      // Lock period in seconds
        uint256 rewardRate;      // Annual reward rate (basis points, e.g., 1200 = 12%)
        uint256 totalStaked;     // Total tokens staked in this pool
        bool active;             // Whether this pool is active
    }
    
    struct UserStake {
        uint256 amount;          // Amount staked
        uint256 rewardDebt;      // Reward debt for accurate reward calculation
        uint256 stakeTime;       // When the stake was made
        uint256 poolId;          // Which pool this stake belongs to
        uint256 lastClaimTime;   // Last time rewards were claimed
    }
    
    mapping(uint256 => StakingPool) public stakingPools;
    mapping(address => mapping(uint256 => UserStake)) public userStakes; // user => stakeId => UserStake
    mapping(address => uint256) public userStakeCount;
    mapping(address => uint256) public totalUserStaked;
    
    uint256 public poolCount;
    uint256 public totalRewardsDistributed;
    uint256 public rewardPerSecond;
    
    // Constants
    uint256 private constant BASIS_POINTS = 10000;
    uint256 private constant SECONDS_IN_YEAR = 31536000; // 365 * 24 * 60 * 60
    
    event PoolCreated(uint256 indexed poolId, uint256 lockPeriod, uint256 rewardRate);
    event Staked(address indexed user, uint256 indexed poolId, uint256 indexed stakeId, uint256 amount);
    event Unstaked(address indexed user, uint256 indexed poolId, uint256 indexed stakeId, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 indexed stakeId, uint256 amount);
    event RewardsDeposited(uint256 amount);
    
    modifier onlyOwner() {
        require(msg.sender == owner, "Not the owner");
        _;
    }
    
    constructor(address _stakingToken, address _rewardToken) {
        stakingToken = IERC20(_stakingToken);
        rewardToken = IERC20(_rewardToken);
        owner = msg.sender;
        
        // Create default pools
        _createPool(0, 800);          // No lock, 8% APY
        _createPool(30 days, 1200);   // 30 days lock, 12% APY
        _createPool(90 days, 1800);   // 90 days lock, 18% APY
        _createPool(180 days, 2500);  // 180 days lock, 25% APY
    }
    
    /**
     * @dev Create a new staking pool
     * @param lockPeriod Lock period in seconds
     * @param rewardRate Annual reward rate in basis points (e.g., 1200 = 12%)
     */
    function createPool(uint256 lockPeriod, uint256 rewardRate) external onlyOwner {
        _createPool(lockPeriod, rewardRate);
    }
    
    function _createPool(uint256 lockPeriod, uint256 rewardRate) private {
        require(rewardRate <= 10000, "Reward rate cannot exceed 100%");
        
        stakingPools[poolCount] = StakingPool({
            lockPeriod: lockPeriod,
            rewardRate: rewardRate,
            totalStaked: 0,
            active: true
        });
        
        emit PoolCreated(poolCount, lockPeriod, rewardRate);
        poolCount++;
    }
    
    /**
     * @dev Stake tokens in a specific pool
     * @param poolId The pool to stake in
     * @param amount Amount of tokens to stake
     */
    function stake(uint256 poolId, uint256 amount) external {
        require(poolId < poolCount, "Pool does not exist");
        require(stakingPools[poolId].active, "Pool is not active");
        require(amount > 0, "Amount must be greater than 0");
        
        StakingPool storage pool = stakingPools[poolId];
        uint256 stakeId = userStakeCount[msg.sender];
        
        // Transfer tokens from user
        require(stakingToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        
        // Create user stake
        userStakes[msg.sender][stakeId] = UserStake({
            amount: amount,
            rewardDebt: 0,
            stakeTime: block.timestamp,
            poolId: poolId,
            lastClaimTime: block.timestamp
        });
        
        // Update counters
        userStakeCount[msg.sender]++;
        totalUserStaked[msg.sender] += amount;
        pool.totalStaked += amount;
        
        emit Staked(msg.sender, poolId, stakeId, amount);
    }
    
    /**
     * @dev Unstake tokens from a specific stake
     * @param stakeId The stake ID to unstake from
     */
    function unstake(uint256 stakeId) external {
        require(stakeId < userStakeCount[msg.sender], "Stake does not exist");
        
        UserStake storage userStake = userStakes[msg.sender][stakeId];
        require(userStake.amount > 0, "No tokens staked");
        
        StakingPool storage pool = stakingPools[userStake.poolId];
        
        // Check if lock period has passed
        require(
            block.timestamp >= userStake.stakeTime + pool.lockPeriod,
            "Tokens are still locked"
        );
        
        // Calculate and transfer pending rewards
        uint256 pendingReward = calculateReward(msg.sender, stakeId);
        if (pendingReward > 0) {
            require(rewardToken.transfer(msg.sender, pendingReward), "Reward transfer failed");
            totalRewardsDistributed += pendingReward;
            emit RewardsClaimed(msg.sender, stakeId, pendingReward);
        }
        
        // Transfer staked tokens back to user
        uint256 amount = userStake.amount;
        require(stakingToken.transfer(msg.sender, amount), "Transfer failed");
        
        // Update state
        pool.totalStaked -= amount;
        totalUserStaked[msg.sender] -= amount;
        
        // Reset stake
        userStake.amount = 0;
        userStake.rewardDebt = 0;
        
        emit Unstaked(msg.sender, userStake.poolId, stakeId, amount);
    }
    
    /**
     * @dev Claim pending rewards for a specific stake
     * @param stakeId The stake ID to claim rewards for
     */
    function claimRewards(uint256 stakeId) external {
        require(stakeId < userStakeCount[msg.sender], "Stake does not exist");
        
        UserStake storage userStake = userStakes[msg.sender][stakeId];
        require(userStake.amount > 0, "No tokens staked");
        
        uint256 pendingReward = calculateReward(msg.sender, stakeId);
        require(pendingReward > 0, "No rewards to claim");
        
        // Update last claim time
        userStake.lastClaimTime = block.timestamp;
        
        // Transfer rewards
        require(rewardToken.transfer(msg.sender, pendingReward), "Reward transfer failed");
        totalRewardsDistributed += pendingReward;
        
        emit RewardsClaimed(msg.sender, stakeId, pendingReward);
    }
    
    /**
     * @dev Calculate pending rewards for a user's stake
     * @param user The user address
     * @param stakeId The stake ID
     * @return reward Pending reward amount
     */
    function calculateReward(address user, uint256 stakeId) public view returns (uint256 reward) {
        if (stakeId >= userStakeCount[user]) return 0;
        
        UserStake storage userStake = userStakes[user][stakeId];
        if (userStake.amount == 0) return 0;
        
        StakingPool storage pool = stakingPools[userStake.poolId];
        
        uint256 stakingDuration = block.timestamp - userStake.lastClaimTime;
        uint256 annualReward = (userStake.amount * pool.rewardRate) / BASIS_POINTS;
        reward = (annualReward * stakingDuration) / SECONDS_IN_YEAR;
    }
    
    /**
     * @dev Get user's total pending rewards across all stakes
     * @param user The user address
     * @return totalRewards Total pending rewards
     */
    function getTotalPendingRewards(address user) external view returns (uint256 totalRewards) {
        for (uint256 i = 0; i < userStakeCount[user]; i++) {
            totalRewards += calculateReward(user, i);
        }
    }
    
    /**
     * @dev Get user's stake information
     * @param user The user address
     * @param stakeId The stake ID
     */
    function getUserStake(address user, uint256 stakeId) 
        external 
        view 
        returns (
            uint256 amount,
            uint256 poolId,
            uint256 stakeTime,
            uint256 lastClaimTime,
            uint256 unlockTime,
            uint256 pendingReward
        ) 
    {
        if (stakeId >= userStakeCount[user]) {
            return (0, 0, 0, 0, 0, 0);
        }
        
        UserStake storage userStake = userStakes[user][stakeId];
        StakingPool storage pool = stakingPools[userStake.poolId];
        
        amount = userStake.amount;
        poolId = userStake.poolId;
        stakeTime = userStake.stakeTime;
        lastClaimTime = userStake.lastClaimTime;
        unlockTime = userStake.stakeTime + pool.lockPeriod;
        pendingReward = calculateReward(user, stakeId);
    }
    
    /**
     * @dev Get pool information
     * @param poolId The pool ID
     */
    function getPoolInfo(uint256 poolId) 
        external 
        view 
        returns (
            uint256 lockPeriod,
            uint256 rewardRate,
            uint256 totalStaked,
            bool active
        ) 
    {
        require(poolId < poolCount, "Pool does not exist");
        StakingPool storage pool = stakingPools[poolId];
        
        lockPeriod = pool.lockPeriod;
        rewardRate = pool.rewardRate;
        totalStaked = pool.totalStaked;
        active = pool.active;
    }
    
    /**
     * @dev Toggle pool active status (only owner)
     * @param poolId The pool ID to toggle
     */
    function togglePool(uint256 poolId) external onlyOwner {
        require(poolId < poolCount, "Pool does not exist");
        stakingPools[poolId].active = !stakingPools[poolId].active;
    }
    
    /**
     * @dev Deposit reward tokens to the contract (only owner)
     * @param amount Amount of reward tokens to deposit
     */
    function depositRewards(uint256 amount) external onlyOwner {
        require(rewardToken.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        emit RewardsDeposited(amount);
    }
    
    /**
     * @dev Emergency withdraw function (only owner)
     * @param token The token to withdraw
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        IERC20(token).transfer(owner, amount);
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
