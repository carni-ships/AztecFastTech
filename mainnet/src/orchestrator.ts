// Proving orchestrator: coordinates pipelined proving, real-time competitor
// monitoring, early abort decisions, and auto-recovery.
//
// The Aztec prover node handles proof generation internally — we can't modify
// its proving pipeline. What we CAN control:
//
// 1. PIPELINING: Ensure archiver is synced and caches are warm BEFORE the
//    epoch completes, so proving starts with zero lag. Monitor checkpoint
//    arrival to predict epoch completion and pre-warm.
//
// 2. REAL-TIME AWARENESS: Watch L1 for competitor proof submissions as they
//    happen. Know instantly when someone submits for the current epoch.
//
// 3. ABORT/CONTINUE DECISIONS: If a competitor submits for the current epoch
//    while we're proving, decide whether to continue (build activity score)
//    or skip (save gas for a non-competitive submission).
//
// 4. AUTO-RECOVERY: Monitor prover health, restart on crash/hang, clean state.

import { EpochWatcher, type CompetitorSubmission } from './epoch-watcher.js';
import { ProverWatchdog, formatHealth } from './watchdog.js';
import { PROTOCOL, DEFAULTS } from './config.js';

// --- Activity Score Economics ---
// Activity score determines our share of epoch rewards.
// Score += 125,000 per proof submitted (caps at 15,000,000)
// Score -= 100,000 per epoch we DON'T submit
// At max score: 1,000,000 shares. At zero: 100,000 shares (10%).
//
// Submitting costs ~$1 gas. Each proof builds 125k score → eventually
// worth 10x more shares. Always submit if we're building score,
// unless we've maxed out AND there are many competitors.

const SCORE_INCREMENT = PROTOCOL.scoreIncrement;       // 125,000
const SCORE_MAX = PROTOCOL.scoreMax;                   // 15,000,000
const SCORE_DECAY = PROTOCOL.scoreDecayPerEpoch;       // 100,000
const EPOCHS_TO_MAX_SCORE = Math.ceil(SCORE_MAX / SCORE_INCREMENT); // 120

export interface OrchestratorConfig {
  /** Our prover address */
  proverAddress: `0x${string}`;
  /** Path to prover log file */
  logFile: string;
  /** Path to prover start script */
  startScript: string;
  /** Extra args for start script */
  startArgs: string[];
  /** Path to prover data directory */
  dataDir: string;
  /** Our current activity score estimate (updated as we submit proofs) */
  initialScore: number;
  /** Gas cost of submitting a proof in ETH */
  proofSubmissionCostEth: number;
  /** Estimated reward per epoch in ETH (at current AZTEC price) */
  estimatedRewardPerEpochEth: number;
  /** Max competitor count before we consider skipping (to save gas) */
  maxCompetitorsBeforeSkip: number;
  /** Whether to enable auto-recovery (watchdog) */
  enableWatchdog: boolean;
  /** How often to print status (ms) */
  statusIntervalMs: number;
}

const DEFAULT_ORCHESTRATOR_CONFIG: Omit<OrchestratorConfig, 'proverAddress' | 'logFile' | 'startScript' | 'dataDir'> = {
  startArgs: [],
  initialScore: 0,
  proofSubmissionCostEth: 0.0005,   // ~$1 at current gas
  estimatedRewardPerEpochEth: 0.04, // ~$85 at current AZTEC price
  maxCompetitorsBeforeSkip: 30,     // Break-even is ~37, be conservative
  enableWatchdog: true,
  statusIntervalMs: 60_000,
};

export type SubmitDecision = 'submit' | 'skip' | 'submit-for-score';

interface EpochState {
  epoch: bigint;
  startedProvingAt: number;
  competitorSubmissions: CompetitorSubmission[];
  decision: SubmitDecision | null;
  decisionReason: string;
}

export class ProvingOrchestrator {
  private config: OrchestratorConfig;
  private watcher: EpochWatcher;
  private watchdog: ProverWatchdog | null = null;
  private running: boolean = false;
  private statusTimer: ReturnType<typeof setTimeout> | null = null;

