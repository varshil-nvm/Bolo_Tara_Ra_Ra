import { buildModule } from '@nomicfoundation/hardhat-ignition/modules';
import KYCRegistryModule from './KYCRegistry';

const GreenHydrogenCreditModule = buildModule('GreenHydrogenCreditModule', (m) => {
  // First deploy or use the KYC Registry
  const { kycRegistry } = m.useModule(KYCRegistryModule);

  // Deploy the Green Hydrogen Credit contract with KYC Registry address
  const greenHydrogenCredit = m.contract('GreenHydrogenCredit', [kycRegistry]);

  return {
    kycRegistry,
    greenHydrogenCredit,
  };
});

export default GreenHydrogenCreditModule;
