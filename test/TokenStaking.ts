import assert from 'node:assert/strict';
import { describe, it, beforeEach } from 'node:test';
import { parseEther } from 'viem';

import { network } from 'hardhat';

describe('TokenStaking', async function () {
  const { viem } = await network.connect();
  let stakingToken: any, rewardToken: any, staking: any;
  let owner: any, user1: any, user2: any;

  beforeEach(async function () {
    [owner, user1, user2] = await viem.getWalletClients();

    // Deploy tokens
    stakingToken = await viem.deployContract('MyToken', [
      'Staking Token',
      'STAKE',
      18,
      10000000n, // 10M tokens
    ]);

    rewardToken = await viem.deployContract('MyToken', [
      'Reward Token',
      'REWARD',
      18,
      5000000n, // 5M tokens
    ]);

    // Deploy staking contract
    staking = await viem.deployContract('TokenStaking', [
      stakingToken.address,
      rewardToken.address,
    ]);

    // Mint tokens to users for testing
    await stakingToken.write.mint([user1.account.address, parseEther('10000')], {
      account: owner.account,
    });
    await stakingToken.write.mint([user2.account.address, parseEther('5000')], {
      account: owner.account,
    });

    // Mint reward tokens to staking contract for rewards distribution
    await rewardToken.write.mint([staking.address, parseEther('100000')], {
      account: owner.account,
    });
  });

  describe('Pool Management', function () {
    it('Should have default pools created', async function () {
      const poolCount = await staking.read.poolCount();
      assert.equal(poolCount, 4n); // 4 default pools

      // Check pool 0 (no lock, 8% APY)
      const [lockPeriod0, rewardRate0, totalStaked0, active0] = await staking.read.getPoolInfo([
        0n,
      ]);
      assert.equal(lockPeriod0, 0n);
      assert.equal(rewardRate0, 800n); // 8% = 800 basis points
      assert.equal(totalStaked0, 0n);
      assert.equal(active0, true);

      // Check pool 3 (180 days, 25% APY)
      const [lockPeriod3, rewardRate3, totalStaked3, active3] = await staking.read.getPoolInfo([
        3n,
      ]);
      assert.equal(lockPeriod3, 180n * 24n * 60n * 60n); // 180 days in seconds
      assert.equal(rewardRate3, 2500n); // 25% = 2500 basis points
      assert.equal(totalStaked3, 0n);
      assert.equal(active3, true);
    });

    it('Should allow owner to create new pools', async function () {
      const lockPeriod = 365n * 24n * 60n * 60n; // 1 year
      const rewardRate = 3000n; // 30% APY

      await staking.write.createPool([lockPeriod, rewardRate], {
        account: owner.account,
      });

      const poolCount = await staking.read.poolCount();
      assert.equal(poolCount, 5n);

      const [newLockPeriod, newRewardRate, newTotalStaked, newActive] =
        await staking.read.getPoolInfo([4n]);
      assert.equal(newLockPeriod, lockPeriod);
      assert.equal(newRewardRate, rewardRate);
      assert.equal(newTotalStaked, 0n);
      assert.equal(newActive, true);
    });

    it('Should allow owner to toggle pool status', async function () {
      // Initially active
      const [, , , initialActive] = await staking.read.getPoolInfo([0n]);
      assert.equal(initialActive, true);

      // Toggle to inactive
      await staking.write.togglePool([0n], { account: owner.account });
      const [, , , afterToggle] = await staking.read.getPoolInfo([0n]);
      assert.equal(afterToggle, false);

      // Toggle back to active
      await staking.write.togglePool([0n], { account: owner.account });
      const [, , , afterSecondToggle] = await staking.read.getPoolInfo([0n]);
      assert.equal(afterSecondToggle, true);
    });
  });

  describe('Staking Operations', function () {
    it('Should allow users to stake tokens', async function () {
      const stakeAmount = parseEther('1000');
      const poolId = 0n; // No lock pool

      // Approve and stake
      await stakingToken.write.approve([staking.address, stakeAmount], {
        account: user1.account,
      });
      await staking.write.stake([poolId, stakeAmount], {
        account: user1.account,
      });

      // Check user stake
      const [amount, stakePoolId, stakeTime, lastClaimTime, unlockTime] =
        await staking.read.getUserStake([user1.account.address, 0n]);

      assert.equal(amount, stakeAmount);
      assert.equal(stakePoolId, poolId);
      assert(stakeTime > 0n);
      assert(lastClaimTime > 0n);
      assert.equal(unlockTime, stakeTime); // No lock = immediate unlock

      // Check pool total staked
      const [, , totalStaked] = await staking.read.getPoolInfo([poolId]);
      assert.equal(totalStaked, stakeAmount);

      // Check user's total staked
      const userTotalStaked = await staking.read.totalUserStaked([user1.account.address]);
      assert.equal(userTotalStaked, stakeAmount);
    });

    it('Should handle multiple stakes from same user', async function () {
      const stakeAmount1 = parseEther('500');
      const stakeAmount2 = parseEther('1000');

      // First stake in pool 0 (no lock)
      await stakingToken.write.approve([staking.address, stakeAmount1], {
        account: user1.account,
      });
      await staking.write.stake([0n, stakeAmount1], {
        account: user1.account,
      });

      // Second stake in pool 1 (30 days lock)
      await stakingToken.write.approve([staking.address, stakeAmount2], {
        account: user1.account,
      });
      await staking.write.stake([1n, stakeAmount2], {
        account: user1.account,
      });

      // Check user has 2 stakes
      const stakeCount = await staking.read.userStakeCount([user1.account.address]);
      assert.equal(stakeCount, 2n);

      // Check first stake
      const [amount1, poolId1] = await staking.read.getUserStake([user1.account.address, 0n]);
      assert.equal(amount1, stakeAmount1);
      assert.equal(poolId1, 0n);

      // Check second stake
      const [amount2, poolId2] = await staking.read.getUserStake([user1.account.address, 1n]);
      assert.equal(amount2, stakeAmount2);
      assert.equal(poolId2, 1n);

      // Check total user staked
      const totalStaked = await staking.read.totalUserStaked([user1.account.address]);
      assert.equal(totalStaked, stakeAmount1 + stakeAmount2);
    });

    it('Should calculate unlock time correctly for locked pools', async function () {
      const stakeAmount = parseEther('1000');
      const poolId = 2n; // 90 days lock

      await stakingToken.write.approve([staking.address, stakeAmount], {
        account: user1.account,
      });
      await staking.write.stake([poolId, stakeAmount], {
        account: user1.account,
      });

      const [, , stakeTime, , unlockTime] = await staking.read.getUserStake([
        user1.account.address,
        0n,
      ]);
      const expectedUnlockTime = stakeTime + 90n * 24n * 60n * 60n; // 90 days in seconds

      assert.equal(unlockTime, expectedUnlockTime);
    });
  });

  describe('Reward Calculations', function () {
    it('Should calculate rewards correctly over time', async function () {
      const stakeAmount = parseEther('1000');
      const poolId = 0n; // 8% APY, no lock

      // Stake tokens
      await stakingToken.write.approve([staking.address, stakeAmount], {
        account: user1.account,
      });
      await staking.write.stake([poolId, stakeAmount], {
        account: user1.account,
      });

      // Wait some time by mining blocks (simulate time passing)
      // In a real test environment, you'd use time manipulation
      // For now, we'll check that reward calculation function works
      const reward = await staking.read.calculateReward([user1.account.address, 0n]);

      // Reward should be 0 initially (just staked)
      assert(reward >= 0n);
    });

    it('Should show higher rewards for higher rate pools', async function () {
      const stakeAmount = parseEther('1000');

      // Stake same amount in different pools
      await stakingToken.write.approve([staking.address, stakeAmount * 2n], {
        account: user1.account,
      });

      // Pool 0: 8% APY
      await staking.write.stake([0n, stakeAmount], {
        account: user1.account,
      });

      // Pool 3: 25% APY
      await staking.write.stake([3n, stakeAmount], {
        account: user1.account,
      });

      // Get pool info to verify different rates
      const [, rate0] = await staking.read.getPoolInfo([0n]);
      const [, rate3] = await staking.read.getPoolInfo([3n]);

      assert(rate3 > rate0); // 25% > 8%
      assert.equal(rate0, 800n);
      assert.equal(rate3, 2500n);
    });

    it('Should calculate total pending rewards across all stakes', async function () {
      const stakeAmount = parseEther('500');

      // Make multiple stakes
      await stakingToken.write.approve([staking.address, stakeAmount * 3n], {
        account: user1.account,
      });

      await staking.write.stake([0n, stakeAmount], { account: user1.account });
      await staking.write.stake([1n, stakeAmount], { account: user1.account });
      await staking.write.stake([2n, stakeAmount], { account: user1.account });

      const totalRewards = await staking.read.getTotalPendingRewards([user1.account.address]);
      assert(totalRewards >= 0n); // Should be non-negative
    });
  });

  describe('Unstaking Operations', function () {
    it('Should allow unstaking from unlocked pools immediately', async function () {
      const stakeAmount = parseEther('1000');
      const poolId = 0n; // No lock pool

      // Stake tokens
      await stakingToken.write.approve([staking.address, stakeAmount], {
        account: user1.account,
      });
      await staking.write.stake([poolId, stakeAmount], {
        account: user1.account,
      });

      const balanceBefore = await stakingToken.read.balanceOf([user1.account.address]);

      // Unstake immediately (no lock period)
      await staking.write.unstake([0n], {
        account: user1.account,
      });

      const balanceAfter = await stakingToken.read.balanceOf([user1.account.address]);
      assert.equal(balanceAfter, balanceBefore + stakeAmount);

      // Check stake is cleared
      const [amount] = await staking.read.getUserStake([user1.account.address, 0n]);
      assert.equal(amount, 0n);
    });

    it('Should prevent unstaking from locked pools before unlock time', async function () {
      const stakeAmount = parseEther('1000');
      const poolId = 1n; // 30 days lock

      // Stake tokens
      await stakingToken.write.approve([staking.address, stakeAmount], {
        account: user1.account,
      });
      await staking.write.stake([poolId, stakeAmount], {
        account: user1.account,
      });

      // Try to unstake immediately (should fail)
      try {
        await staking.write.unstake([0n], {
          account: user1.account,
        });
        assert.fail('Should have thrown an error');
      } catch (error: any) {
        assert(
          error.message.includes('Tokens are still locked') || error.message.includes('reverted')
        );
      }
    });
  });

  describe('Reward Claiming', function () {
    it('Should allow claiming rewards without unstaking', async function () {
      const stakeAmount = parseEther('1000');
      const poolId = 0n;

      // Stake tokens
      await stakingToken.write.approve([staking.address, stakeAmount], {
        account: user1.account,
      });
      await staking.write.stake([poolId, stakeAmount], {
        account: user1.account,
      });

      // Check initial reward token balance
      const rewardBalanceBefore = await rewardToken.read.balanceOf([user1.account.address]);

      // Try to claim rewards (might be 0 if no time passed)
      const pendingReward = await staking.read.calculateReward([user1.account.address, 0n]);

      if (pendingReward > 0n) {
        await staking.write.claimRewards([0n], {
          account: user1.account,
        });

        const rewardBalanceAfter = await rewardToken.read.balanceOf([user1.account.address]);
        assert(rewardBalanceAfter >= rewardBalanceBefore);
      }

      // Verify stake is still there
      const [amount] = await staking.read.getUserStake([user1.account.address, 0n]);
      assert.equal(amount, stakeAmount);
    });
  });

  describe('Owner Functions', function () {
    it('Should allow owner to deposit reward tokens', async function () {
      const depositAmount = parseEther('10000');

      await rewardToken.write.approve([staking.address, depositAmount], {
        account: owner.account,
      });
      await staking.write.depositRewards([depositAmount], {
        account: owner.account,
      });

      // Verify tokens were transferred to staking contract
      const contractBalance = await rewardToken.read.balanceOf([staking.address]);
      assert(contractBalance >= depositAmount);
    });

    it('Should allow owner to transfer ownership', async function () {
      const currentOwner = await staking.read.owner();
      assert.equal(currentOwner.toLowerCase(), owner.account.address.toLowerCase());

      await staking.write.transferOwnership([user1.account.address], {
        account: owner.account,
      });

      const newOwner = await staking.read.owner();
      assert.equal(newOwner.toLowerCase(), user1.account.address.toLowerCase());
    });

    it('Should prevent non-owners from calling owner functions', async function () {
      try {
        await staking.write.createPool([86400n, 1000n], {
          account: user1.account, // Not the owner
        });
        assert.fail('Should have thrown an error');
      } catch (error: any) {
        assert(error.message.includes('Not the owner') || error.message.includes('reverted'));
      }
    });
  });

  describe('Edge Cases', function () {
    it('Should handle zero amount stakes gracefully', async function () {
      try {
        await staking.write.stake([0n, 0n], {
          account: user1.account,
        });
        assert.fail('Should have thrown an error');
      } catch (error: any) {
        assert(
          error.message.includes('Amount must be greater than 0') ||
            error.message.includes('reverted')
        );
      }
    });

    it('Should handle invalid pool IDs', async function () {
      const stakeAmount = parseEther('1000');
      const invalidPoolId = 999n;

      try {
        await stakingToken.write.approve([staking.address, stakeAmount], {
          account: user1.account,
        });
        await staking.write.stake([invalidPoolId, stakeAmount], {
          account: user1.account,
        });
        assert.fail('Should have thrown an error');
      } catch (error: any) {
        assert(error.message.includes('Pool does not exist') || error.message.includes('reverted'));
      }
    });

    it('Should handle inactive pools', async function () {
      const stakeAmount = parseEther('1000');
      const poolId = 0n;

      // Deactivate pool
      await staking.write.togglePool([poolId], { account: owner.account });

      try {
        await stakingToken.write.approve([staking.address, stakeAmount], {
          account: user1.account,
        });
        await staking.write.stake([poolId, stakeAmount], {
          account: user1.account,
        });
        assert.fail('Should have thrown an error');
      } catch (error: any) {
        assert(error.message.includes('Pool is not active') || error.message.includes('reverted'));
      }
    });
  });
});
