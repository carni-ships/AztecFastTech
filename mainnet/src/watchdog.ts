// Prover process watchdog: monitors health, detects crashes/hangs, auto-restarts
//
// Watches the prover log file for activity. If no new log lines appear for
// a configurable timeout, assumes the prover is hung and restarts it.
// Also detects OOM kills and process exits.

import { execSync, spawn, type ChildProcess } from 'child_process';
import { existsSync, statSync, readFileSync } from 'fs';
import { PROTOCOL } from './config.js';

export interface WatchdogConfig {
  /** Path to the prover log file */
  logFile: string;
  /** Path to the prover start script */
  startScript: string;
  /** Extra args to pass to the start script */
  startArgs: string[];
  /** How long (ms) without log activity before considering the prover hung */
  hangTimeoutMs: number;
  /** How often (ms) to check prover health */
  checkIntervalMs: number;
  /** Maximum consecutive restarts before giving up */
  maxRestarts: number;
  /** Cooldown (ms) between restarts to avoid thrashing */
  restartCooldownMs: number;
  /** Path to prover data directory (for state cleanup) */
  dataDir: string;
  /** Callback when prover restarts */
  onRestart?: (reason: string, restartCount: number) => void;
  /** Callback when prover finishes an epoch (detected from logs) */
  onEpochComplete?: (epoch: number, durationSec: number) => void;
  /** Callback when watchdog gives up */
  onFatalFailure?: (reason: string) => void;
}

export interface ProverHealth {
  alive: boolean;
  pid: number | null;
  lastLogActivitySec: number;
  isProving: boolean;
  currentCircuit: string | null;
  consecutiveRestarts: number;
  totalEpochsProved: number;
  uptime: number;
}

interface EpochTiming {
  epoch: number;
  startedAt: number;   // unix seconds
  completedAt: number;  // unix seconds
  durationSec: number;
}

const DEFAULT_CONFIG: Omit<WatchdogConfig, 'logFile' | 'startScript' | 'dataDir'> = {
  startArgs: [],
  hangTimeoutMs: 10 * 60 * 1000,  // 10 min — root rollup takes ~5 min, give buffer
  checkIntervalMs: 30_000,         // check every 30s
  maxRestarts: 10,
  restartCooldownMs: 60_000,       // 1 min between restarts
};

export class ProverWatchdog {
  private config: WatchdogConfig;
  private process: ChildProcess | null = null;
  private lastLogSize: number = 0;
  private lastLogModified: number = 0;
  private lastLogCheck: number = Date.now();
  private consecutiveRestarts: number = 0;
  private lastRestartTime: number = 0;
  private startTime: number = Date.now();
  private totalEpochsProved: number = 0;
  private running: boolean = false;
  private checkTimer: ReturnType<typeof setTimeout> | null = null;

  // Epoch timing tracking
  private currentEpochStart: number = 0;
  private epochTimings: EpochTiming[] = [];

  constructor(config: Partial<WatchdogConfig> & Pick<WatchdogConfig, 'logFile' | 'startScript' | 'dataDir'>) {
    this.config = { ...DEFAULT_CONFIG, ...config };
  }

  /** Start the watchdog — launches the prover and begins monitoring */
  async start(): Promise<void> {
    if (this.running) return;
    this.running = true;
    this.startTime = Date.now();

    console.log('[Watchdog] Starting prover process...');
    this.launchProver();
    this.scheduleCheck();
  }

  /** Stop the watchdog and kill the prover */
  stop(): void {
    this.running = false;
    if (this.checkTimer) {
      clearTimeout(this.checkTimer);
      this.checkTimer = null;
    }
    this.killProver();
    console.log('[Watchdog] Stopped');
  }

  /** Get current prover health */
  getHealth(): ProverHealth {
    const now = Date.now();
    const lastActivitySec = (now - this.lastLogModified) / 1000;

    return {
      alive: this.process !== null && this.process.exitCode === null,
      pid: this.process?.pid ?? null,
      lastLogActivitySec: Math.round(lastActivitySec),
      isProving: this.currentEpochStart > 0,
      currentCircuit: this.detectCurrentCircuit(),
      consecutiveRestarts: this.consecutiveRestarts,
      totalEpochsProved: this.totalEpochsProved,
      uptime: Math.round((now - this.startTime) / 1000),
    };
  }

  /** Get recent epoch timings */
  getEpochTimings(): EpochTiming[] {
    return [...this.epochTimings];
  }

  /** Average epoch proving time (seconds) */
  getAvgEpochTime(): number {
    if (this.epochTimings.length === 0) return 0;
    const total = this.epochTimings.reduce((sum, t) => sum + t.durationSec, 0);
    return total / this.epochTimings.length;
  }

