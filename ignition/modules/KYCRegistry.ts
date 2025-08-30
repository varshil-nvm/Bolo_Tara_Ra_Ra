import { buildModule } from '@nomicfoundation/hardhat-ignition/modules';

const KYCRegistryModule = buildModule('KYCRegistryModule', (m) => {
  const kycRegistry = m.contract('KYCRegistry', []);

  return { kycRegistry };
});

export default KYCRegistryModule;
