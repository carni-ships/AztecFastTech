// PersistentBb — keeps a bb process resident via the msgpack API.
//
// Eliminates ~40ms startup overhead per prove by reusing a long-lived
// bb process. Communicates via stdin/stdout with length-prefixed msgpack.
//
// Witness prefetch: overlaps next witness I/O (read + decompress) with
// the current proof's compute-heavy phases (Sumcheck + PCS). Saves
// ~100-200ms per proof by hiding witness decompression latency.

import { spawn, type ChildProcess } from "child_process";
import { Encoder, Decoder } from "msgpackr";
import { readFile } from "fs/promises";
import { gunzip } from "zlib";
import { promisify } from "util";
import { join } from "path";

const DEFAULT_BB_PATH = join(process.env.HOME ?? "~", ".bb", "bb");

const msgpackEncoder = new Encoder({ useRecords: false });
const msgpackDecoder = new Decoder({ useRecords: false });
const gunzipAsync = promisify(gunzip);

/** Prefetched witness data ready for use in the next prove call. */
export interface PrefetchedWitness {
  /** Identifier (e.g., block number or circuit name) for cache matching. */
  id: string;
  /** Decompressed witness bytes, ready to pass to prove(). */
  witness: Buffer;
}

export class PersistentBb {
  private proc: ChildProcess;
  private pendingResolves: Array<{ resolve: (v: any) => void; reject: (e: Error) => void }> = [];
  private buffer = Buffer.alloc(0);
  private readingLength = true;
  private expectedLength = 0;

  // --- Witness prefetch state ---
  // A background promise that resolves to the next witness, or null if no prefetch is active.
  private prefetchPromise: Promise<PrefetchedWitness> | null = null;
  private prefetchId: string | null = null;

  constructor(threads: number, bbPath = DEFAULT_BB_PATH) {
    this.proc = spawn(bbPath, ["msgpack", "run"], {
      stdio: ["pipe", "pipe", "pipe"],
      env: { ...process.env, OMP_NUM_THREADS: String(threads) },
    });
    this.proc.stdout!.on("data", (d: Buffer) => this.handleData(d));
    this.proc.on("error", (e) => {
      if (this.pendingResolves.length > 0) this.pendingResolves.shift()!.reject(e);
    });
  }

  private handleData(data: Buffer) {
    this.buffer = Buffer.concat([this.buffer, data]);
    while (true) {
      if (this.readingLength) {
        if (this.buffer.length >= 4) {
          this.expectedLength = this.buffer.readUInt32LE(0);
          this.buffer = this.buffer.subarray(4);
          this.readingLength = false;
        } else break;
      } else {
        if (this.buffer.length >= this.expectedLength) {
          const payload = this.buffer.subarray(0, this.expectedLength);
          this.buffer = this.buffer.subarray(this.expectedLength);
          this.readingLength = true;
          const resp = msgpackDecoder.unpack(payload);
          if (this.pendingResolves.length > 0) this.pendingResolves.shift()!.resolve(resp);
        } else break;
      }
    }
  }

  /** Prove a circuit via the persistent bb process. */
  prove(
    bytecode: Buffer,
    vk: Buffer,
    witness: Buffer,
    circuitName = "circuit",
  ): Promise<any> {
    return new Promise((resolve, reject) => {
      this.pendingResolves.push({ resolve, reject });
      const cmd = [["CircuitProve", {
        circuit: { name: circuitName, bytecode, verification_key: vk },
        witness,
        settings: {
          ipa_accumulation: false,
          oracle_hash_type: "poseidon2",
          disable_zk: true,
          optimized_solidity_verifier: false,
        },
      }]];
      const packed = msgpackEncoder.pack(cmd);
      const lenBuf = Buffer.alloc(4);
      lenBuf.writeUInt32LE(packed.length, 0);
      this.proc.stdin!.write(lenBuf);
      this.proc.stdin!.write(packed);
    });
  }