  private launchProver(): void {
    if (this.process) {
      this.killProver();
    }

    const child = spawn(this.config.startScript, this.config.startArgs, {
      stdio: ['ignore', 'pipe', 'pipe'],
      detached: false,
      env: { ...process.env },
    });

    child.on('exit', (code, signal) => {
      const reason = signal ? `signal ${signal}` : `exit code ${code}`;
      console.log(`[Watchdog] Prover exited: ${reason}`);
      this.process = null;

      if (this.running) {
        this.handleCrash(`Process exited (${reason})`);
      }
    });

    child.on('error', (err) => {
      console.error(`[Watchdog] Prover spawn error: ${err.message}`);
      this.process = null;
      if (this.running) {
        this.handleCrash(`Spawn error: ${err.message}`);
      }
    });

    // Pipe stdout/stderr to log detection (we still watch the log file for timing)
    child.stdout?.on('data', () => { this.lastLogModified = Date.now(); });
    child.stderr?.on('data', () => { this.lastLogModified = Date.now(); });

    this.process = child;
    this.lastLogModified = Date.now();
    console.log(`[Watchdog] Prover launched (PID: ${child.pid})`);
  }

  private killProver(): void {
    if (!this.process) return;

    try {
      // SIGTERM first, then SIGKILL after 5s
      this.process.kill('SIGTERM');
      const pid = this.process.pid;

      setTimeout(() => {
        try {
          if (pid) process.kill(pid, 0); // Check if still alive
          if (pid) process.kill(pid, 'SIGKILL');
        } catch {
          // Already dead
        }
      }, 5000);
    } catch {
      // Process already exited
    }

    this.process = null;
  }

  private scheduleCheck(): void {
    if (!this.running) return;
    this.checkTimer = setTimeout(() => this.check(), this.config.checkIntervalMs);
  }

  private check(): void {
    if (!this.running) return;

    try {
      // 1. Check if process is alive
      if (!this.process || this.process.exitCode !== null) {
        // Process is dead — handleCrash will be called by the 'exit' event
        this.scheduleCheck();
        return;
      }

      // 2. Check log file activity
      if (existsSync(this.config.logFile)) {
        const stat = statSync(this.config.logFile);
        const newSize = stat.size;

        if (newSize !== this.lastLogSize) {
          this.lastLogSize = newSize;
          this.lastLogModified = Date.now();
          this.scanLogTail();
        }
      }

      // 3. Check for hang (no log activity for hangTimeoutMs)
      const silentMs = Date.now() - this.lastLogModified;
      if (silentMs > this.config.hangTimeoutMs) {
        console.log(`[Watchdog] Prover appears hung (${Math.round(silentMs / 1000)}s silent)`);
        this.handleCrash(`Hung: no log activity for ${Math.round(silentMs / 1000)}s`);
        this.scheduleCheck();
        return;
      }

      // 4. Check for OOM via dmesg (macOS/Linux)
      if (this.process.pid) {
        this.checkOOM(this.process.pid);
      }
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error(`[Watchdog] Check error: ${msg.slice(0, 150)}`);
    }

    this.scheduleCheck();
  }

  /** Scan the tail of the log file for epoch completion markers */
  private scanLogTail(): void {
    try {
      if (!existsSync(this.config.logFile)) return;

      // Read last 8KB of log
      const stat = statSync(this.config.logFile);
      const readSize = Math.min(8192, stat.size);
      const fd = require('fs').openSync(this.config.logFile, 'r');
      const buf = Buffer.alloc(readSize);
      require('fs').readSync(fd, buf, 0, readSize, stat.size - readSize);
      require('fs').closeSync(fd);
      const tail = buf.toString('utf-8');

      // Detect epoch proving start
      // Pattern: "Proving epoch N" or "Starting epoch N" or "new proving job"
      const startMatch = tail.match(/(?:Proving|Starting|proving) epoch (\d+)/i);
      if (startMatch && this.currentEpochStart === 0) {
        this.currentEpochStart = Date.now() / 1000;
      }

      // Detect epoch completion
      // Pattern: "proof submitted" or "epoch N proved" or "submitEpochRootProof"
      const completeMatch = tail.match(/(?:proof submitted|epoch (\d+) prov|submitEpochRootProof|Proof for epoch (\d+))/i);
      if (completeMatch && this.currentEpochStart > 0) {
        const now = Date.now() / 1000;
        const duration = now - this.currentEpochStart;
        const epochNum = parseInt(completeMatch[1] || completeMatch[2] || '0');

        const timing: EpochTiming = {
          epoch: epochNum,
          startedAt: this.currentEpochStart,
          completedAt: now,
          durationSec: duration,
        };

        this.epochTimings.push(timing);
        // Keep last 50 timings
        if (this.epochTimings.length > 50) {
          this.epochTimings.shift();
        }

        this.totalEpochsProved++;
        this.currentEpochStart = 0;
        this.consecutiveRestarts = 0; // Successful epoch resets restart counter

        console.log(`[Watchdog] Epoch ${epochNum} proved in ${duration.toFixed(0)}s`);
        this.config.onEpochComplete?.(epochNum, duration);
      }
    } catch {
      // Log scanning is best-effort
    }
  }

