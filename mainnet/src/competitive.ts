// Competitive intelligence: track other provers' submission timing and estimate
// when they'll submit for the current/next epoch.
//
// Key insight: the dominant prover (0xa5c7...2705) submits every ~38.4 min
// (exactly 1 epoch). They use streaming/pipelined proving — starting proofs
// on early checkpoints while the epoch is still in progress. To compete,
// we either need to prove faster or co-submit within the same epoch (shared rewards).

import { createPublicClient, http, parseAbiItem, formatEther } from 'viem';
import { mainnet } from 'viem/chains';
import { ADDRESSES, RPC_ENDPOINTS, PROTOCOL } from './config.js';

function getPublicClient() {
  return createPublicClient({
    chain: mainnet,
    transport: http(RPC_ENDPOINTS.public[0]),
  });
}

const submitEpochRootEvent = parseAbiItem(
  'event L2ProofVerified(uint256 indexed blockNumber, address indexed proverId)',
);

export interface ProverSubmission {
  proverId: `0x${string}`;
  l2BlockNumber: bigint;
  epoch: bigint;
  l1BlockNumber: bigint;
  l1Timestamp: bigint;
  txHash: `0x${string}`;
}

export interface ProverProfile {
  address: `0x${string}`;
  submissions: ProverSubmission[];
  avgIntervalSec: number;
  minIntervalSec: number;
  maxIntervalSec: number;
  avgProvingLatencySec: number; // time after epoch end to submission
  submissionsPerDay: number;
  lastSubmissionTimestamp: bigint;
  estimatedNextSubmissionSec: number; // seconds from now
}

/// Fetch recent proof submissions from L1 events
export async function getRecentSubmissions(
  lookbackBlocks: bigint = 7200n, // ~24 hours of L1 blocks
): Promise<ProverSubmission[]> {
  const client = getPublicClient();
  const currentBlock = await client.getBlockNumber();
  const fromBlock = currentBlock > lookbackBlocks ? currentBlock - lookbackBlocks : 0n;

  const logs = await client.getLogs({
    address: ADDRESSES.rollup,
    event: submitEpochRootEvent,
    fromBlock,
    toBlock: 'latest',
  });

  // Get block timestamps for each log
  const uniqueBlocks = [...new Set(logs.map(l => l.blockNumber))];
  const blockTimestamps = new Map<bigint, bigint>();

  // Batch fetch block timestamps (max 10 concurrent)
  for (let i = 0; i < uniqueBlocks.length; i += 10) {
    const batch = uniqueBlocks.slice(i, i + 10);
    const blocks = await Promise.all(
      batch.map(bn => client.getBlock({ blockNumber: bn })),
    );
    for (const block of blocks) {
      blockTimestamps.set(block.number, block.timestamp);
    }
  }

  return logs.map(log => ({
    proverId: log.args.proverId!,
    l2BlockNumber: log.args.blockNumber!,
    epoch: log.args.blockNumber! / BigInt(PROTOCOL.slotsPerEpoch),
    l1BlockNumber: log.blockNumber,
    l1Timestamp: blockTimestamps.get(log.blockNumber) ?? 0n,
    txHash: log.transactionHash,
  }));
}

/// Build a profile for a specific prover based on their submission history
export function buildProverProfile(
  address: `0x${string}`,
  submissions: ProverSubmission[],
): ProverProfile {
  const proverSubs = submissions
    .filter(s => s.proverId.toLowerCase() === address.toLowerCase())
    .sort((a, b) => Number(a.l1Timestamp - b.l1Timestamp));

  // Calculate intervals between consecutive submissions
  const intervals: number[] = [];
  for (let i = 1; i < proverSubs.length; i++) {
    const delta = Number(proverSubs[i].l1Timestamp - proverSubs[i - 1].l1Timestamp);
    intervals.push(delta);
  }

  const avgInterval = intervals.length > 0
    ? intervals.reduce((a, b) => a + b, 0) / intervals.length
    : PROTOCOL.epochDurationSec;

  const minInterval = intervals.length > 0 ? Math.min(...intervals) : 0;
  const maxInterval = intervals.length > 0 ? Math.max(...intervals) : 0;

  // Estimate proving latency: interval - epoch_duration = time spent proving after epoch ends
  // If interval ≈ epoch_duration, prover is streaming (starts during epoch)
  const avgLatency = Math.max(0, avgInterval - PROTOCOL.epochDurationSec);

  const lastTs = proverSubs.length > 0
    ? proverSubs[proverSubs.length - 1].l1Timestamp
    : 0n;

  // Estimate when they'll submit next
  const nowSec = Math.floor(Date.now() / 1000);
  const secSinceLast = nowSec - Number(lastTs);
  const estimatedNext = Math.max(0, avgInterval - secSinceLast);

  return {
    address,
    submissions: proverSubs,
    avgIntervalSec: avgInterval,
    minIntervalSec: minInterval,
    maxIntervalSec: maxInterval,
    avgProvingLatencySec: avgLatency,
    submissionsPerDay: 86400 / avgInterval,
    lastSubmissionTimestamp: lastTs,
    estimatedNextSubmissionSec: estimatedNext,
  };
}

