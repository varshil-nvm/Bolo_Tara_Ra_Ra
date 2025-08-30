import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { parseEther, keccak256, toHex, encodePacked } from 'viem';

import { network } from 'hardhat';

describe('GreenHydrogenCredit', async function () {
  const { viem } = await network.connect();

  // Helper function to deploy both contracts
  async function deployContracts() {
    const kycRegistry = await viem.deployContract('KYCRegistry', []);
    const greenCredit = await viem.deployContract('GreenHydrogenCredit', [kycRegistry.address]);
    return { kycRegistry, greenCredit };
  }

  // Helper function to register and verify a user
  async function registerAndVerifyUser(kycRegistry: any, userClient: any, adminClient: any) {
    await kycRegistry.write.registerUser([], { account: userClient.account });
    await kycRegistry.write.verifyKYC(
      [
        userClient.account.address,
        0n, // No expiry
        'QmTestHash123',
        'Documents verified',
      ],
      { account: adminClient.account }
    );
  }

  // Helper function to create production data
  function createProductionData(producer: string, hydrogenAmount = parseEther('100')) {
    const productionHash = keccak256(
      encodePacked(
        ['string', 'address', 'uint256'],
        [`production_${Date.now()}`, producer, hydrogenAmount]
      )
    );

    return {
      producer,
      productionHash,
      hydrogenAmount,
      productionDate: BigInt(Math.floor(Date.now() / 1000)),
      facilityId: 'FACILITY_001',
      certificationData: 'QmCertificationHash123',
      location: 'Germany, Renewable Energy Park',
      carbonIntensity: parseEther('0.5'), // 0.5 kg CO2/kg H2
    };
  }

  describe('Deployment and Setup', function () {
    it('Should deploy with correct parameters', async function () {
      const { kycRegistry, greenCredit } = await deployContracts();

      const name = await greenCredit.read.name();
      const symbol = await greenCredit.read.symbol();
      const kycAddr = await greenCredit.read.kycRegistry();

      assert.equal(name, 'Green Hydrogen Credit');
      assert.equal(symbol, 'GHC');
      assert.equal(kycAddr.toLowerCase(), kycRegistry.address.toLowerCase());

      const totalIssued = await greenCredit.read.totalCreditsIssued();
      assert.equal(totalIssued, 0n);
    });

    it('Should set up roles correctly', async function () {
      const [admin] = await viem.getWalletClients();
      const { greenCredit } = await deployContracts();

      const DEFAULT_ADMIN_ROLE =
        '0x0000000000000000000000000000000000000000000000000000000000000000';
      const CERTIFIER_ROLE = keccak256(toHex('CERTIFIER_ROLE'));

      const hasAdminRole = await greenCredit.read.hasRole([
        DEFAULT_ADMIN_ROLE,
        admin.account.address,
      ]);
      const hasCertifierRole = await greenCredit.read.hasRole([
        CERTIFIER_ROLE,
        admin.account.address,
      ]);

      assert.equal(hasAdminRole, true);
      assert.equal(hasCertifierRole, true);
    });
  });

  describe('Credit Minting', function () {
    it('Should mint a credit with valid parameters', async function () {
      const [admin, producer] = await viem.getWalletClients();
      const { kycRegistry, greenCredit } = await deployContracts();

      // Register and verify producer
      await registerAndVerifyUser(kycRegistry, producer, admin);

      // Create production data
      const prodData = createProductionData(producer.account.address);

      // Mint credit
      await greenCredit.write.mintCredit(
        [
          prodData.producer,
          prodData.productionHash,
          prodData.hydrogenAmount,
          prodData.productionDate,
          prodData.facilityId,
          prodData.certificationData,
          prodData.location,
          prodData.carbonIntensity,
        ],
        { account: admin.account }
      );

      // Check credit was minted
      const totalSupply = await greenCredit.read.totalSupply();
      assert.equal(totalSupply, 1n);

      const balance = await greenCredit.read.balanceOf([producer.account.address]);
      assert.equal(balance, 1n);

      const owner = await greenCredit.read.ownerOf([1n]);
      assert.equal(owner.toLowerCase(), producer.account.address.toLowerCase());
    });

    it('Should prevent double-minting with same production hash', async function () {
      const [admin, producer] = await viem.getWalletClients();
      const { kycRegistry, greenCredit } = await deployContracts();

      await registerAndVerifyUser(kycRegistry, producer, admin);
      const prodData = createProductionData(producer.account.address);

      // First mint should succeed
      await greenCredit.write.mintCredit(
        [
          prodData.producer,
          prodData.productionHash,
          prodData.hydrogenAmount,
          prodData.productionDate,
          prodData.facilityId,
          prodData.certificationData,
          prodData.location,
          prodData.carbonIntensity,
        ],
        { account: admin.account }
      );

      // Second mint with same hash should fail
      await assert.rejects(
        greenCredit.write.mintCredit(
          [
            prodData.producer,
            prodData.productionHash,
            prodData.hydrogenAmount,
            prodData.productionDate,
            prodData.facilityId,
            prodData.certificationData,
            prodData.location,
            prodData.carbonIntensity,
          ],
          { account: admin.account }
        ),
        /Production hash already used/
      );
    });

    it('Should prevent minting without valid KYC', async function () {
      const [admin, producer] = await viem.getWalletClients();
      const { kycRegistry, greenCredit } = await deployContracts();

      // Register but don't verify producer
      await kycRegistry.write.registerUser([], { account: producer.account });

      const prodData = createProductionData(producer.account.address);

      await assert.rejects(
        greenCredit.write.mintCredit(
          [
            prodData.producer,
            prodData.productionHash,
            prodData.hydrogenAmount,
            prodData.productionDate,
            prodData.facilityId,
            prodData.certificationData,
            prodData.location,
            prodData.carbonIntensity,
          ],
          { account: admin.account }
        ),
        /Producer KYC not valid/
      );
    });

    it('Should prevent minting by non-certifiers', async function () {
      const [admin, producer, nonCertifier] = await viem.getWalletClients();
      const { kycRegistry, greenCredit } = await deployContracts();

      await registerAndVerifyUser(kycRegistry, producer, admin);
      const prodData = createProductionData(producer.account.address);

      await assert.rejects(
        greenCredit.write.mintCredit(
          [
            prodData.producer,
            prodData.productionHash,
            prodData.hydrogenAmount,
            prodData.productionDate,
            prodData.facilityId,
            prodData.certificationData,
            prodData.location,
            prodData.carbonIntensity,
          ],
          { account: nonCertifier.account }
        ),
        /AccessControl/
      );
    });

    it('Should validate production parameters', async function () {
      const [admin, producer] = await viem.getWalletClients();
      const { kycRegistry, greenCredit } = await deployContracts();

      await registerAndVerifyUser(kycRegistry, producer, admin);

      // Test minimum hydrogen amount
      let prodData = createProductionData(producer.account.address, BigInt('1000')); // Below minimum
      await assert.rejects(
        greenCredit.write.mintCredit(
          [
            prodData.producer,
            prodData.productionHash,
            prodData.hydrogenAmount,
            prodData.productionDate,
            prodData.facilityId,
            prodData.certificationData,
            prodData.location,
            prodData.carbonIntensity,
          ],
          { account: admin.account }
        ),
        /Hydrogen amount too small/
      );

      // Test maximum carbon intensity
      prodData = createProductionData(producer.account.address);
      prodData.carbonIntensity = parseEther('5'); // Above maximum
      await assert.rejects(
        greenCredit.write.mintCredit(
          [
            prodData.producer,
            prodData.productionHash,
            prodData.hydrogenAmount,
            prodData.productionDate,
            prodData.facilityId,
            prodData.certificationData,
            prodData.location,
            prodData.carbonIntensity,
          ],
          { account: admin.account }
        ),
        /Carbon intensity too high/
      );

      // Test future production date
      prodData = createProductionData(producer.account.address);
      prodData.productionDate = BigInt(Math.floor(Date.now() / 1000) + 86400); // Tomorrow
      await assert.rejects(
        greenCredit.write.mintCredit(
          [
            prodData.producer,
            prodData.productionHash,
            prodData.hydrogenAmount,
            prodData.productionDate,
            prodData.facilityId,
            prodData.certificationData,
            prodData.location,
            prodData.carbonIntensity,
          ],
          { account: admin.account }
        ),
        /Production date cannot be in future/
      );
    });
  });

  describe('Batch Minting', function () {
    it('Should batch mint multiple credits', async function () {
      const [admin, producer1, producer2] = await viem.getWalletClients();
      const { kycRegistry, greenCredit } = await deployContracts();

      // Register and verify producers
      await registerAndVerifyUser(kycRegistry, producer1, admin);
      await registerAndVerifyUser(kycRegistry, producer2, admin);

      // Create batch mint data
      const mintData = [
        createProductionData(producer1.account.address),
        createProductionData(producer2.account.address),
      ];

      // Batch mint
      await greenCredit.write.batchMintCredits([mintData], { account: admin.account });

      // Check results
      const totalSupply = await greenCredit.read.totalSupply();
      assert.equal(totalSupply, 2n);

      const balance1 = await greenCredit.read.balanceOf([producer1.account.address]);
      const balance2 = await greenCredit.read.balanceOf([producer2.account.address]);
      assert.equal(balance1, 1n);
      assert.equal(balance2, 1n);
    });

    it('Should reject empty batch', async function () {
      const [admin] = await viem.getWalletClients();
      const { greenCredit } = await deployContracts();

      await assert.rejects(
        greenCredit.write.batchMintCredits([[]], { account: admin.account }),
        /Empty mint data/
      );
    });

    it('Should reject oversized batches', async function () {
      const [admin, producer] = await viem.getWalletClients();
      const { kycRegistry, greenCredit } = await deployContracts();

      await registerAndVerifyUser(kycRegistry, producer, admin);

      // Create oversized batch (101 items)
      const largeBatch = Array(101)
        .fill(0)
        .map(() => createProductionData(producer.account.address));

      await assert.rejects(
        greenCredit.write.batchMintCredits([largeBatch], { account: admin.account }),
        /Batch too large/
      );
    });
  });

  describe('Credit Information', function () {
    it('Should retrieve credit information correctly', async function () {
      const [admin, producer] = await viem.getWalletClients();
      const { kycRegistry, greenCredit } = await deployContracts();

      await registerAndVerifyUser(kycRegistry, producer, admin);
      const prodData = createProductionData(producer.account.address);

      // Mint credit
      await greenCredit.write.mintCredit(
        [
          prodData.producer,
          prodData.productionHash,
          prodData.hydrogenAmount,
          prodData.productionDate,
          prodData.facilityId,
          prodData.certificationData,
          prodData.location,
          prodData.carbonIntensity,
        ],
        { account: admin.account }
      );

      // Get credit info
      const creditInfo = await greenCredit.read.getCreditInfo([1n]);
      assert.equal(
        creditInfo.production.producer.toLowerCase(),
        producer.account.address.toLowerCase()
      );
      assert.equal(creditInfo.production.hydrogenAmount, prodData.hydrogenAmount);
      assert.equal(creditInfo.production.facilityId, prodData.facilityId);
      assert.equal(creditInfo.status, 0); // Active

      // Test production hash tracking
      const [used, tokenId] = await greenCredit.read.isProductionHashUsed([
        prodData.productionHash,
      ]);
      assert.equal(used, true);
      assert.equal(tokenId, 1n);
    });

    it('Should track producer credits', async function () {
      const [admin, producer] = await viem.getWalletClients();
      const { kycRegistry, greenCredit } = await deployContracts();

      await registerAndVerifyUser(kycRegistry, producer, admin);

      // Mint multiple credits for same producer
      for (let i = 0; i < 3; i++) {
        const prodData = createProductionData(producer.account.address);
        await greenCredit.write.mintCredit(
          [
            prodData.producer,
            prodData.productionHash,
            prodData.hydrogenAmount,
            prodData.productionDate,
            prodData.facilityId,
            prodData.certificationData,
            prodData.location,
            prodData.carbonIntensity,
          ],
          { account: admin.account }
        );
      }

      // Check producer credits
      const producerCredits = await greenCredit.read.getProducerCredits([producer.account.address]);
      assert.equal(producerCredits.length, 3);
      assert.deepEqual(producerCredits, [1n, 2n, 3n]);
    });
  });

  describe('Credit Retirement', function () {
    it('Should allow credit owner to retire credit', async function () {
      const [admin, producer] = await viem.getWalletClients();
      const { kycRegistry, greenCredit } = await deployContracts();

      await registerAndVerifyUser(kycRegistry, producer, admin);
      const prodData = createProductionData(producer.account.address);

      // Mint credit
      await greenCredit.write.mintCredit(
        [
          prodData.producer,
          prodData.productionHash,
          prodData.hydrogenAmount,
          prodData.productionDate,
          prodData.facilityId,
          prodData.certificationData,
          prodData.location,
          prodData.carbonIntensity,
        ],
        { account: admin.account }
      );

      // Retire credit
      const retireReason = 'Offsetting carbon emissions';
      await greenCredit.write.retireCredit([1n, retireReason], { account: producer.account });

      // Check credit is retired (should throw when trying to access burned token)
      await assert.rejects(greenCredit.read.ownerOf([1n]), /ERC721NonexistentToken/);

      // Check retirement stats
      const totalRetired = await greenCredit.read.totalCreditsRetired();
      assert.equal(totalRetired, 1n);

      // Check credit info still accessible
      const creditInfo = await greenCredit.read.getCreditInfo([1n]);
      assert.equal(creditInfo.status, 2); // Retired
      assert.equal(creditInfo.retirementReason, retireReason);
    });

    it('Should prevent non-owners from retiring credits', async function () {
      const [admin, producer, nonOwner] = await viem.getWalletClients();
      const { kycRegistry, greenCredit } = await deployContracts();

      await registerAndVerifyUser(kycRegistry, producer, admin);
      const prodData = createProductionData(producer.account.address);

      // Mint credit
      await greenCredit.write.mintCredit(
        [
          prodData.producer,
          prodData.productionHash,
          prodData.hydrogenAmount,
          prodData.productionDate,
          prodData.facilityId,
          prodData.certificationData,
          prodData.location,
          prodData.carbonIntensity,
        ],
        { account: admin.account }
      );

      // Try to retire as non-owner
      await assert.rejects(
        greenCredit.write.retireCredit([1n, 'Invalid retirement'], { account: nonOwner.account }),
        /Not the owner of this credit/
      );
    });
  });

  describe('Credit Flagging and Regulation', function () {
    it('Should allow regulators to flag credits', async function () {
      const [admin, producer, regulator] = await viem.getWalletClients();
      const { kycRegistry, greenCredit } = await deployContracts();

      // Grant regulator role
      const REGULATOR_ROLE = keccak256(toHex('REGULATOR_ROLE'));
      await greenCredit.write.grantRole([REGULATOR_ROLE, regulator.account.address], {
        account: admin.account,
      });

      await registerAndVerifyUser(kycRegistry, producer, admin);
      const prodData = createProductionData(producer.account.address);

      // Mint credit
      await greenCredit.write.mintCredit(
        [
          prodData.producer,
          prodData.productionHash,
          prodData.hydrogenAmount,
          prodData.productionDate,
          prodData.facilityId,
          prodData.certificationData,
          prodData.location,
          prodData.carbonIntensity,
        ],
        { account: admin.account }
      );

      // Flag credit
      const flagReason = 'Suspicious production data';
      await greenCredit.write.flagCredit([1n, flagReason], { account: regulator.account });

      // Check credit is flagged
      const creditInfo = await greenCredit.read.getCreditInfo([1n]);
      assert.equal(creditInfo.status, 1); // Flagged
      assert.equal(creditInfo.flagReason, flagReason);
      assert.equal(creditInfo.flaggedBy.toLowerCase(), regulator.account.address.toLowerCase());
    });

    it('Should allow regulators to unflag credits', async function () {
      const [admin, producer, regulator] = await viem.getWalletClients();
      const { kycRegistry, greenCredit } = await deployContracts();

      const REGULATOR_ROLE = keccak256(toHex('REGULATOR_ROLE'));
      await greenCredit.write.grantRole([REGULATOR_ROLE, regulator.account.address], {
        account: admin.account,
      });

      await registerAndVerifyUser(kycRegistry, producer, admin);
      const prodData = createProductionData(producer.account.address);

      // Mint and flag credit
      await greenCredit.write.mintCredit(
        [
          prodData.producer,
          prodData.productionHash,
          prodData.hydrogenAmount,
          prodData.productionDate,
          prodData.facilityId,
          prodData.certificationData,
          prodData.location,
          prodData.carbonIntensity,
        ],
        { account: admin.account }
      );

      await greenCredit.write.flagCredit([1n, 'Investigation needed'], {
        account: regulator.account,
      });

      // Unflag credit
      await greenCredit.write.unflagCredit([1n], { account: regulator.account });

      // Check credit is active again
      const creditInfo = await greenCredit.read.getCreditInfo([1n]);
      assert.equal(creditInfo.status, 0); // Active
      assert.equal(creditInfo.flagReason, '');
    });

    it('Should prevent non-regulators from flagging credits', async function () {
      const [admin, producer, nonRegulator] = await viem.getWalletClients();
      const { kycRegistry, greenCredit } = await deployContracts();

      await registerAndVerifyUser(kycRegistry, producer, admin);
      const prodData = createProductionData(producer.account.address);

      // Mint credit
      await greenCredit.write.mintCredit(
        [
          prodData.producer,
          prodData.productionHash,
          prodData.hydrogenAmount,
          prodData.productionDate,
          prodData.facilityId,
          prodData.certificationData,
          prodData.location,
          prodData.carbonIntensity,
        ],
        { account: admin.account }
      );

      // Try to flag as non-regulator
      await assert.rejects(
        greenCredit.write.flagCredit([1n, 'Invalid flag'], { account: nonRegulator.account }),
        /AccessControl/
      );
    });
  });

  describe('Transfer Restrictions', function () {
    it('Should require KYC for transfers', async function () {
      const [admin, producer, recipient] = await viem.getWalletClients();
      const { kycRegistry, greenCredit } = await deployContracts();

      await registerAndVerifyUser(kycRegistry, producer, admin);
      const prodData = createProductionData(producer.account.address);

      // Mint credit
      await greenCredit.write.mintCredit(
        [
          prodData.producer,
          prodData.productionHash,
          prodData.hydrogenAmount,
          prodData.productionDate,
          prodData.facilityId,
          prodData.certificationData,
          prodData.location,
          prodData.carbonIntensity,
        ],
        { account: admin.account }
      );

      // Try to transfer to unverified recipient
      await assert.rejects(
        greenCredit.write.transferFrom([producer.account.address, recipient.account.address, 1n], {
          account: producer.account,
        }),
        /Recipient KYC not valid/
      );

      // Register and verify recipient, then transfer should work
      await registerAndVerifyUser(kycRegistry, recipient, admin);

      await greenCredit.write.transferFrom(
        [producer.account.address, recipient.account.address, 1n],
        {
          account: producer.account,
        }
      );

      const newOwner = await greenCredit.read.ownerOf([1n]);
      assert.equal(newOwner.toLowerCase(), recipient.account.address.toLowerCase());
    });

    it('Should prevent transfer of flagged credits', async function () {
      const [admin, producer, recipient, regulator] = await viem.getWalletClients();
      const { kycRegistry, greenCredit } = await deployContracts();

      const REGULATOR_ROLE = keccak256(toHex('REGULATOR_ROLE'));
      await greenCredit.write.grantRole([REGULATOR_ROLE, regulator.account.address], {
        account: admin.account,
      });

      await registerAndVerifyUser(kycRegistry, producer, admin);
      await registerAndVerifyUser(kycRegistry, recipient, admin);
      const prodData = createProductionData(producer.account.address);

      // Mint and flag credit
      await greenCredit.write.mintCredit(
        [
          prodData.producer,
          prodData.productionHash,
          prodData.hydrogenAmount,
          prodData.productionDate,
          prodData.facilityId,
          prodData.certificationData,
          prodData.location,
          prodData.carbonIntensity,
        ],
        { account: admin.account }
      );

      await greenCredit.write.flagCredit([1n, 'Under investigation'], {
        account: regulator.account,
      });

      // Try to transfer flagged credit
      await assert.rejects(
        greenCredit.write.transferFrom([producer.account.address, recipient.account.address, 1n], {
          account: producer.account,
        }),
        /Credit not transferable/
      );
    });
  });

  describe('Aggregate Statistics and Analytics', function () {
    it('Should track aggregate statistics correctly', async function () {
      const [admin, producer1, producer2, regulator] = await viem.getWalletClients();
      const { kycRegistry, greenCredit } = await deployContracts();

      const REGULATOR_ROLE = keccak256(toHex('REGULATOR_ROLE'));
      await greenCredit.write.grantRole([REGULATOR_ROLE, regulator.account.address], {
        account: admin.account,
      });

      await registerAndVerifyUser(kycRegistry, producer1, admin);
      await registerAndVerifyUser(kycRegistry, producer2, admin);

      // Mint multiple credits
      const hydrogenAmounts = [parseEther('100'), parseEther('200'), parseEther('150')];
      for (let i = 0; i < 3; i++) {
        const prodData = createProductionData(
          i < 2 ? producer1.account.address : producer2.account.address,
          hydrogenAmounts[i]
        );
        await greenCredit.write.mintCredit(
          [
            prodData.producer,
            prodData.productionHash,
            prodData.hydrogenAmount,
            prodData.productionDate,
            prodData.facilityId,
            prodData.certificationData,
            prodData.location,
            prodData.carbonIntensity,
          ],
          { account: admin.account }
        );
      }

      // Flag one credit and retire another
      await greenCredit.write.flagCredit([1n, 'Investigation'], { account: regulator.account });
      await greenCredit.write.retireCredit([2n, 'Carbon offset'], { account: producer1.account });

      // Check aggregate stats
      const [totalIssued, totalRetired, totalActive, totalFlagged, totalHydrogen] =
        await greenCredit.read.getAggregateStats();

      assert.equal(totalIssued, 3n);
      assert.equal(totalRetired, 1n);
      assert.equal(totalActive, 1n); // Credit 3
      assert.equal(totalFlagged, 1n); // Credit 1

      const expectedTotalHydrogen = hydrogenAmounts.reduce((sum, amount) => sum + amount, 0n);
      assert.equal(totalHydrogen, expectedTotalHydrogen);
    });

    it('Should allow regulators to get credits by status', async function () {
      const [admin, producer, regulator] = await viem.getWalletClients();
      const { kycRegistry, greenCredit } = await deployContracts();

      const REGULATOR_ROLE = keccak256(toHex('REGULATOR_ROLE'));
      await greenCredit.write.grantRole([REGULATOR_ROLE, regulator.account.address], {
        account: admin.account,
      });

      await registerAndVerifyUser(kycRegistry, producer, admin);

      // Mint credits
      for (let i = 0; i < 3; i++) {
        const prodData = createProductionData(producer.account.address);
        await greenCredit.write.mintCredit(
          [
            prodData.producer,
            prodData.productionHash,
            prodData.hydrogenAmount,
            prodData.productionDate,
            prodData.facilityId,
            prodData.certificationData,
            prodData.location,
            prodData.carbonIntensity,
          ],
          { account: admin.account }
        );
      }

      // Flag two credits
      await greenCredit.write.flagCredit([1n, 'Investigation'], { account: regulator.account });
      await greenCredit.write.flagCredit([2n, 'Investigation'], { account: regulator.account });

      // Get flagged credits
      const flaggedCredits = await greenCredit.read.getCreditsByStatus([1], {
        // Flagged status
        account: regulator.account,
      });

      assert.equal(flaggedCredits.length, 2);
      assert.deepEqual(flaggedCredits, [1n, 2n]);

      // Get active credits
      const activeCredits = await greenCredit.read.getCreditsByStatus([0], {
        // Active status
        account: regulator.account,
      });

      assert.equal(activeCredits.length, 1);
      assert.deepEqual(activeCredits, [3n]);
    });
  });

  describe('Emergency Functions', function () {
    it('Should allow regulators to emergency burn credits', async function () {
      const [admin, producer, regulator] = await viem.getWalletClients();
      const { kycRegistry, greenCredit } = await deployContracts();

      const REGULATOR_ROLE = keccak256(toHex('REGULATOR_ROLE'));
      await greenCredit.write.grantRole([REGULATOR_ROLE, regulator.account.address], {
        account: admin.account,
      });

      await registerAndVerifyUser(kycRegistry, producer, admin);
      const prodData = createProductionData(producer.account.address);

      // Mint credit
      await greenCredit.write.mintCredit(
        [
          prodData.producer,
          prodData.productionHash,
          prodData.hydrogenAmount,
          prodData.productionDate,
          prodData.facilityId,
          prodData.certificationData,
          prodData.location,
          prodData.carbonIntensity,
        ],
        { account: admin.account }
      );

      // Emergency burn
      const burnReason = 'Fraudulent credit detected';
      await greenCredit.write.emergencyBurn([1n, burnReason], { account: regulator.account });

      // Check credit is burned
      await assert.rejects(greenCredit.read.ownerOf([1n]), /ERC721NonexistentToken/);

      // Check retirement stats updated
      const totalRetired = await greenCredit.read.totalCreditsRetired();
      assert.equal(totalRetired, 1n);
    });

    it('Should allow admin to pause/unpause contract', async function () {
      const [admin, producer] = await viem.getWalletClients();
      const { kycRegistry, greenCredit } = await deployContracts();

      // Pause contract
      await greenCredit.write.pause([], { account: admin.account });

      // Try to mint while paused
      await registerAndVerifyUser(kycRegistry, producer, admin);
      const prodData = createProductionData(producer.account.address);

      await assert.rejects(
        greenCredit.write.mintCredit(
          [
            prodData.producer,
            prodData.productionHash,
            prodData.hydrogenAmount,
            prodData.productionDate,
            prodData.facilityId,
            prodData.certificationData,
            prodData.location,
            prodData.carbonIntensity,
          ],
          { account: admin.account }
        ),
        /EnforcedPause/
      );

      // Unpause and try again
      await greenCredit.write.unpause([], { account: admin.account });

      await greenCredit.write.mintCredit(
        [
          prodData.producer,
          prodData.productionHash,
          prodData.hydrogenAmount,
          prodData.productionDate,
          prodData.facilityId,
          prodData.certificationData,
          prodData.location,
          prodData.carbonIntensity,
        ],
        { account: admin.account }
      );

      const totalSupply = await greenCredit.read.totalSupply();
      assert.equal(totalSupply, 1n);
    });
  });

  describe('Configuration Updates', function () {
    it('Should allow admin to update KYC registry', async function () {
      const [admin] = await viem.getWalletClients();
      const { kycRegistry, greenCredit } = await deployContracts();

      // Deploy new KYC registry
      const newKycRegistry = await viem.deployContract('KYCRegistry', []);

      // Update KYC registry
      await greenCredit.write.updateKYCRegistry([newKycRegistry.address], {
        account: admin.account,
      });

      // Check update
      const updatedRegistry = await greenCredit.read.kycRegistry();
      assert.equal(updatedRegistry.toLowerCase(), newKycRegistry.address.toLowerCase());
    });

    it('Should prevent non-admin from updating KYC registry', async function () {
      const [admin, nonAdmin] = await viem.getWalletClients();
      const { kycRegistry, greenCredit } = await deployContracts();

      const newKycRegistry = await viem.deployContract('KYCRegistry', []);

      await assert.rejects(
        greenCredit.write.updateKYCRegistry([newKycRegistry.address], {
          account: nonAdmin.account,
        }),
        /AccessControl/
      );
    });
  });

  describe('Token Metadata', function () {
    it('Should generate correct token URI', async function () {
      const [admin, producer] = await viem.getWalletClients();
      const { kycRegistry, greenCredit } = await deployContracts();

      await registerAndVerifyUser(kycRegistry, producer, admin);
      const prodData = createProductionData(producer.account.address);

      // Mint credit
      await greenCredit.write.mintCredit(
        [
          prodData.producer,
          prodData.productionHash,
          prodData.hydrogenAmount,
          prodData.productionDate,
          prodData.facilityId,
          prodData.certificationData,
          prodData.location,
          prodData.carbonIntensity,
        ],
        { account: admin.account }
      );

      // Check token URI
      const tokenURI = await greenCredit.read.tokenURI([1n]);
      assert.equal(tokenURI, 'https://api.greenhydrogencredits.com/metadata/1.json');
    });
  });
});
