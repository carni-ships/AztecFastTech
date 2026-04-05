// Flashbots bundle construction and submission via relay API
//
// Pattern: gasPrice=0 tx → contract pays builder via coinbase.transfer from swap proceeds
// On revert: zero cost (bundle not included, no gas paid)
// Targets all major builders for ~95% block coverage

import {
  createPublicClient,
  createWalletClient,
  http,
  encodeFunctionData,
  formatEther,
  parseEther,
  serializeTransaction,
  keccak256,
  type TransactionSerializable,
  type Hex,
} from 'viem';
import { mainnet } from 'viem/chains';
import { privateKeyToAccount, signTransaction } from 'viem/accounts';
import { ADDRESSES, RPC_ENDPOINTS, DEFAULTS } from './config.js';
import { proverBatcherAbi } from './abis.js';
import { quoteProfitability, formatQuote, type PriceQuote } from './price.js';

export interface BundleResult {
  success: boolean;
  bundleHash?: string;
  txHash?: Hex;
  quote?: PriceQuote;
  error?: string;
  targetBlock?: bigint;
}

// Flashbots relay requires a signing key for bundle authentication
// This can be any key — it's just for identifying the searcher, not for tx signing
function getFlashbotsAuthKey(): `0x${string}` {
  // Use the prover key as auth key (Flashbots just uses it for identity/rate limiting)
  return (process.env.PROVER_PRIVATE_KEY || process.env.FLASHBOTS_AUTH_KEY) as `0x${string}`;
}

/// Sign a Flashbots bundle payload for relay authentication
async function flashbotsSign(payload: string, authKey: `0x${string}`): Promise<string> {
  const account = privateKeyToAccount(authKey);
  const message = keccak256(`0x${Buffer.from(payload).toString('hex')}`);
  const signature = await account.signMessage({ message: { raw: message } });
  return `${account.address}:${signature}`;
}

/// Send a bundle to the Flashbots relay
async function sendBundle(
  signedTxs: Hex[],
  targetBlock: bigint,
  authKey: `0x${string}`,
): Promise<{ bundleHash?: string; error?: string }> {
  const blockHex = `0x${targetBlock.toString(16)}`;

  const params = {
    jsonrpc: '2.0',
    id: 1,
    method: 'eth_sendBundle',
    params: [{
      txs: signedTxs,
      blockNumber: blockHex,
      // Target all major builders for max inclusion probability
      // Flashbots builder is included by default
      builders: DEFAULTS.builders,
    }],
  };

  const body = JSON.stringify(params);
  const signature = await flashbotsSign(body, authKey);

  const response = await fetch(RPC_ENDPOINTS.flashbotsRelay, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Flashbots-Signature': signature,
    },
    body,
  });

  const result = await response.json() as any;

  if (result.error) {
    return { error: result.error.message || JSON.stringify(result.error) };
  }

  return { bundleHash: result.result?.bundleHash };
}

/// Simulate a bundle via Flashbots (free, catches reverts before submission)
async function simulateBundle(
  signedTxs: Hex[],
  targetBlock: bigint,
  authKey: `0x${string}`,
): Promise<{ success: boolean; error?: string; gasUsed?: bigint; coinbaseDiff?: bigint }> {
  const blockHex = `0x${targetBlock.toString(16)}`;

  const params = {
    jsonrpc: '2.0',
    id: 1,
    method: 'eth_callBundle',
    params: [{
      txs: signedTxs,
      blockNumber: blockHex,
      stateBlockNumber: 'latest',
    }],
  };

  const body = JSON.stringify(params);
  const signature = await flashbotsSign(body, authKey);

  const response = await fetch(RPC_ENDPOINTS.flashbotsRelay, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Flashbots-Signature': signature,
    },
    body,
  });

  const result = await response.json() as any;

  if (result.error) {
    return { success: false, error: result.error.message || JSON.stringify(result.error) };
  }

  const bundleResult = result.result;
  if (bundleResult?.results?.[0]?.error) {
    return { success: false, error: bundleResult.results[0].error };
  }

  return {
    success: true,
    gasUsed: bundleResult?.totalGasUsed ? BigInt(bundleResult.totalGasUsed) : undefined,
    coinbaseDiff: bundleResult?.coinbaseDiff ? BigInt(bundleResult.coinbaseDiff) : undefined,
  };
}