/// Get profiles for all active provers
export async function getAllProverProfiles(
  lookbackBlocks?: bigint,
): Promise<ProverProfile[]> {
  const submissions = await getRecentSubmissions(lookbackBlocks);

  // Group by prover
  const provers = new Set(submissions.map(s => s.proverId.toLowerCase() as `0x${string}`));
  const profiles = [...provers].map(addr => buildProverProfile(addr, submissions));

  // Sort by submission count (most active first)
  profiles.sort((a, b) => b.submissions.length - a.submissions.length);

  return profiles;
}

/// Estimate the current epoch and when it ends
export function getCurrentEpochInfo(): {
  currentEpoch: number;
  epochEndTimestamp: number;
  secondsUntilEnd: number;
  proofDeadlineTimestamp: number;
  secondsUntilDeadline: number;
} {
  // We don't have the exact genesis timestamp, but we can estimate from
  // the dominant prover's submission pattern. For a more accurate version,
  // query the rollup contract's getCurrentEpoch().
  const nowSec = Math.floor(Date.now() / 1000);
  const epochDur = PROTOCOL.epochDurationSec;

  // Approximate: current epoch ≈ time / epoch_duration (modular)
  // This is a rough estimate — for production, read from the rollup contract
  const currentEpoch = Math.floor(nowSec / epochDur);
  const epochStart = currentEpoch * epochDur;
  const epochEnd = epochStart + epochDur;
  const proofDeadline = epochEnd + PROTOCOL.proofWindowSec;

  return {
    currentEpoch,
    epochEndTimestamp: epochEnd,
    secondsUntilEnd: Math.max(0, epochEnd - nowSec),
    proofDeadlineTimestamp: proofDeadline,
    secondsUntilDeadline: Math.max(0, proofDeadline - nowSec),
  };
}

/// Pretty-print competitive analysis
export function printCompetitiveAnalysis(profiles: ProverProfile[]): void {
  const now = new Date().toISOString();
  console.log(`\n=== Competitive Analysis (${now}) ===`);
  console.log(`  Active provers: ${profiles.length}`);
  console.log('');

  for (const p of profiles) {
    const short = `${p.address.slice(0, 6)}...${p.address.slice(-4)}`;
    const lastAgo = Math.floor(Date.now() / 1000) - Number(p.lastSubmissionTimestamp);
    const lastAgoMin = (lastAgo / 60).toFixed(1);

    console.log(`  ${short}:`);
    console.log(`    Submissions (24h):    ${p.submissions.length}`);
    console.log(`    Avg interval:         ${(p.avgIntervalSec / 60).toFixed(1)} min (epoch = ${(PROTOCOL.epochDurationSec / 60).toFixed(1)} min)`);
    console.log(`    Range:                ${(p.minIntervalSec / 60).toFixed(1)} - ${(p.maxIntervalSec / 60).toFixed(1)} min`);
    console.log(`    Proving latency:      ${(p.avgProvingLatencySec / 60).toFixed(1)} min after epoch end`);
    console.log(`    Last submission:      ${lastAgoMin} min ago`);
    console.log(`    Est. next in:         ${(p.estimatedNextSubmissionSec / 60).toFixed(1)} min`);
    console.log(`    Submissions/day:      ${p.submissionsPerDay.toFixed(1)}`);
    console.log('');
  }

  // Strategy recommendation
  if (profiles.length > 0) {
    const dominant = profiles[0];
    const ourWindow = PROTOCOL.epochDurationSec + PROTOCOL.proofWindowSec;
    const theirSpeed = dominant.avgIntervalSec;

    console.log('  --- Strategy ---');
    if (theirSpeed <= PROTOCOL.epochDurationSec * 1.05) {
      console.log('  Dominant prover uses streaming/pipelined proving (submits within epoch).');
      console.log('  To compete: prove concurrently and submit for the same epoch.');
      console.log('  Both provers share rewards proportional to activity score.');
      console.log(`  Our target: submit within ${(ourWindow / 60).toFixed(1)} min of epoch start.`);
    } else {
      const gap = theirSpeed - PROTOCOL.epochDurationSec;
      console.log(`  Dominant prover has ${(gap / 60).toFixed(1)} min proving latency after epoch end.`);
      console.log(`  We have ${(ourWindow / 60).toFixed(1)} min total window.`);
      console.log(`  If we prove faster than ${(gap / 60).toFixed(1)} min, we submit first.`);
    }
  }
}