  // State tracking
  private activityScore: number;
  private epochsProved: number = 0;
  private epochsSkipped: number = 0;
  private currentEpoch: EpochState | null = null;
  private recentDecisions: Array<{ epoch: bigint; decision: SubmitDecision; reason: string }> = [];

  constructor(config: Partial<OrchestratorConfig> & Pick<OrchestratorConfig, 'proverAddress' | 'logFile' | 'startScript' | 'dataDir'>) {
    this.config = { ...DEFAULT_ORCHESTRATOR_CONFIG, ...config };
    this.activityScore = this.config.initialScore;

    // Set up the L1 watcher
    this.watcher = new EpochWatcher(this.config.proverAddress);
    this.watcher.on((event) => {
      switch (event.type) {
        case 'competitor-submitted':
          this.onCompetitorSubmitted(event.submission);
          break;
        case 'new-l1-block':
          // Opportunity for pre-warming, cache checks, etc.
          break;
      }
    });

    // Set up watchdog if enabled
    if (this.config.enableWatchdog) {
      this.watchdog = new ProverWatchdog({
        logFile: this.config.logFile,
        startScript: this.config.startScript,
        startArgs: this.config.startArgs,
        dataDir: this.config.dataDir,
        onRestart: (reason, count) => {
          console.log(`[Orchestrator] Prover restarted: ${reason} (attempt ${count})`);
          // Reset current epoch state — we lost our proving progress
          this.currentEpoch = null;
        },
        onEpochComplete: (epoch, durationSec) => {
          this.onEpochProved(epoch, durationSec);
        },
        onFatalFailure: (reason) => {
          console.error(`[Orchestrator] FATAL: Watchdog gave up — ${reason}`);
          console.error('[Orchestrator] Manual intervention required.');
        },
      });
    }
  }

  /** Start the orchestrator: launches watcher, watchdog, and status loop */
  async start(): Promise<void> {
    if (this.running) return;
    this.running = true;

    console.log('=== Proving Orchestrator Started ===');
    console.log(`  Prover:            ${this.config.proverAddress}`);
    console.log(`  Activity score:    ${this.activityScore} / ${SCORE_MAX}`);
    console.log(`  Epochs to max:     ${Math.max(0, Math.ceil((SCORE_MAX - this.activityScore) / SCORE_INCREMENT))}`);
    console.log(`  Watchdog:          ${this.config.enableWatchdog ? 'ON' : 'OFF'}`);
    console.log(`  Skip threshold:    ${this.config.maxCompetitorsBeforeSkip} competitors`);
    console.log('');

    // Start L1 watcher
    await this.watcher.start();

    // Start watchdog (launches prover process)
    if (this.watchdog) {
      await this.watchdog.start();
    }

    // Start status loop
    this.scheduleStatus();
  }

  /** Stop everything */
  stop(): void {
    this.running = false;
    this.watcher.stop();
    this.watchdog?.stop();
    if (this.statusTimer) {
      clearTimeout(this.statusTimer);
      this.statusTimer = null;
    }
    console.log('[Orchestrator] Stopped');
  }

  // --- Decision Engine ---