/// Build, simulate, and submit a claim+sell bundle
export async function submitClaimBundle(
  privateKey: `0x${string}`,
  batcherAddress: `0x${string}`,
  epochs: bigint[],
  overrides?: {
    minProfitEth?: number;
    builderPaymentEth?: number;
    slippageBps?: number;
    dryRun?: boolean;
  },
): Promise<BundleResult> {
  const account = privateKeyToAccount(privateKey);
  const dryRun = overrides?.dryRun ?? false;

  const publicClient = createPublicClient({
    chain: mainnet,
    transport: http(RPC_ENDPOINTS.public[0]),
  });

  // 1. Estimate rewards and check profitability
  //    32 checkpoints × 500 AZTEC × 30% prover = 4,800 AZTEC per epoch
  const estimatedAztecPerEpoch = parseEther('4800');
  const totalAztecEstimate = estimatedAztecPerEpoch * BigInt(epochs.length);

  const quote = await quoteProfitability(totalAztecEstimate, overrides);

  console.log(`\nProfitability check for ${epochs.length} epochs:`);
  console.log(formatQuote(quote));

  if (!quote.profitable) {
    return {
      success: false,
      quote,
      error: `Not profitable: net ${formatEther(quote.netProfit)} ETH`,
    };
  }

  // 2. Build the claimAndSell calldata
  const builderPayment = parseEther(String(overrides?.builderPaymentEth ?? DEFAULTS.builderPaymentEth));
  const minOperatorProfit = parseEther(String(overrides?.minProfitEth ?? DEFAULTS.minProfitEth));

  const calldata = encodeFunctionData({
    abi: proverBatcherAbi,
    functionName: 'claimAndSell',
    args: [epochs, quote.minEthOut, builderPayment, minOperatorProfit],
  });

  // 3. Build the transaction with gasPrice=0
  //    Builder is paid via coinbase.transfer from swap proceeds, not via gas fee
  const nonce = await publicClient.getTransactionCount({ address: account.address });
  const currentBlock = await publicClient.getBlockNumber();

  const tx: TransactionSerializable = {
    to: batcherAddress,
    data: calldata,
    gas: DEFAULTS.gasEstimate,
    maxFeePerGas: 0n,          // Zero gas price — builder paid via coinbase.transfer
    maxPriorityFeePerGas: 0n,  // Zero priority — all payment via coinbase
    nonce,
    chainId: 1,
    type: 'eip1559',
  };

  // 4. Sign the transaction
  const walletClient = createWalletClient({
    account,
    chain: mainnet,
    transport: http(RPC_ENDPOINTS.public[0]),
  });

  const serialized = await walletClient.signTransaction(tx);

  if (dryRun) {
    console.log('\n[DRY RUN] Would submit bundle — skipping.');
    console.log(`  Target blocks: ${currentBlock + 1n}, ${currentBlock + 2n}`);
    console.log(`  Builder payment: ${formatEther(builderPayment)} ETH`);
    console.log(`  Min operator profit: ${formatEther(minOperatorProfit)} ETH`);
    return { success: true, quote, targetBlock: currentBlock + 1n };
  }

  // 5. Simulate the bundle first (free, catches reverts)
  const authKey = getFlashbotsAuthKey();
  console.log('\nSimulating bundle...');
  const sim = await simulateBundle([serialized], currentBlock + 1n, authKey);

  if (!sim.success) {
    console.log(`  Simulation failed: ${sim.error}`);
    return { success: false, quote, error: `Simulation failed: ${sim.error}` };
  }

  console.log(`  Simulation OK — gas: ${sim.gasUsed}, coinbaseDiff: ${sim.coinbaseDiff}`);

  // 6. Submit to block+1 AND block+2 for higher inclusion probability
  console.log('\nSubmitting bundle to all builders...');
  const targets = [currentBlock + 1n, currentBlock + 2n];
  const results = await Promise.all(
    targets.map(block => sendBundle([serialized], block, authKey)),
  );

  for (let i = 0; i < results.length; i++) {
    const r = results[i];
    if (r.error) {
      console.log(`  Block ${targets[i]}: ERROR — ${r.error}`);
    } else {
      console.log(`  Block ${targets[i]}: submitted (hash: ${r.bundleHash})`);
    }
  }

  // 7. Wait for inclusion
  const successResult = results.find(r => r.bundleHash);
  if (!successResult) {
    return { success: false, quote, error: 'All bundle submissions failed' };
  }

  console.log('\nWaiting for inclusion (up to 2 blocks)...');
  try {
    // Poll for the tx to appear on-chain
    for (let attempt = 0; attempt < 6; attempt++) {
      await new Promise(r => setTimeout(r, 15_000)); // ~1 block
      const block = await publicClient.getBlockNumber();
      if (block > currentBlock + 2n) {
        // Check if our tx landed
        const receipt = await publicClient.getTransactionReceipt({ hash: keccak256(serialized) }).catch(() => null);
        if (receipt) {
          console.log(`  Included in block ${receipt.blockNumber}!`);
          return {
            success: receipt.status === 'success',
            bundleHash: successResult.bundleHash,
            txHash: receipt.transactionHash,
            quote,
            targetBlock: receipt.blockNumber,
          };
        }
      }
    }
    console.log('  Bundle not included in target blocks (may retry next cycle).');
    return { success: false, quote, bundleHash: successResult.bundleHash, error: 'Not included in target blocks' };
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return { success: false, quote, error: msg };
  }
}
