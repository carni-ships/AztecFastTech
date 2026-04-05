// Epoch selection: find which epochs the prover has proven but not yet claimed

import { createPublicClient, http, parseAbiItem } from 'viem';
import { mainnet } from 'viem/chains';
import { ADDRESSES, RPC_ENDPOINTS, DEFAULTS } from './config.js';
import { rollupAbi } from './abis.js';

function getPublicClient() {
  return createPublicClient({
    chain: mainnet,
    transport: http(RPC_ENDPOINTS.public[0]),
  });
}

// Event: L2ProofVerified(uint256 indexed blockNumber, bytes32 indexed archive, address indexed proverId)
const l2ProofVerifiedEvent = parseAbiItem(
  'event L2ProofVerified(uint256 indexed blockNumber, bytes32 indexed archive, address indexed proverId)',
);

export interface EpochInfo {
  epoch: bigint;
  blockNumber: bigint;
  txHash: `0x${string}`;
  l1Block: bigint;
}

/// Find all epochs where our prover submitted verified proofs
export async function getProvenEpochs(
  proverAddress: `0x${string}`,
  fromBlock?: bigint,
): Promise<EpochInfo[]> {
  const client = getPublicClient();

  // Default: look back ~7 days (~50k L1 blocks)
  const currentBlock = await client.getBlockNumber();
  const startBlock = fromBlock ?? (currentBlock > 50400n ? currentBlock - 50400n : 0n);

  const logs = await client.getLogs({
    address: ADDRESSES.rollup,
    event: l2ProofVerifiedEvent,
    args: {
      proverId: proverAddress,
    },
    fromBlock: startBlock,
    toBlock: 'latest',
  });

  return logs.map((log) => ({
    epoch: log.args.blockNumber! / 32n, // 32 blocks per epoch
    blockNumber: log.args.blockNumber!,
    txHash: log.transactionHash,
    l1Block: log.blockNumber,
  }));
}

/// Determine which proven epochs haven't been claimed yet.
/// Uses a simple heuristic: try to simulate claimProverRewards and see which epochs
/// actually return nonzero rewards. Epochs already claimed return 0.
export async function getUnclaimedEpochs(
  proverAddress: `0x${string}`,
  batcherAddress: `0x${string}`,
  fromBlock?: bigint,
): Promise<bigint[]> {
  const proven = await getProvenEpochs(proverAddress, fromBlock);
  if (proven.length === 0) return [];

  // Deduplicate epochs
  const uniqueEpochs = [...new Set(proven.map((e) => e.epoch))].sort((a, b) =>
    Number(a - b),
  );

  // Filter: try simulating claim for each epoch individually to check if it has unclaimed rewards.
  // This is expensive on RPC but accurate. For production, batch this.
  const client = getPublicClient();
  const unclaimed: bigint[] = [];

  // Check in batches of 10 to avoid excessive RPC calls
  for (let i = 0; i < uniqueEpochs.length; i += 10) {
    const batch = uniqueEpochs.slice(i, i + 10);

    const results = await Promise.allSettled(
      batch.map((epoch) =>
        client.simulateContract({
          address: ADDRESSES.rollup,
          abi: rollupAbi,
          functionName: 'claimProverRewards',
          args: [batcherAddress, [epoch]],
          account: batcherAddress,
        }),
      ),
    );

    for (let j = 0; j < results.length; j++) {
      const result = results[j];
      if (result.status === 'fulfilled' && result.value.result > 0n) {
        unclaimed.push(batch[j]);
      }
      // If rejected or result is 0, epoch is already claimed or not eligible
    }
  }

  return unclaimed;
}

/// Select optimal batch of epochs to claim, respecting min/max batch size
export function selectEpochBatch(
  unclaimed: bigint[],
  minBatch: number = DEFAULTS.minEpochBatch,
  maxBatch: number = DEFAULTS.maxEpochBatch,
): bigint[] | null {
  if (unclaimed.length < minBatch) {
    return null; // Not enough epochs accumulated
  }
  // Take up to maxBatch, oldest first
  return unclaimed.slice(0, maxBatch);
}