  private checkOOM(pid: number): void {
    try {
      // macOS: check if process was killed by jetsam
      if (process.platform === 'darwin') {
        const result = execSync(
          `log show --predicate 'eventMessage contains "killed"' --last 1m 2>/dev/null | grep -i ${pid} || true`,
          { encoding: 'utf-8', timeout: 3000 },
        );
        if (result.includes(String(pid))) {
          this.handleCrash('OOM killed (jetsam)');
        }
      }
    } catch {
      // OOM detection is best-effort
    }
  }

  private handleCrash(reason: string): void {
    if (!this.running) return;

    this.consecutiveRestarts++;
    this.currentEpochStart = 0; // Reset epoch tracking

    console.log(`[Watchdog] Crash detected: ${reason} (restart ${this.consecutiveRestarts}/${this.config.maxRestarts})`);

    if (this.consecutiveRestarts > this.config.maxRestarts) {
      console.error(`[Watchdog] FATAL: Exceeded max restarts (${this.config.maxRestarts}). Giving up.`);
      this.config.onFatalFailure?.(`Exceeded max restarts: ${reason}`);
      this.stop();
      return;
    }

    // Enforce cooldown
    const now = Date.now();
    const sinceLast = now - this.lastRestartTime;
    if (sinceLast < this.config.restartCooldownMs) {
      const wait = this.config.restartCooldownMs - sinceLast;
      console.log(`[Watchdog] Cooldown: waiting ${Math.round(wait / 1000)}s before restart`);
      setTimeout(() => {
        if (this.running) {
          this.cleanupAndRestart(reason);
        }
      }, wait);
      return;
    }

    this.cleanupAndRestart(reason);
  }

  private cleanupAndRestart(reason: string): void {
    this.killProver();

    // Clean up broker state (it doesn't persist across restarts cleanly)
    try {
      const brokerPath = `${this.config.dataDir}/broker`;
      if (existsSync(brokerPath)) {
        execSync(`rm -rf "${brokerPath}"`, { timeout: 5000 });
        console.log('[Watchdog] Cleaned broker state for fresh restart');
      }
    } catch (err) {
      console.error('[Watchdog] Failed to clean broker state (continuing anyway)');
    }

    this.lastRestartTime = Date.now();
    this.config.onRestart?.(reason, this.consecutiveRestarts);

    console.log('[Watchdog] Restarting prover...');
    this.launchProver();
  }

  /** Detect what circuit is currently being proved from log tail */
  private detectCurrentCircuit(): string | null {
    try {
      if (!existsSync(this.config.logFile)) return null;
      const stat = statSync(this.config.logFile);
      const readSize = Math.min(4096, stat.size);
      const fd = require('fs').openSync(this.config.logFile, 'r');
      const buf = Buffer.alloc(readSize);
      require('fs').readSync(fd, buf, 0, readSize, stat.size - readSize);
      require('fs').closeSync(fd);
      const tail = buf.toString('utf-8');

      // Look for circuit names in recent log lines
      const circuits = [
        'ROOT_ROLLUP', 'CHECKPOINT_ROOT', 'CHECKPOINT_MERGE',
        'BLOCK_MERGE', 'PRIVATE_TX_BASE_ROLLUP', 'PARITY_BASE',
      ];
      // Search from end of string (most recent)
      for (const circuit of circuits) {
        if (tail.lastIndexOf(circuit) > tail.length - 2000) {
          return circuit;
        }
      }
    } catch {
      // Best-effort
    }
    return null;
  }
}

export function formatHealth(h: ProverHealth): string {
  const lines = [
    `  Alive:            ${h.alive ? 'YES' : 'NO'}${h.pid ? ` (PID ${h.pid})` : ''}`,
    `  Last log activity: ${h.lastLogActivitySec}s ago`,
    `  Currently proving: ${h.isProving ? (h.currentCircuit ?? 'yes') : 'no'}`,
    `  Consecutive restarts: ${h.consecutiveRestarts}`,
    `  Total epochs proved: ${h.totalEpochsProved}`,
    `  Uptime: ${Math.floor(h.uptime / 3600)}h ${Math.floor((h.uptime % 3600) / 60)}m`,
  ];
  return lines.join('\n');
}
