#!/usr/bin/env tsx
// CLI for mainnet prover reward pipeline
//
// Commands:
//   status    — Check prover health, balances, timelock
//   quote     — Get profitability quote for current unclaimed epochs
//   claim     — Run one claim cycle (check + submit if profitable)
//   daemon    — Run continuous claim daemon
//   monitor   — Run continuous monitoring loop
//   price     — Show current AZTEC/ETH price

import { DEFAULTS } from './config.js';
import { getProverStatus, printStatus, runMonitor } from './monitor.js';
import { getUnclaimedEpochs, selectEpochBatch } from './epochs.js';
import { getAztecEthPrice, quoteProfitability, formatQuote } from './price.js';
import { submitClaimBundle } from './bundle.js';
import { runClaimDaemon, defaultConfig } from './claim-daemon.js';
import { parseEther, formatEther } from 'viem';

const USAGE = `
Usage: tsx src/cli.ts <command> [options]

Commands:
  status                  Check prover health, balances, and timelock status
  price                   Show current AZTEC/ETH price from Uniswap V4
  quote                   Estimate profitability of claiming current unclaimed epochs
  claim [--dry-run]       Run one claim cycle (submit bundle if profitable)
  daemon [--dry-run]      Run continuous claim daemon
  monitor                 Run continuous monitoring loop (balance, timelock, health)

Environment variables:
  PROVER_PRIVATE_KEY      Prover wallet private key (0x-prefixed)
  PROVER_ADDRESS          Prover wallet address
  BATCHER_ADDRESS         Deployed ProverBatcher contract address
  MIN_PROFIT_ETH          Minimum profit threshold (default: ${DEFAULTS.minProfitEth})
  MIN_EPOCH_BATCH         Minimum epochs to batch (default: ${DEFAULTS.minEpochBatch})
  MAX_EPOCH_BATCH         Maximum epochs per claim (default: ${DEFAULTS.maxEpochBatch})
  BUILDER_PAYMENT_ETH         Flashbots builder tip (default: ${DEFAULTS.builderPaymentEth})
  SLIPPAGE_BPS            Swap slippage in bps (default: ${DEFAULTS.slippageBps})
  CLAIM_INTERVAL_MS       Claim check interval (default: ${DEFAULTS.claimCheckIntervalMs})
  MONITOR_INTERVAL_MS     Monitor poll interval (default: ${DEFAULTS.monitorIntervalMs})
`;

function requireEnv(name: string): string {
  const val = process.env[name];
  if (!val) {
    console.error(`ERROR: ${name} is required. Set it in your environment or .secrets/prover-wallet.env`);
    process.exit(1);
  }
  return val;
}

function getAddress(): `0x${string}` {
  return requireEnv('PROVER_ADDRESS') as `0x${string}`;
}

function getPrivateKey(): `0x${string}` {
  return requireEnv('PROVER_PRIVATE_KEY') as `0x${string}`;
}

function getBatcherAddress(): `0x${string}` {
  return requireEnv('BATCHER_ADDRESS') as `0x${string}`;
}

function getOverrides() {
  return {
    minProfitEth: parseFloat(process.env.MIN_PROFIT_ETH ?? String(DEFAULTS.minProfitEth)),
    builderPaymentEth: parseFloat(process.env.BUILDER_PAYMENT_ETH ?? String(DEFAULTS.builderPaymentEth)),
    slippageBps: parseInt(process.env.SLIPPAGE_BPS ?? String(DEFAULTS.slippageBps)),
  };
}

async function main() {
  const command = process.argv[2];
  const flags = process.argv.slice(3);
  const dryRun = flags.includes('--dry-run');

  switch (command) {
    case 'status': {
      const status = await getProverStatus(getAddress());
      printStatus(status);
      break;
    }

    case 'price': {
      const price = await getAztecEthPrice();
      console.log(`AZTEC/ETH: ${price.toFixed(10)}`);
      console.log(`4,800 AZTEC (1 epoch prover pool) = ${(4800 * price).toFixed(6)} ETH`);
      console.log(`48,000 AZTEC (10 epochs) = ${(48000 * price).toFixed(6)} ETH`);
      break;
    }

    case 'quote': {
      const address = getAddress();
      const batcher = getBatcherAddress();
      console.log('Scanning for unclaimed epochs...');
      const unclaimed = await getUnclaimedEpochs(address, batcher);
      console.log(`Found ${unclaimed.length} unclaimed epochs.`);

      if (unclaimed.length === 0) {
        console.log('Nothing to claim.');
        break;
      }

      const batch = selectEpochBatch(unclaimed, 1, DEFAULTS.maxEpochBatch) ?? unclaimed;
      const estimatedAztec = parseEther('4800') * BigInt(batch.length);
      const quote = await quoteProfitability(estimatedAztec, getOverrides());

      console.log(`\nQuote for ${batch.length} epochs (~${formatEther(estimatedAztec)} AZTEC):`);
      console.log(formatQuote(quote));
      break;
    }

    case 'claim': {
      const result = await submitClaimBundle(
        getPrivateKey(),
        getBatcherAddress(),
        await getClaimBatch(),
        { ...getOverrides(), dryRun },
      );
      process.exit(result.success ? 0 : 1);
      break;
    }

    case 'daemon': {
      await runClaimDaemon({
        ...defaultConfig,
        ...getOverrides(),
        privateKey: getPrivateKey(),
        proverAddress: getAddress(),
        batcherAddress: getBatcherAddress(),
        minEpochBatch: parseInt(process.env.MIN_EPOCH_BATCH ?? String(DEFAULTS.minEpochBatch)),
        maxEpochBatch: parseInt(process.env.MAX_EPOCH_BATCH ?? String(DEFAULTS.maxEpochBatch)),
        checkIntervalMs: parseInt(process.env.CLAIM_INTERVAL_MS ?? String(DEFAULTS.claimCheckIntervalMs)),
        dryRun,
      });
      break;
    }

    case 'monitor': {
      const intervalMs = parseInt(process.env.MONITOR_INTERVAL_MS ?? String(DEFAULTS.monitorIntervalMs));
      await runMonitor(getAddress(), intervalMs);
      break;
    }

    default:
      console.log(USAGE);
      process.exit(command ? 1 : 0);
  }
}

async function getClaimBatch(): Promise<bigint[]> {
  const address = getAddress();
  const batcher = getBatcherAddress();
  const minBatch = parseInt(process.env.MIN_EPOCH_BATCH ?? String(DEFAULTS.minEpochBatch));

  console.log('Scanning for unclaimed epochs...');
  const unclaimed = await getUnclaimedEpochs(address, batcher);

  if (unclaimed.length === 0) {
    console.log('No unclaimed epochs found.');
    process.exit(0);
  }

  const batch = selectEpochBatch(unclaimed, minBatch, DEFAULTS.maxEpochBatch);
  if (!batch) {
    console.log(`Only ${unclaimed.length} epochs — need ${minBatch} minimum.`);
    process.exit(0);
    throw new Error('unreachable'); // satisfy TS control flow
  }

  return batch;
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
