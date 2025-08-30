import assert from 'node:assert/strict';
import { describe, it, beforeEach } from 'node:test';
import { parseEther } from 'viem';

import { network } from 'hardhat';

describe('SimpleDEX', async function () {
  const { viem } = await network.connect();
  let tokenA: any, tokenB: any, dex: any;
  let owner: any, user1: any, user2: any;

  beforeEach(async function () {
    [owner, user1, user2] = await viem.getWalletClients();

    // Deploy tokens
    tokenA = await viem.deployContract('MyToken', [
      'Token A',
      'TKNA',
      18,
      1000000n, // 1M tokens
    ]);

    tokenB = await viem.deployContract('MyToken', [
      'Token B',
      'TKNB',
      18,
      1000000n, // 1M tokens
    ]);

    // Deploy DEX
    dex = await viem.deployContract('SimpleDEX', [tokenA.address, tokenB.address]);

    // Mint tokens to users for testing
    await tokenA.write.mint([user1.account.address, parseEther('10000')], {
      account: owner.account,
    });
    await tokenB.write.mint([user1.account.address, parseEther('10000')], {
      account: owner.account,
    });

    await tokenA.write.mint([user2.account.address, parseEther('5000')], {
      account: owner.account,
    });
    await tokenB.write.mint([user2.account.address, parseEther('5000')], {
      account: owner.account,
    });
  });

  describe('Liquidity Management', function () {
    it('Should add initial liquidity', async function () {
      const amountA = parseEther('1000');
      const amountB = parseEther('2000');

      // Approve tokens
      await tokenA.write.approve([dex.address, amountA], {
        account: user1.account,
      });
      await tokenB.write.approve([dex.address, amountB], {
        account: user1.account,
      });

      // Add liquidity
      await dex.write.addLiquidity([amountA, amountB], {
        account: user1.account,
      });

      // Check reserves
      const [reserveA, reserveB] = await dex.read.getReserves();
      assert.equal(reserveA, amountA);
      assert.equal(reserveB, amountB);

      // Check user liquidity
      const userLiquidity = await dex.read.liquidity([user1.account.address]);
      assert(userLiquidity > 0n);
    });

    it('Should maintain ratio when adding subsequent liquidity', async function () {
      // Add initial liquidity
      const amountA1 = parseEther('1000');
      const amountB1 = parseEther('2000');

      await tokenA.write.approve([dex.address, amountA1], {
        account: user1.account,
      });
      await tokenB.write.approve([dex.address, amountB1], {
        account: user1.account,
      });
      await dex.write.addLiquidity([amountA1, amountB1], {
        account: user1.account,
      });

      // Add more liquidity from user2
      const amountA2 = parseEther('500');
      const amountB2 = parseEther('1000');

      await tokenA.write.approve([dex.address, amountA2], {
        account: user2.account,
      });
      await tokenB.write.approve([dex.address, amountB2], {
        account: user2.account,
      });
      await dex.write.addLiquidity([amountA2, amountB2], {
        account: user2.account,
      });

      // Check total reserves
      const [reserveA, reserveB] = await dex.read.getReserves();
      assert.equal(reserveA, amountA1 + amountA2);
      assert.equal(reserveB, amountB1 + amountB2);
    });

    it('Should remove liquidity correctly', async function () {
      // Add liquidity first
      const amountA = parseEther('1000');
      const amountB = parseEther('2000');

      await tokenA.write.approve([dex.address, amountA], {
        account: user1.account,
      });
      await tokenB.write.approve([dex.address, amountB], {
        account: user1.account,
      });
      await dex.write.addLiquidity([amountA, amountB], {
        account: user1.account,
      });

      const userLiquidity = await dex.read.liquidity([user1.account.address]);
      const balanceABefore = await tokenA.read.balanceOf([user1.account.address]);
      const balanceBBefore = await tokenB.read.balanceOf([user1.account.address]);

      // Remove half liquidity
      const liquidityToRemove = userLiquidity / 2n;
      await dex.write.removeLiquidity([liquidityToRemove], {
        account: user1.account,
      });

      const balanceAAfter = await tokenA.read.balanceOf([user1.account.address]);
      const balanceBAfter = await tokenB.read.balanceOf([user1.account.address]);

      // Check balances increased
      assert(balanceAAfter > balanceABefore);
      assert(balanceBAfter > balanceBBefore);
    });
  });

  describe('Token Swapping', function () {
    beforeEach(async function () {
      // Add initial liquidity
      const amountA = parseEther('1000');
      const amountB = parseEther('2000');

      await tokenA.write.approve([dex.address, amountA], {
        account: user1.account,
      });
      await tokenB.write.approve([dex.address, amountB], {
        account: user1.account,
      });
      await dex.write.addLiquidity([amountA, amountB], {
        account: user1.account,
      });
    });

    it('Should swap Token A for Token B', async function () {
      const swapAmount = parseEther('100');
      const balanceBBefore = await tokenB.read.balanceOf([user2.account.address]);

      // Get quote
      const expectedOut = await dex.read.getSwapQuoteAForB([swapAmount]);
      assert(expectedOut > 0n);

      // Approve and swap
      await tokenA.write.approve([dex.address, swapAmount], {
        account: user2.account,
      });
      await dex.write.swapAForB([swapAmount, 1n], {
        account: user2.account,
      });

      const balanceBAfter = await tokenB.read.balanceOf([user2.account.address]);
      const received = balanceBAfter - balanceBBefore;

      assert(received > 0n);
      // Should be close to expected (accounting for precision)
      assert(received >= (expectedOut * 99n) / 100n); // Allow 1% tolerance
    });

    it('Should swap Token B for Token A', async function () {
      const swapAmount = parseEther('200');
      const balanceABefore = await tokenA.read.balanceOf([user2.account.address]);

      // Get quote
      const expectedOut = await dex.read.getSwapQuoteBForA([swapAmount]);
      assert(expectedOut > 0n);

      // Approve and swap
      await tokenB.write.approve([dex.address, swapAmount], {
        account: user2.account,
      });
      await dex.write.swapBForA([swapAmount, 1n], {
        account: user2.account,
      });

      const balanceAAfter = await tokenA.read.balanceOf([user2.account.address]);
      const received = balanceAAfter - balanceABefore;

      assert(received > 0n);
      // Should be close to expected (accounting for precision)
      assert(received >= (expectedOut * 99n) / 100n); // Allow 1% tolerance
    });

    it('Should maintain price relationship after swaps', async function () {
      const initialPrice = await dex.read.getPrice();

      // Perform multiple small swaps
      const swapAmount = parseEther('10');

      await tokenA.write.approve([dex.address, swapAmount * 3n], {
        account: user2.account,
      });

      // Swap A for B multiple times (should increase price)
      await dex.write.swapAForB([swapAmount, 1n], { account: user2.account });
      await dex.write.swapAForB([swapAmount, 1n], { account: user2.account });
      await dex.write.swapAForB([swapAmount, 1n], { account: user2.account });

      const finalPrice = await dex.read.getPrice();

      // Price should have decreased (Token B became more scarce)
      assert(finalPrice < initialPrice);
    });
  });

  describe('Price Quotes', function () {
    beforeEach(async function () {
      // Add liquidity
      const amountA = parseEther('1000');
      const amountB = parseEther('2000');

      await tokenA.write.approve([dex.address, amountA], {
        account: user1.account,
      });
      await tokenB.write.approve([dex.address, amountB], {
        account: user1.account,
      });
      await dex.write.addLiquidity([amountA, amountB], {
        account: user1.account,
      });
    });

    it('Should provide accurate swap quotes', async function () {
      const swapAmount = parseEther('100');

      const quoteAForB = await dex.read.getSwapQuoteAForB([swapAmount]);
      const quoteBForA = await dex.read.getSwapQuoteBForA([swapAmount]);

      assert(quoteAForB > 0n);
      assert(quoteBForA > 0n);
    });

    it('Should show current price ratio', async function () {
      const price = await dex.read.getPrice();
      assert(price > 0n);

      // With 1000 A and 2000 B, price should be around 2 * 1e18
      const expectedPrice = 2n * 10n ** 18n;
      const tolerance = expectedPrice / 100n; // 1% tolerance

      assert(price >= expectedPrice - tolerance);
      assert(price <= expectedPrice + tolerance);
    });
  });
});
