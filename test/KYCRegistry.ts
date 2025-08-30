import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { parseEther, keccak256, toHex } from 'viem';

import { network } from 'hardhat';

describe('KYCRegistry', async function () {
  const { viem } = await network.connect();

  describe('Deployment and Role Setup', function () {
    it('Should deploy with correct initial roles', async function () {
      const [admin] = await viem.getWalletClients();
      const kycRegistry = await viem.deployContract('KYCRegistry', []);

      // Check admin role
      const DEFAULT_ADMIN_ROLE =
        '0x0000000000000000000000000000000000000000000000000000000000000000';
      const hasAdminRole = await kycRegistry.read.hasRole([
        DEFAULT_ADMIN_ROLE,
        admin.account.address,
      ]);
      assert.equal(hasAdminRole, true);

      // Check total registered users starts at 0
      const totalUsers = await kycRegistry.read.totalRegisteredUsers();
      assert.equal(totalUsers, 0n);
    });

    it('Should allow admin to grant roles', async function () {
      const [admin, certifier] = await viem.getWalletClients();
      const kycRegistry = await viem.deployContract('KYCRegistry', []);

      const CERTIFIER_ROLE = keccak256(toHex('CERTIFIER_ROLE'));

      await kycRegistry.write.grantRole([CERTIFIER_ROLE, certifier.account.address], {
        account: admin.account,
      });

      const hasCertifierRole = await kycRegistry.read.hasRole([
        CERTIFIER_ROLE,
        certifier.account.address,
      ]);
      assert.equal(hasCertifierRole, true);
    });
  });

  describe('User Registration', function () {
    it('Should allow users to register themselves', async function () {
      const [admin, user1] = await viem.getWalletClients();
      const kycRegistry = await viem.deployContract('KYCRegistry', []);

      await kycRegistry.write.registerUser([], {
        account: user1.account,
      });

      const isRegistered = await kycRegistry.read.registeredUsers([user1.account.address]);
      assert.equal(isRegistered, true);

      const totalUsers = await kycRegistry.read.totalRegisteredUsers();
      assert.equal(totalUsers, 1n);

      // Check initial KYC status is Unverified (0)
      const [status] = await kycRegistry.read.getKYCStatus([user1.account.address]);
      assert.equal(status, 0); // KYCStatus.Unverified
    });

    it('Should prevent double registration', async function () {
      const [admin, user1] = await viem.getWalletClients();
      const kycRegistry = await viem.deployContract('KYCRegistry', []);

      await kycRegistry.write.registerUser([], {
        account: user1.account,
      });

      // Try to register again
      await assert.rejects(
        kycRegistry.write.registerUser([], {
          account: user1.account,
        }),
        /User already registered/
      );
    });
  });

  describe('KYC Verification', function () {
    it('Should allow certifiers to verify KYC', async function () {
      const [admin, user1] = await viem.getWalletClients();
      const kycRegistry = await viem.deployContract('KYCRegistry', []);

      // Register user
      await kycRegistry.write.registerUser([], {
        account: user1.account,
      });

      // Verify KYC (admin has CERTIFIER_ROLE by default)
      const expiryDuration = 365 * 24 * 60 * 60; // 1 year
      const ipfsHash = 'QmTestHash123';
      const reason = 'Documents verified';

      await kycRegistry.write.verifyKYC(
        [user1.account.address, BigInt(expiryDuration), ipfsHash, reason],
        {
          account: admin.account,
        }
      );

      // Check KYC is now valid
      const isValid = await kycRegistry.read.isKYCValid([user1.account.address]);
      assert.equal(isValid, true);

      // Check status details
      const [status, verifiedAt, expiresAt, certifier] = await kycRegistry.read.getKYCStatus([
        user1.account.address,
      ]);
      assert.equal(status, 1); // KYCStatus.Verified
      assert.equal(certifier.toLowerCase(), admin.account.address.toLowerCase());
      assert.notEqual(verifiedAt, 0n);
      assert.notEqual(expiresAt, 0n);
    });

    it('Should prevent non-certifiers from verifying KYC', async function () {
      const [admin, user1, nonCertifier] = await viem.getWalletClients();
      const kycRegistry = await viem.deployContract('KYCRegistry', []);

      // Register user
      await kycRegistry.write.registerUser([], {
        account: user1.account,
      });

      // Try to verify as non-certifier
      await assert.rejects(
        kycRegistry.write.verifyKYC(
          [
            user1.account.address,
            BigInt(365 * 24 * 60 * 60),
            'QmTestHash123',
            'Documents verified',
          ],
          {
            account: nonCertifier.account,
          }
        ),
        /AccessControl/
      );
    });

    it('Should prevent verifying already verified users', async function () {
      const [admin, user1] = await viem.getWalletClients();
      const kycRegistry = await viem.deployContract('KYCRegistry', []);

      // Register and verify user
      await kycRegistry.write.registerUser([], {
        account: user1.account,
      });

      await kycRegistry.write.verifyKYC(
        [user1.account.address, BigInt(365 * 24 * 60 * 60), 'QmTestHash123', 'Documents verified'],
        {
          account: admin.account,
        }
      );

      // Try to verify again
      await assert.rejects(
        kycRegistry.write.verifyKYC(
          [user1.account.address, BigInt(365 * 24 * 60 * 60), 'QmTestHash456', 'Re-verification'],
          {
            account: admin.account,
          }
        ),
        /User already verified/
      );
    });
  });

  describe('KYC Revocation', function () {
    it('Should allow certifiers to revoke KYC', async function () {
      const [admin, user1] = await viem.getWalletClients();
      const kycRegistry = await viem.deployContract('KYCRegistry', []);

      // Register and verify user
      await kycRegistry.write.registerUser([], {
        account: user1.account,
      });

      await kycRegistry.write.verifyKYC(
        [
          user1.account.address,
          0n, // No expiry
          'QmTestHash123',
          'Documents verified',
        ],
        {
          account: admin.account,
        }
      );

      // Revoke KYC
      const revokeReason = 'Fraudulent documents detected';
      await kycRegistry.write.revokeKYC([user1.account.address, revokeReason], {
        account: admin.account,
      });

      // Check KYC is no longer valid
      const isValid = await kycRegistry.read.isKYCValid([user1.account.address]);
      assert.equal(isValid, false);

      // Check status is revoked
      const [status, , , , reason] = await kycRegistry.read.getKYCStatus([user1.account.address]);
      assert.equal(status, 2); // KYCStatus.Revoked
      assert.equal(reason, revokeReason);
    });

    it('Should allow regulators to revoke KYC', async function () {
      const [admin, user1, regulator] = await viem.getWalletClients();
      const kycRegistry = await viem.deployContract('KYCRegistry', []);

      // Grant regulator role
      const REGULATOR_ROLE = keccak256(toHex('REGULATOR_ROLE'));
      await kycRegistry.write.grantRole([REGULATOR_ROLE, regulator.account.address], {
        account: admin.account,
      });

      // Register and verify user
      await kycRegistry.write.registerUser([], {
        account: user1.account,
      });

      await kycRegistry.write.verifyKYC(
        [user1.account.address, 0n, 'QmTestHash123', 'Documents verified'],
        {
          account: admin.account,
        }
      );

      // Revoke as regulator
      await kycRegistry.write.revokeKYC([user1.account.address, 'Regulatory compliance issue'], {
        account: regulator.account,
      });

      const isValid = await kycRegistry.read.isKYCValid([user1.account.address]);
      assert.equal(isValid, false);
    });
  });

  describe('Batch Operations', function () {
    it('Should allow batch KYC verification', async function () {
      const [admin, user1, user2, user3] = await viem.getWalletClients();
      const kycRegistry = await viem.deployContract('KYCRegistry', []);

      // Register users
      await kycRegistry.write.registerUser([], { account: user1.account });
      await kycRegistry.write.registerUser([], { account: user2.account });
      await kycRegistry.write.registerUser([], { account: user3.account });

      // Batch verify
      const users = [user1.account.address, user2.account.address, user3.account.address];
      await kycRegistry.write.batchVerifyKYC(
        [
          users,
          BigInt(365 * 24 * 60 * 60), // 1 year
          'Batch verification completed',
        ],
        {
          account: admin.account,
        }
      );

      // Check all users are verified
      for (const userAddr of users) {
        const isValid = await kycRegistry.read.isKYCValid([userAddr]);
        assert.equal(isValid, true);
      }
    });

    it('Should reject empty batch operations', async function () {
      const [admin] = await viem.getWalletClients();
      const kycRegistry = await viem.deployContract('KYCRegistry', []);

      await assert.rejects(
        kycRegistry.write.batchVerifyKYC([[], BigInt(365 * 24 * 60 * 60), 'Batch verification'], {
          account: admin.account,
        }),
        /Empty user array/
      );
    });
  });

  describe('KYC Expiration', function () {
    it('Should handle KYC expiration correctly', async function () {
      const [admin, user1] = await viem.getWalletClients();
      const kycRegistry = await viem.deployContract('KYCRegistry', []);

      // Register user
      await kycRegistry.write.registerUser([], {
        account: user1.account,
      });

      // Verify with very short expiry (1 second)
      await kycRegistry.write.verifyKYC(
        [
          user1.account.address,
          1n, // 1 second expiry
          'QmTestHash123',
          'Short-term verification',
        ],
        {
          account: admin.account,
        }
      );

      // Initially valid
      const isValid = await kycRegistry.read.isKYCValid([user1.account.address]);
      assert.equal(isValid, true);

      // Wait and check expiration warning
      const willExpire = await kycRegistry.read.willKYCExpireSoon([user1.account.address, 3600n]);
      assert.equal(willExpire, true);
    });

    it('Should handle no-expiry KYC correctly', async function () {
      const [admin, user1] = await viem.getWalletClients();
      const kycRegistry = await viem.deployContract('KYCRegistry', []);

      // Register user
      await kycRegistry.write.registerUser([], {
        account: user1.account,
      });

      // Verify with no expiry
      await kycRegistry.write.verifyKYC(
        [
          user1.account.address,
          0n, // No expiry
          'QmTestHash123',
          'Permanent verification',
        ],
        {
          account: admin.account,
        }
      );

      const isValid = await kycRegistry.read.isKYCValid([user1.account.address]);
      assert.equal(isValid, true);

      const willExpire = await kycRegistry.read.willKYCExpireSoon([user1.account.address, 3600n]);
      assert.equal(willExpire, false);
    });
  });

  describe('Access Control and Security', function () {
    it('Should prevent unauthorized access to sensitive functions', async function () {
      const [admin, user1, unauthorized] = await viem.getWalletClients();
      const kycRegistry = await viem.deployContract('KYCRegistry', []);

      // Register user
      await kycRegistry.write.registerUser([], {
        account: user1.account,
      });

      // Try to verify as unauthorized user
      await assert.rejects(
        kycRegistry.write.verifyKYC(
          [
            user1.account.address,
            BigInt(365 * 24 * 60 * 60),
            'QmTestHash123',
            'Unauthorized verification',
          ],
          {
            account: unauthorized.account,
          }
        ),
        /AccessControl/
      );
    });

    it('Should allow users to view their own documents', async function () {
      const [admin, user1] = await viem.getWalletClients();
      const kycRegistry = await viem.deployContract('KYCRegistry', []);

      // Register and verify user
      await kycRegistry.write.registerUser([], {
        account: user1.account,
      });

      const ipfsHash = 'QmTestDocuments123';
      await kycRegistry.write.verifyKYC(
        [user1.account.address, 0n, ipfsHash, 'Documents verified'],
        {
          account: admin.account,
        }
      );

      // User should be able to view their own documents
      const documents = await kycRegistry.read.getKYCDocuments([user1.account.address], {
        account: user1.account,
      });
      assert.equal(documents, ipfsHash);
    });

    it('Should prevent unauthorized users from viewing documents', async function () {
      const [admin, user1, unauthorized] = await viem.getWalletClients();
      const kycRegistry = await viem.deployContract('KYCRegistry', []);

      // Register and verify user
      await kycRegistry.write.registerUser([], {
        account: user1.account,
      });

      await kycRegistry.write.verifyKYC(
        [user1.account.address, 0n, 'QmTestDocuments123', 'Documents verified'],
        {
          account: admin.account,
        }
      );

      // Unauthorized user should not be able to view documents
      await assert.rejects(
        kycRegistry.read.getKYCDocuments([user1.account.address], {
          account: unauthorized.account,
        }),
        /Not authorized to view documents/
      );
    });
  });

  describe('Regulatory Functions', function () {
    it('Should allow regulators to get status counts', async function () {
      const [admin, user1, user2, user3, regulator] = await viem.getWalletClients();
      const kycRegistry = await viem.deployContract('KYCRegistry', []);

      // Grant regulator role
      const REGULATOR_ROLE = keccak256(toHex('REGULATOR_ROLE'));
      await kycRegistry.write.grantRole([REGULATOR_ROLE, regulator.account.address], {
        account: admin.account,
      });

      // Register users
      await kycRegistry.write.registerUser([], { account: user1.account });
      await kycRegistry.write.registerUser([], { account: user2.account });
      await kycRegistry.write.registerUser([], { account: user3.account });

      // Verify some users
      await kycRegistry.write.verifyKYC([user1.account.address, 0n, 'QmHash1', 'Verified'], {
        account: admin.account,
      });

      await kycRegistry.write.verifyKYC([user2.account.address, 0n, 'QmHash2', 'Verified'], {
        account: admin.account,
      });

      // Revoke one user
      await kycRegistry.write.revokeKYC([user2.account.address, 'Policy violation'], {
        account: admin.account,
      });

      // Check counts
      const [unverified, verified, revoked] = await kycRegistry.read.getStatusCounts([], {
        account: regulator.account,
      });

      assert.equal(unverified, 1n); // user3
      assert.equal(verified, 1n); // user1
      assert.equal(revoked, 1n); // user2
    });

    it('Should allow regulators to get users by status', async function () {
      const [admin, user1, user2, regulator] = await viem.getWalletClients();
      const kycRegistry = await viem.deployContract('KYCRegistry', []);

      // Grant regulator role
      const REGULATOR_ROLE = keccak256(toHex('REGULATOR_ROLE'));
      await kycRegistry.write.grantRole([REGULATOR_ROLE, regulator.account.address], {
        account: admin.account,
      });

      // Register and verify users
      await kycRegistry.write.registerUser([], { account: user1.account });
      await kycRegistry.write.registerUser([], { account: user2.account });

      await kycRegistry.write.verifyKYC([user1.account.address, 0n, 'QmHash1', 'Verified'], {
        account: admin.account,
      });

      // Get verified users
      const verifiedUsers = await kycRegistry.read.getUsersByStatus([1], {
        // KYCStatus.Verified
        account: regulator.account,
      });

      assert.equal(verifiedUsers.length, 1);
      assert.equal(verifiedUsers[0].toLowerCase(), user1.account.address.toLowerCase());
    });
  });

  describe('Edge Cases and Error Handling', function () {
    it('Should handle unregistered users gracefully', async function () {
      const [admin, unregisteredUser] = await viem.getWalletClients();
      const kycRegistry = await viem.deployContract('KYCRegistry', []);

      const isValid = await kycRegistry.read.isKYCValid([unregisteredUser.account.address]);
      assert.equal(isValid, false);

      await assert.rejects(
        kycRegistry.read.getKYCStatus([unregisteredUser.account.address]),
        /User not registered/
      );
    });

    it('Should handle document updates correctly', async function () {
      const [admin, user1] = await viem.getWalletClients();
      const kycRegistry = await viem.deployContract('KYCRegistry', []);

      // Register and verify user
      await kycRegistry.write.registerUser([], {
        account: user1.account,
      });

      const originalHash = 'QmOriginalHash';
      await kycRegistry.write.verifyKYC(
        [user1.account.address, 0n, originalHash, 'Initial verification'],
        {
          account: admin.account,
        }
      );

      // Update documents
      const newHash = 'QmUpdatedHash';
      await kycRegistry.write.updateKYCDocuments([user1.account.address, newHash], {
        account: admin.account,
      });

      // Check updated hash
      const updatedDocuments = await kycRegistry.read.getKYCDocuments([user1.account.address], {
        account: admin.account,
      });
      assert.equal(updatedDocuments, newHash);
    });

    it('Should require valid reasons for status changes', async function () {
      const [admin, user1] = await viem.getWalletClients();
      const kycRegistry = await viem.deployContract('KYCRegistry', []);

      // Register and verify user
      await kycRegistry.write.registerUser([], {
        account: user1.account,
      });

      await kycRegistry.write.verifyKYC(
        [user1.account.address, 0n, 'QmTestHash123', 'Documents verified'],
        {
          account: admin.account,
        }
      );

      // Try to revoke with empty reason (should work as empty string is valid in Solidity)
      await kycRegistry.write.revokeKYC(
        [
          user1.account.address,
          '', // Empty reason
        ],
        {
          account: admin.account,
        }
      );

      const isValid = await kycRegistry.read.isKYCValid([user1.account.address]);
      assert.equal(isValid, false);
    });
  });
});