  /**
   * Decide whether to submit our proof for an epoch, given the competitive landscape.
   *
   * Three outcomes:
   * - 'submit':           No competitors seen → submit for full reward
   * - 'submit-for-score': Competitors present but activity score is valuable → submit anyway ($1 gas)
   * - 'skip':             Many competitors AND score is maxed → save gas
   */
  makeSubmitDecision(epoch: bigint): { decision: SubmitDecision; reason: string } {
    const competitors = this.watcher.getProverCount(epoch);
    const hasCompetitor = this.watcher.hasCompetitorSubmitted(epoch);

    // No competitors → always submit
    if (!hasCompetitor) {
      return { decision: 'submit', reason: 'No competitor submissions detected' };
    }

    // Competitors present — evaluate activity score value
    const scoreDeficit = SCORE_MAX - this.activityScore;
    const epochsToMax = Math.ceil(scoreDeficit / SCORE_INCREMENT);

    // If we're still building score, always submit (each proof is worth 125k score)
    if (this.activityScore < SCORE_MAX) {
      // Calculate the value of 125k score in future rewards
      // At max score: 1M shares. At current: proportionally less.
      // Each 125k score ≈ 0.83% of max shares. Over 120 epochs, that compounds.
      return {
        decision: 'submit-for-score',
        reason: `Score ${this.activityScore}/${SCORE_MAX} (${epochsToMax} epochs to max). ` +
          `${competitors} competitor(s) seen. Submitting to build score.`,
      };
    }

    // Score is maxed. Worth submitting if expected reward > gas cost.
    const expectedShare = 1 / (competitors + 1); // +1 for us
    const expectedReward = this.config.estimatedRewardPerEpochEth * expectedShare;
    const gasCost = this.config.proofSubmissionCostEth;

    if (expectedReward > gasCost * 2) {
      return {
        decision: 'submit',
        reason: `Score maxed. ${competitors} competitors → expected ${(expectedShare * 100).toFixed(1)}% share ` +
          `(~${expectedReward.toFixed(4)} ETH) > 2x gas cost (${gasCost.toFixed(4)} ETH)`,
      };
    }

    // Too many competitors and score is maxed — skip
    if (competitors >= this.config.maxCompetitorsBeforeSkip) {
      return {
        decision: 'skip',
        reason: `Score maxed, ${competitors} competitors ≥ threshold ${this.config.maxCompetitorsBeforeSkip}. ` +
          `Expected reward ${expectedReward.toFixed(4)} ETH not worth gas.`,
      };
    }

    // Default: submit for the proportional reward
    return {
      decision: 'submit',
      reason: `Score maxed, ${competitors} competitors. Expected ${(expectedShare * 100).toFixed(1)}% share. Submitting.`,
    };
  }

  // --- Event Handlers ---

  private onCompetitorSubmitted(submission: CompetitorSubmission): void {
    const short = `${submission.proverId.slice(0, 6)}...${submission.proverId.slice(-4)}`;
    const epochNum = Number(submission.epoch);
    console.log(`[Orchestrator] Competitor ${short} submitted proof for epoch ${epochNum} (tx: ${submission.txHash.slice(0, 10)}...)`);

    // Re-evaluate our decision for this epoch
    const { decision, reason } = this.makeSubmitDecision(submission.epoch);

    if (this.currentEpoch && this.currentEpoch.epoch === submission.epoch) {
      this.currentEpoch.competitorSubmissions.push(submission);
      this.currentEpoch.decision = decision;
      this.currentEpoch.decisionReason = reason;
    }

    console.log(`[Orchestrator] Decision for epoch ${epochNum}: ${decision}`);
    console.log(`  Reason: ${reason}`);
  }

  private onEpochProved(epoch: number, durationSec: number): void {
    this.epochsProved++;
    const epochBig = BigInt(epoch);

    // Get the final submit decision
    const { decision, reason } = this.makeSubmitDecision(epochBig);

    this.recentDecisions.push({ epoch: epochBig, decision, reason });
    if (this.recentDecisions.length > 20) {
      this.recentDecisions.shift();
    }

    if (decision === 'skip') {
      this.epochsSkipped++;
      // Activity score decays when we don't submit
      this.activityScore = Math.max(0, this.activityScore - SCORE_DECAY);
      console.log(`[Orchestrator] Epoch ${epoch}: SKIPPING submission (${reason})`);
      console.log(`  Activity score: ${this.activityScore} (-${SCORE_DECAY} decay)`);
    } else {
      // We'll submit — score increases
      this.activityScore = Math.min(SCORE_MAX, this.activityScore + SCORE_INCREMENT);
      const label = decision === 'submit-for-score' ? 'SUBMITTING (for score)' : 'SUBMITTING';
      console.log(`[Orchestrator] Epoch ${epoch}: ${label} — proved in ${durationSec.toFixed(0)}s`);
      console.log(`  Activity score: ${this.activityScore} (+${SCORE_INCREMENT})`);
    }

    // Reset epoch state
    this.currentEpoch = null;
  }

