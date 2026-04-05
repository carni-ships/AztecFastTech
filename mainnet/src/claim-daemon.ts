// Claim daemon: periodically checks for unclaimed epochs and submits profitable bundles

import { formatEther, parseEther } from 'viem';
import { DEFAULTS } from './config.js';
import { getProverStatus } from './monitor.js';
import { getUnclaimedEpochs, selectEpochBatch } from './epochs.js';
import { submitClaimBundle, type BundleResult } from './bundle.js';
import { quoteProfitability, formatQuote } from './price.js';

export interface ClaimDaemonConfig {
  privateKey: `0x${string}`;
  proverAddress: `0x${string}`;
  batcherAddress: `0x${string}`;
  minProfitEth: number;
  builderTipEth: number;
  slippageBps: number;
  minEpochBatch: number;
  maxEpochBatch: number;
  checkIntervalMs: number;
  dryRun: boolean;
}

const defaultConfig: Omit<ClaimDaemonConfig, 'privateKey' | 'proverAddress' | 'batcherAddress'> = {
  minProfitEth: DEFAULTS.minProfitEth,
  builderTipEth: DEFAULTS.builderTipEth,
  slippageBps: DEFAULTS.slippageBps,
  minEpochBatch: DEFAULTS.minEpochBatch,
  maxEpochBatch: DEFAULTS.maxEpochBatch,
  checkIntervalMs: DEFAULTS.claimCheckIntervalMs,
  dryRun: false,
};

export async function runClaimDaemon(config: ClaimDaemonConfig): Promise<never> {
  console.log('=== Claim Daemon Started ===');
  console.log(`  Prover:       ${config.proverAddress}`);
  console.log(`  Batcher:      ${config.batcherAddress}`);
  console.log(`  Min profit:   ${config.minProfitEth} ETH`);
  console.log(`  Min batch:    ${config.minEpochBatch} epochs`);
  console.log(`  Check every:  ${config.checkIntervalMs / 1000}s`);
  console.log(`  Dry run:      ${config.dryRun}`);
  console.log('');

  let consecutiveErrors = 0;

  while (true) {
    try {
      // 1. Check if rewards are claimable
      const status = await getProverStatus(config.proverAddress);

      if (!status.rewardsClaimable) {
        console.log(`[${ts()}] Rewards locked (90-day timelock). Waiting...`);
        await sleep(config.checkIntervalMs);
        continue;
      }

      if (status.lowEth) {
        console.log(`[${ts()}] WARNING: Low ETH (${status.ethBalanceFormatted}). Skipping claim cycle.`);
        await sleep(config.checkIntervalMs);
        continue;
      }

      // 2. Find unclaimed epochs
      console.log(`[${ts()}] Scanning for unclaimed epochs...`);
      const unclaimed = await getUnclaimedEpochs(
        config.proverAddress,
        config.batcherAddress,
      );

      if (unclaimed.length === 0) {
        console.log(`[${ts()}] No unclaimed epochs found.`);
        await sleep(config.checkIntervalMs);
        continue;
      }

      console.log(`[${ts()}] Found ${unclaimed.length} unclaimed epochs: ${unclaimed.slice(0, 5).join(', ')}${unclaimed.length > 5 ? '...' : ''}`);

      // 3. Select batch
      const batch = selectEpochBatch(unclaimed, config.minEpochBatch, config.maxEpochBatch);

      if (!batch) {
        console.log(`[${ts()}] Only ${unclaimed.length} epochs — need ${config.minEpochBatch} minimum. Accumulating...`);
        await sleep(config.checkIntervalMs);
        continue;
      }

      // 4. Quick profitability pre-check before submitting
      const estimatedAztec = parseEther('150') * BigInt(batch.length);
      const quote = await quoteProfitability(estimatedAztec, {
        minProfitEth: config.minProfitEth,
        builderTipEth: config.builderTipEth,
        slippageBps: config.slippageBps,
      });

      if (!quote.profitable) {
        console.log(`[${ts()}] Not profitable at current prices:`);
        console.log(formatQuote(quote));
        console.log(`  Deferring claim. Will retry with more epochs next cycle.`);
        await sleep(config.checkIntervalMs);
        continue;
      }

      // 5. Submit bundle
      console.log(`[${ts()}] Submitting claim for ${batch.length} epochs...`);
      const result = await submitClaimBundle(config.privateKey, config.batcherAddress, batch, {
        minProfitEth: config.minProfitEth,
        builderTipEth: config.builderTipEth,
        slippageBps: config.slippageBps,
        dryRun: config.dryRun,
      });

      if (result.success) {
        console.log(`[${ts()}] Claim successful! tx: ${result.txHash ?? 'dry-run'}`);
        console.log(`  Net profit: ${formatEther(result.quote?.netProfit ?? 0n)} ETH`);
        console.log(`  Via: ${result.submittedVia}`);
      } else {
        console.log(`[${ts()}] Claim failed: ${result.error}`);
      }

      consecutiveErrors = 0;
    } catch (err) {
      consecutiveErrors++;
      const msg = err instanceof Error ? err.message : String(err);
      console.error(`[${ts()}] Error: ${msg.slice(0, 200)}`);

      // Back off on repeated errors
      if (consecutiveErrors > 3) {
        const backoff = Math.min(consecutiveErrors * 30_000, 300_000);
        console.log(`  Backing off ${backoff / 1000}s (${consecutiveErrors} consecutive errors)`);
        await sleep(backoff);
        continue;
      }
    }

    await sleep(config.checkIntervalMs);
  }
}

function ts(): string {
  return new Date().toISOString().replace('T', ' ').slice(0, 19);
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export { defaultConfig };
