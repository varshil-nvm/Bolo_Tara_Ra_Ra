import { buildModule } from '@nomicfoundation/hardhat-ignition/modules';

const MyTokenModule = buildModule('MyTokenModule', (m) => {
  const name = m.getParameter('name', 'MyToken');
  const symbol = m.getParameter('symbol', 'MTK');
  const decimals = m.getParameter('decimals', 18);
  const initialSupply = m.getParameter('initialSupply', 1000000n);

  const token = m.contract('MyToken', [name, symbol, decimals, initialSupply]);

  return { token };
});

export default MyTokenModule;
