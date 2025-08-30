import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { parseEther } from 'viem';

import { network } from 'hardhat';

describe('MyToken', async function () {
  const { viem } = await network.connect();
  const TOKEN_NAME = 'MyToken';
  const TOKEN_SYMBOL = 'MTK';
  const TOKEN_DECIMALS = 18;
  const INITIAL_SUPPLY = 1000000n; // 1 million tokens

  it('Should deploy with correct parameters', async function () {
    const token = await viem.deployContract('MyToken', [
      TOKEN_NAME,
      TOKEN_SYMBOL,
      TOKEN_DECIMALS,
      INITIAL_SUPPLY,
    ]);

    assert.equal(await token.read.name(), TOKEN_NAME);
    assert.equal(await token.read.symbol(), TOKEN_SYMBOL);
    assert.equal(await token.read.decimals(), TOKEN_DECIMALS);

    const expectedTotalSupply = INITIAL_SUPPLY * 10n ** BigInt(TOKEN_DECIMALS);
    const totalSupply = await token.read.totalSupply();
    assert.equal(totalSupply, expectedTotalSupply);
  });

  it('Should transfer tokens between accounts', async function () {
    const [owner, addr1] = await viem.getWalletClients();
    const token = await viem.deployContract('MyToken', [
      TOKEN_NAME,
      TOKEN_SYMBOL,
      TOKEN_DECIMALS,
      INITIAL_SUPPLY,
    ]);

    const transferAmount = parseEther('50');

    // Transfer 50 tokens from owner to addr1
    await token.write.transfer([addr1.account.address, transferAmount], {
      account: owner.account,
    });

    const addr1Balance = await token.read.balanceOf([addr1.account.address]);
    assert.equal(addr1Balance, transferAmount);
  });
});
