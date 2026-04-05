// Real-time L1 epoch watcher: tracks checkpoint production and competitor proof submissions
// as they happen, not post-hoc. Polls L1 every ~12s (1 block) for new events.

import { createPublicClient, http, parseAbiItem, type Log } from 'viem';
import { mainnet } from 'viem/chains';
import { ADDRESSES, RPC_ENDPOINTS, PROTOCOL } from './config.js';

function getPublicClient() {
  return createPublicClient({
    chain: mainnet,
    transport: http(RPC_ENDPOINTS.public[0]),
  });
}

const l2ProofVerifiedEvent = parseAbiItem(
  'event L2ProofVerified(uint256 indexed blockNumber, bytes32 indexed archive, address indexed proverId)',
);

export interface CompetitorSubmission {
  proverId: `0x${string}`;
  epoch: bigint;
  l2BlockNumber: bigint;
  l1BlockNumber: bigint;
  l1Timestamp: bigint;
  txHash: `0x${string}`;
}

export type EpochWatcherEvent =
  | { type: 'competitor-submitted'; submission: CompetitorSubmission }
  | { type: 'epoch-complete'; epoch: bigint; timestamp: number }
  | { type: 'new-l1-block'; blockNumber: bigint; timestamp: bigint };

export type EpochWatcherCallback = (event: EpochWatcherEvent) => void;

export interface EpochWatcherState {
  /** Last L1 block we scanned */
  lastScannedBlock: bigint;
  /** Current L1 block number */
  currentL1Block: bigint;
  /** Submissions seen per epoch (epoch → proverId[]) */
  epochSubmissions: Map<bigint, CompetitorSubmission[]>;
  /** Our prover address (to distinguish our submissions from competitors') */
  ourAddress: `0x${string}` | null;
  /** Whether we're running */
  running: boolean;
}

export class EpochWatcher {
  private state: EpochWatcherState;
  private callbacks: EpochWatcherCallback[] = [];
  private pollTimer: ReturnType<typeof setTimeout> | null = null;
  private pollIntervalMs: number;

  constructor(
    ourAddress: `0x${string}` | null = null,
    pollIntervalMs: number = 12_000, // ~1 L1 block
  ) {
    this.pollIntervalMs = pollIntervalMs;
    this.state = {
      lastScannedBlock: 0n,
      currentL1Block: 0n,
      epochSubmissions: new Map(),
      ourAddress: ourAddress?.toLowerCase() as `0x${string}` | null,
      running: false,
    };
  }

  on(callback: EpochWatcherCallback): void {
    this.callbacks.push(callback);
  }

  private emit(event: EpochWatcherEvent): void {
    for (const cb of this.callbacks) {
      try {
        cb(event);
      } catch {
        // Don't let callback errors kill the watcher
      }
    }
  }

  /** Start watching. Initializes from current block. */
  async start(): Promise<void> {
    if (this.state.running) return;
    this.state.running = true;

    const client = getPublicClient();
    const currentBlock = await client.getBlockNumber();
    // Start scanning from 5 blocks back to catch any recent submissions
    this.state.lastScannedBlock = currentBlock > 5n ? currentBlock - 5n : 0n;
    this.state.currentL1Block = currentBlock;

    console.log(`[EpochWatcher] Started at L1 block ${currentBlock}`);
    this.schedulePoll();
  }

  stop(): void {
    this.state.running = false;
    if (this.pollTimer) {
      clearTimeout(this.pollTimer);
      this.pollTimer = null;
    }
    console.log('[EpochWatcher] Stopped');
  }

  private schedulePoll(): void {
    if (!this.state.running) return;
    this.pollTimer = setTimeout(() => this.poll(), this.pollIntervalMs);
  }

  private async poll(): Promise<void> {
    if (!this.state.running) return;

    try {
      const client = getPublicClient();
      const currentBlock = await client.getBlockNumber();

      if (currentBlock <= this.state.lastScannedBlock) {
        this.schedulePoll();
        return;
      }

      // Emit new block event
      const block = await client.getBlock({ blockNumber: currentBlock });
      this.state.currentL1Block = currentBlock;
      this.emit({
        type: 'new-l1-block',
        blockNumber: currentBlock,
        timestamp: block.timestamp,
      });

      // Scan for L2ProofVerified events since last scanned block
      const fromBlock = this.state.lastScannedBlock + 1n;
      const logs = await client.getLogs({
        address: ADDRESSES.rollup,
        event: l2ProofVerifiedEvent,
        fromBlock,
        toBlock: currentBlock,
      });

      for (const log of logs) {
        const proverId = log.args.proverId!;
        const l2BlockNumber = log.args.blockNumber!;
        const epoch = l2BlockNumber / BigInt(PROTOCOL.slotsPerEpoch);

        const submission: CompetitorSubmission = {
          proverId,
          epoch,
          l2BlockNumber,
          l1BlockNumber: log.blockNumber,
          l1Timestamp: block.timestamp, // Approximate — same block we just fetched
          txHash: log.transactionHash,
        };

        // Track submission
        if (!this.state.epochSubmissions.has(epoch)) {
          this.state.epochSubmissions.set(epoch, []);
        }
        this.state.epochSubmissions.get(epoch)!.push(submission);

        // Emit if it's not us
        const isUs = this.state.ourAddress &&
          proverId.toLowerCase() === this.state.ourAddress;

        if (!isUs) {
          this.emit({ type: 'competitor-submitted', submission });
        }
      }

      this.state.lastScannedBlock = currentBlock;

      // Prune old epoch data (keep last 5 epochs)
      const nowSec = Math.floor(Date.now() / 1000);
      const currentEpoch = BigInt(Math.floor(nowSec / PROTOCOL.epochDurationSec));
      for (const epoch of this.state.epochSubmissions.keys()) {
        if (epoch < currentEpoch - 5n) {
          this.state.epochSubmissions.delete(epoch);
        }
      }
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error(`[EpochWatcher] Poll error: ${msg.slice(0, 150)}`);
    }

    this.schedulePoll();
  }

  // --- Query methods ---

  /** Has any competitor submitted a proof for this epoch? */
  hasCompetitorSubmitted(epoch: bigint): boolean {
    const subs = this.state.epochSubmissions.get(epoch);
    if (!subs) return false;
    if (!this.state.ourAddress) return subs.length > 0;
    return subs.some(s => s.proverId.toLowerCase() !== this.state.ourAddress);
  }

  /** Get all submissions for an epoch */
  getEpochSubmissions(epoch: bigint): CompetitorSubmission[] {
    return this.state.epochSubmissions.get(epoch) ?? [];
  }

  /** How many unique provers have submitted for this epoch? */
  getProverCount(epoch: bigint): number {
    const subs = this.state.epochSubmissions.get(epoch);
    if (!subs) return 0;
    return new Set(subs.map(s => s.proverId.toLowerCase())).size;
  }

  /** Current L1 block */
  getCurrentL1Block(): bigint {
    return this.state.currentL1Block;
  }

  /** Is the watcher running? */
  isRunning(): boolean {
    return this.state.running;
  }
}
