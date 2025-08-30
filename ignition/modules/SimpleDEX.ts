import { buildModule } from '@nomicfoundation/hardhat-ignition/modules';

const SimpleDEXModule = buildModule('SimpleDEXModule', (m) => {
  // Deploy two test tokens for the DEX
  const tokenA = m.contract(
    'MyToken',
    [
      'DEX Token A',
      'DEXA',
      18,
      1000000n, // 1M tokens
    ],
    { id: 'DEXTokenA' }
  );

  const tokenB = m.contract(
    'MyToken',
    [
      'DEX Token B',
      'DEXB',
      18,
      1000000n, // 1M tokens
    ],
    { id: 'DEXTokenB' }
  );

  // Deploy the DEX with the two tokens
  const dex = m.contract('SimpleDEX', [tokenA, tokenB]);

  return { tokenA, tokenB, dex };
});

export default SimpleDEXModule;