  /**
   * Start prefetching the next witness file in the background.
   *
   * Call this right after sending a prove command — while the current proof
   * runs Sumcheck + PCS (CPU-bound, 8-15s), this reads and decompresses
   * the next witness file from disk, overlapping I/O with computation.
   *
   * @param id - Unique identifier for this witness (e.g., block number, circuit name).
   *             Used to match when retrieving via getPrefetchedWitness().
   * @param witnessPath - Path to .gz witness file on disk.
   */
  prefetchWitness(id: string, witnessPath: string): void {
    // Cancel any in-flight prefetch — only one at a time.
    this.prefetchId = id;
    this.prefetchPromise = (async () => {
      const compressed = await readFile(witnessPath);
      let decompressed: Buffer;
      try {
        decompressed = await gunzipAsync(compressed) as Buffer;
      } catch {
        // Not gzipped — use raw bytes.
        decompressed = compressed;
      }
      return { id, witness: decompressed };
    })();
    // Swallow errors — prefetch is best-effort. Failure just means
    // the next proof reads the witness synchronously as before.
    this.prefetchPromise.catch(() => {
      this.prefetchPromise = null;
      this.prefetchId = null;
    });
  }

  /**
   * Start prefetching a witness from raw bytes (already in memory but needs decompression).
   *
   * Use this when the witness data comes from a network fetch or witness builder
   * rather than a file on disk.
   *
   * @param id - Unique identifier for this witness.
   * @param compressedWitness - Gzipped witness bytes (or raw if not compressed).
   */
  prefetchWitnessFromBuffer(id: string, compressedWitness: Buffer): void {
    this.prefetchId = id;
    this.prefetchPromise = (async () => {
      let decompressed: Buffer;
      try {
        decompressed = await gunzipAsync(compressedWitness) as Buffer;
      } catch {
        decompressed = compressedWitness;
      }
      return { id, witness: decompressed };
    })();
    this.prefetchPromise.catch(() => {
      this.prefetchPromise = null;
      this.prefetchId = null;
    });
  }

  /**
   * Retrieve a prefetched witness if available and matching the given id.
   *
   * Returns the decompressed witness buffer if prefetch completed for this id,
   * or null if no matching prefetch is ready (caller should read witness normally).
   *
   * @param id - The witness identifier to match against the prefetch.
   * @param timeoutMs - Max time to wait for prefetch completion (default: 500ms).
   *                    Set to 0 to only return if already complete.
   */
  async getPrefetchedWitness(id: string, timeoutMs = 500): Promise<Buffer | null> {
    if (!this.prefetchPromise || this.prefetchId !== id) {
      return null;
    }

    try {
      if (timeoutMs <= 0) {
        // Non-blocking: race with an immediately-resolving promise.
        const result = await Promise.race([
          this.prefetchPromise,
          Promise.resolve(null),
        ]);
        return result?.witness ?? null;
      }

      // Wait up to timeoutMs for the prefetch to complete.
      const result = await Promise.race([
        this.prefetchPromise,
        new Promise<null>((resolve) => setTimeout(() => resolve(null), timeoutMs)),
      ]);

      if (result && result.id === id) {
        this.prefetchPromise = null;
        this.prefetchId = null;
        return result.witness;
      }
    } catch {
      // Prefetch failed — caller reads witness normally.
    }

    this.prefetchPromise = null;
    this.prefetchId = null;
    return null;
  }

  /** Check if a prefetch is currently in flight. */
  hasPendingPrefetch(): boolean {
    return this.prefetchPromise !== null;
  }

  /** Cancel any in-flight prefetch. */
  cancelPrefetch(): void {
    this.prefetchPromise = null;
    this.prefetchId = null;
  }

  /** Gracefully shut down the bb process. */
  shutdown(): Promise<void> {
    this.cancelPrefetch();
    const packed = msgpackEncoder.pack([["Shutdown", {}]]);
    const lenBuf = Buffer.alloc(4);
    lenBuf.writeUInt32LE(packed.length, 0);
    this.proc.stdin!.write(lenBuf);
    this.proc.stdin!.write(packed);
    this.proc.stdin!.end();
    return new Promise((r) => this.proc.on("close", r));
  }
}
