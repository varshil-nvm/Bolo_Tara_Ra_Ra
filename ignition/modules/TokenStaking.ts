import { buildModule } from '@nomicfoundation/hardhat-ignition/modules';

const TokenStakingModule = buildModule('TokenStakingModule', (m) => {
  // Deploy staking token
  const stakingToken = m.contract(
    'MyToken',
    [
      'Staking Token',
      'STAKE',
      18,
      10000000n, // 10M tokens
    ],
    { id: 'StakingToken' }
  );

  // Deploy reward token (could be the same or different)
  const rewardToken = m.contract(
    'MyToken',
    [
      'Reward Token',
      'REWARD',
      18,
      5000000n, // 5M tokens
    ],
    { id: 'RewardToken' }
  );

  // Deploy the staking contract
  const staking = m.contract('TokenStaking', [stakingToken, rewardToken]);

  return { stakingToken, rewardToken, staking };
});

export default TokenStakingModule;