  // --- Status ---

  private scheduleStatus(): void {
    if (!this.running) return;
    this.statusTimer = setTimeout(() => {
      this.printStatus();
      this.scheduleStatus();
    }, this.config.statusIntervalMs);
  }

  printStatus(): void {
    const now = new Date().toISOString().replace('T', ' ').slice(0, 19);
    console.log(`\n--- Orchestrator Status (${now}) ---`);

    // Activity score
    const pct = ((this.activityScore / SCORE_MAX) * 100).toFixed(1);
    const epochsToMax = Math.max(0, Math.ceil((SCORE_MAX - this.activityScore) / SCORE_INCREMENT));
    console.log(`  Activity score:    ${this.activityScore.toLocaleString()} / ${SCORE_MAX.toLocaleString()} (${pct}%)`);
    if (epochsToMax > 0) {
      console.log(`  Epochs to max:     ${epochsToMax} (~${(epochsToMax * PROTOCOL.epochDurationSec / 3600).toFixed(1)}h)`);
    }

    // Epoch stats
    console.log(`  Epochs proved:     ${this.epochsProved}`);
    console.log(`  Epochs skipped:    ${this.epochsSkipped}`);

    // Proving speed
    if (this.watchdog) {
      const avgTime = this.watchdog.getAvgEpochTime();
      if (avgTime > 0) {
        const margin = PROTOCOL.epochDurationSec + PROTOCOL.proofWindowSec - avgTime;
        console.log(`  Avg proving time:  ${(avgTime / 60).toFixed(1)} min`);
        console.log(`  Time margin:       ${(margin / 60).toFixed(1)} min before deadline`);
      }
    }

    // Watchdog health
    if (this.watchdog) {
      const health = this.watchdog.getHealth();
      console.log(`  Prover alive:      ${health.alive ? 'YES' : 'NO'}${health.pid ? ` (PID ${health.pid})` : ''}`);
      if (health.isProving) {
        console.log(`  Current circuit:   ${health.currentCircuit ?? 'unknown'}`);
      }
      if (health.consecutiveRestarts > 0) {
        console.log(`  Restarts:          ${health.consecutiveRestarts}`);
      }
    }

    // L1 watcher
    console.log(`  L1 block:          ${this.watcher.getCurrentL1Block()}`);

    // Recent decisions
    if (this.recentDecisions.length > 0) {
      const last = this.recentDecisions[this.recentDecisions.length - 1];
      console.log(`  Last decision:     epoch ${last.epoch}: ${last.decision}`);
    }
    console.log('');
  }
}

// --- CLI entry point ---

export interface RunOrchestratorOptions {
  proverAddress: `0x${string}`;
  logFile?: string;
  startScript?: string;
  startArgs?: string[];
  dataDir?: string;
  initialScore?: number;
  noWatchdog?: boolean;
}

export async function runOrchestrator(opts: RunOrchestratorOptions): Promise<never> {
  const orchestrator = new ProvingOrchestrator({
    proverAddress: opts.proverAddress,
    logFile: opts.logFile ?? '.prover-data-mainnet/prover.log',
    startScript: opts.startScript ?? './scripts/start-prover-mainnet.sh',
    startArgs: opts.startArgs ?? [],
    dataDir: opts.dataDir ?? '.prover-data-mainnet',
    initialScore: opts.initialScore ?? 0,
    enableWatchdog: !opts.noWatchdog,
  });

  // Handle shutdown
  const shutdown = () => {
    console.log('\n[Orchestrator] Shutting down...');
    orchestrator.stop();
    process.exit(0);
  };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);

  await orchestrator.start();

  // Keep alive
  return new Promise(() => {});
}
