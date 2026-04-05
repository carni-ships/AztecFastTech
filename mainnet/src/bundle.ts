// Flashbots bundle construction and submission
// Falls back to MEV Blocker if Flashbots fails

import {
  createPublicClient,
  createWalletClient,
  http,
  encodeFunctionData,
  formatEther,
  parseEther,
} from 'viem';
import { mainnet } from 'viem/chains';
import { privateKeyToAccount } from 'viem/accounts';
import { ADDRESSES, RPC_ENDPOINTS, DEFAULTS } from './config.js';
import { proverBatcherAbi } from './abis.js';
import { quoteProfitability, formatQuote, type PriceQuote } from './price.js';

export interface BundleResult {
  success: boolean;
  txHash?: `0x${string}`;
  quote?: PriceQuote;
  error?: string;
  submittedVia?: string;
}

/// Build and submit a claim+sell bundle via private mempool
export async function submitClaimBundle(
  privateKey: `0x${string}`,
  batcherAddress: `0x${string}`,
  epochs: bigint[],
  overrides?: {
    minProfitEth?: number;
    builderTipEth?: number;
    slippageBps?: number;
    dryRun?: boolean;
  },
): Promise<BundleResult> {
  const account = privateKeyToAccount(privateKey);
  const dryRun = overrides?.dryRun ?? false;

  // 1. Estimate total AZTEC rewards for this batch
  //    32 checkpoints × 500 AZTEC × 30% prover share = 4,800 AZTEC per epoch
  //    (verified from RollupConfiguration.sol:73-74)
  //    Actual share depends on activity score and number of competing provers
  const estimatedAztecPerEpoch = parseEther('4800');
  const totalAztecEstimate = estimatedAztecPerEpoch * BigInt(epochs.length);

  // 2. Get profitability quote
  const quote = await quoteProfitability(totalAztecEstimate, overrides);

  console.log(`\nProfitability check for ${epochs.length} epochs:`);
  console.log(formatQuote(quote));

  if (!quote.profitable) {
    return {
      success: false,
      quote,
      error: `Not profitable: net ${formatEther(quote.netProfit)} ETH (need ${formatEther(parseEther(String(overrides?.minProfitEth ?? DEFAULTS.minProfitEth)))})`,
    };
  }

  if (dryRun) {
    console.log('\n[DRY RUN] Would submit bundle — skipping.');
    return { success: true, quote, submittedVia: 'dry-run' };
  }

  // 3. Build the claimAndSell transaction
  const calldata = encodeFunctionData({
    abi: proverBatcherAbi,
    functionName: 'claimAndSell',
    args: [epochs, quote.minEthOut, parseEther(String(overrides?.minProfitEth ?? DEFAULTS.minProfitEth)), quote.builderTip],
  });

  // 4. Try each private RPC endpoint
  for (const rpcUrl of RPC_ENDPOINTS.private) {
    try {
      console.log(`\nSubmitting via ${new URL(rpcUrl).hostname}...`);

      const walletClient = createWalletClient({
        account,
        chain: mainnet,
        transport: http(rpcUrl),
      });

      const publicClient = createPublicClient({
        chain: mainnet,
        transport: http(RPC_ENDPOINTS.public[0]),
      });

      // Get nonce and gas estimate from public RPC
      const [nonce, gasPrice] = await Promise.all([
        publicClient.getTransactionCount({ address: account.address }),
        publicClient.getGasPrice(),
      ]);

      const txHash = await walletClient.sendTransaction({
        to: batcherAddress,
        data: calldata,
        gas: DEFAULTS.gasEstimate,
        maxFeePerGas: gasPrice * 2n, // 2x buffer for inclusion
        maxPriorityFeePerGas: gasPrice / 10n, // low priority — builder tip is the real payment
        nonce,
      });

      console.log(`  Submitted: ${txHash}`);

      // Wait for confirmation
      const receipt = await publicClient.waitForTransactionReceipt({
        hash: txHash,
        timeout: 120_000, // 2 minutes
      });

      if (receipt.status === 'success') {
        console.log(`  Confirmed in block ${receipt.blockNumber}`);
        return {
          success: true,
          txHash,
          quote,
          submittedVia: new URL(rpcUrl).hostname,
        };
      } else {
        console.log(`  Reverted in block ${receipt.blockNumber}`);
        return {
          success: false,
          txHash,
          quote,
          error: 'Transaction reverted on-chain',
          submittedVia: new URL(rpcUrl).hostname,
        };
      }
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      console.log(`  Failed: ${msg.slice(0, 120)}`);
      continue; // Try next RPC
    }
  }

  return {
    success: false,
    quote,
    error: 'All private RPC endpoints failed',
  };
}
