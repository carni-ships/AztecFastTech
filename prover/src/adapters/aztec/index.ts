// Aztec adapter for zkMetal — fetches L2 blocks from an Aztec node via JSON-RPC.
//
// Connects to an Aztec node (testnet or local) and fetches block data
// for benchmarking and proof generation.
//
// Usage:
//   tsx cli.ts watch --adapter aztec --node https://rpc.testnet.aztec-labs.com
//   tsx cli.ts prove --adapter aztec --node https://rpc.testnet.aztec-labs.com --block 100

import type { DataSource, WitnessBuilder, ProofSink, ProofOutput, RecursiveProofInputs } from "../../types.js";

// --- Aztec Block Types ---

/** Tree snapshot from Aztec state */
export interface TreeSnapshot {
  root: string;
  nextAvailableLeafIndex: number;
}

/** Gas fees structure */
export interface GasFees {
  feePerL2Gas: string;
  feePerDaGas: string;
}

/** Global variables from block header */
export interface GlobalVariables {
  chainId: string;
  version: string;
  blockNumber: number;
  slotNumber: number;
  timestamp: string;
  coinbase: string;
  feeRecipient: string;
  gasFees: GasFees;
}

/** State reference containing all tree snapshots */
export interface StateReference {
  l1ToL2MessageTree: TreeSnapshot;
  noteHashTree: TreeSnapshot;
  nullifierTree: TreeSnapshot;
  publicDataTree: TreeSnapshot;
}

/** Block header */
export interface AztecBlockHeader {
  lastArchive: TreeSnapshot;
  state: StateReference;
  globalVariables: GlobalVariables;
  totalFees: string;
  totalManaUsed: string;
}

/** Transaction effect within a block */
export interface TxEffect {
  /** Hex-encoded transaction hash */
  txHash?: string;
  /** Note hashes produced */
  noteHashes?: string[];
  /** Nullifiers produced */
  nullifiers?: string[];
  /** L2-to-L1 messages */
  l2ToL1Msgs?: string[];
  /** Public data writes [slot, value] */
  publicDataWrites?: Array<{ leafSlot: string; value: string }>;
}

/** Full Aztec L2 block */
export interface AztecBlock {
  /** Block number */
  number: number;
  /** Archive tree snapshot after block */
  archive: TreeSnapshot;
  /** Block header */
  header: AztecBlockHeader;
  /** Transaction effects */
  txEffects: TxEffect[];
  /** Raw JSON-RPC response (for debugging) */
  _raw?: unknown;
}

// --- JSON-RPC Helper ---

let rpcId = 1;

async function jsonRpc(url: string, method: string, params: unknown[] = []): Promise<unknown> {
  const body = JSON.stringify({
    jsonrpc: "2.0",
    id: rpcId++,
    method,
    params,
  });

  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body,
  });

  if (!res.ok) {
    throw new Error(`JSON-RPC ${method} failed: HTTP ${res.status} ${res.statusText}`);
  }

  const json = await res.json() as { result?: unknown; error?: { code: number; message: string } };

  if (json.error) {
    throw new Error(`JSON-RPC ${method} error: [${json.error.code}] ${json.error.message}`);
  }

  return json.result;
}

// --- Block parsing ---

function parseTreeSnapshot(raw: any): TreeSnapshot {
  if (!raw) return { root: "0x0", nextAvailableLeafIndex: 0 };
  return {
    root: raw.root ?? raw.Root ?? "0x0",
    nextAvailableLeafIndex: Number(raw.nextAvailableLeafIndex ?? raw.NextAvailableLeafIndex ?? 0),
  };
}

function parseGlobalVariables(raw: any): GlobalVariables {
  if (!raw) return {
    chainId: "0", version: "0", blockNumber: 0, slotNumber: 0,
    timestamp: "0", coinbase: "0x0", feeRecipient: "0x0",
    gasFees: { feePerL2Gas: "0", feePerDaGas: "0" },
  };
  return {
    chainId: String(raw.chainId ?? 0),
    version: String(raw.version ?? 0),
    blockNumber: Number(raw.blockNumber ?? 0),
    slotNumber: Number(raw.slotNumber ?? raw.slot ?? 0),
    timestamp: String(raw.timestamp ?? 0),
    coinbase: raw.coinbase ?? "0x0",
    feeRecipient: raw.feeRecipient ?? "0x0",
    gasFees: {
      feePerL2Gas: String(raw.gasFees?.feePerL2Gas ?? 0),
      feePerDaGas: String(raw.gasFees?.feePerDaGas ?? 0),
    },
  };
}

function parseHeader(raw: any): AztecBlockHeader {
  if (!raw) throw new Error("Block header is missing");
  return {
    lastArchive: parseTreeSnapshot(raw.lastArchive),
    state: {
      l1ToL2MessageTree: parseTreeSnapshot(raw.state?.l1ToL2MessageTree),
      noteHashTree: parseTreeSnapshot(raw.state?.partial?.noteHashTree ?? raw.state?.noteHashTree),
      nullifierTree: parseTreeSnapshot(raw.state?.partial?.nullifierTree ?? raw.state?.nullifierTree),
      publicDataTree: parseTreeSnapshot(raw.state?.partial?.publicDataTree ?? raw.state?.publicDataTree),
    },
    globalVariables: parseGlobalVariables(raw.globalVariables),
    totalFees: String(raw.totalFees ?? 0),
    totalManaUsed: String(raw.totalManaUsed ?? 0),
  };
}

function parseTxEffects(raw: any): TxEffect[] {
  if (!raw) return [];
  const effects = Array.isArray(raw) ? raw : (raw.txEffects ?? []);
  return effects.map((tx: any) => ({
    txHash: tx.txHash ?? tx.hash,
    noteHashes: tx.noteHashes ?? [],
    nullifiers: tx.nullifiers ?? [],
    l2ToL1Msgs: tx.l2ToL1Msgs ?? [],
    publicDataWrites: tx.publicDataWrites ?? [],
  }));
}

function parseBlock(raw: any, blockNumber: number): AztecBlock {
  if (!raw) throw new Error(`Block ${blockNumber} not found`);

  return {
    number: raw.header?.globalVariables?.blockNumber
      ? Number(raw.header.globalVariables.blockNumber)
      : blockNumber,
    archive: parseTreeSnapshot(raw.archive),
    header: parseHeader(raw.header),
    txEffects: parseTxEffects(raw.body),
    _raw: raw,
  };
}

// --- Aztec DataSource ---

export class AztecDataSource implements DataSource<AztecBlock> {
  constructor(private rpcUrl: string) {}

  async fetchBlock(blockNumber: number): Promise<AztecBlock> {
    // node_getBlock takes a block parameter — try numeric first
    const raw = await jsonRpc(this.rpcUrl, "node_getBlock", [blockNumber]);
    return parseBlock(raw, blockNumber);
  }

  async fetchLatestBlockNumber(): Promise<number> {
    const result = await jsonRpc(this.rpcUrl, "node_getBlockNumber", []);
    return Number(result);
  }

  async fetchNextBlockNumber(afterBlock: number): Promise<number | null> {
    const latest = await this.fetchLatestBlockNumber();
    if (afterBlock >= latest) return null;
    return afterBlock + 1;
  }

  /** Get node version info */
  async getNodeInfo(): Promise<{ version: string; chainId: number; protocolVersion: number }> {
    const info = await jsonRpc(this.rpcUrl, "node_getNodeInfo", []) as any;
    return {
      version: info?.nodeVersion ?? info?.version ?? "unknown",
      chainId: Number(info?.l1ChainId ?? info?.chainId ?? 0),
      protocolVersion: Number(info?.protocolVersion ?? info?.rollupVersion ?? 0),
    };
  }

  /** Get proven block number (last block with a valid proof) */
  async getProvenBlockNumber(): Promise<number> {
    const result = await jsonRpc(this.rpcUrl, "node_getProvenBlockNumber", []);
    return Number(result);
  }

  /** Check node readiness */
  async isReady(): Promise<boolean> {
    try {
      const result = await jsonRpc(this.rpcUrl, "node_isReady", []);
      return Boolean(result);
    } catch {
      return false;
    }
  }
}

// --- Aztec WitnessBuilder ---

/**
 * Builds witness data from Aztec L2 blocks.
 *
 * This extracts the block's tree roots, global variables, and tx effects
 * into a flat witness map suitable for proving. The exact witness layout
 * depends on which circuit is being used:
 *
 * - For benchmarking with a generic circuit, the block data is exposed
 *   as structured fields that the circuit can read.
 * - For rollup proving, Aztec's own rollup circuits expect specific
 *   witness formats (base/merge/root rollup).
 */
export class AztecWitnessBuilder implements WitnessBuilder<AztecBlock> {
  async buildWitness(
    block: AztecBlock,
    blockNumber: number,
    _recursiveOpts?: RecursiveProofInputs,
  ): Promise<Record<string, unknown>> {
    const header = block.header;
    const gv = header.globalVariables;

    // Flatten block data into witness fields.
    // Field names follow Aztec's rollup circuit conventions where possible.
    return {
      // Block identity
      block_number: String(blockNumber),
      slot_number: String(gv.slotNumber),
      timestamp: gv.timestamp,
      chain_id: gv.chainId,
      version: gv.version,

      // Fee data
      coinbase: gv.coinbase,
      fee_recipient: gv.feeRecipient,
      fee_per_l2_gas: gv.gasFees.feePerL2Gas,
      fee_per_da_gas: gv.gasFees.feePerDaGas,
      total_fees: header.totalFees,
      total_mana_used: header.totalManaUsed,

      // Archive tree (after block)
      archive_root: block.archive.root,
      archive_next_leaf: String(block.archive.nextAvailableLeafIndex),

      // Previous archive (before block)
      last_archive_root: header.lastArchive.root,
      last_archive_next_leaf: String(header.lastArchive.nextAvailableLeafIndex),

      // State trees (after block)
      note_hash_root: header.state.noteHashTree.root,
      note_hash_next_leaf: String(header.state.noteHashTree.nextAvailableLeafIndex),
      nullifier_root: header.state.nullifierTree.root,
      nullifier_next_leaf: String(header.state.nullifierTree.nextAvailableLeafIndex),
      public_data_root: header.state.publicDataTree.root,
      public_data_next_leaf: String(header.state.publicDataTree.nextAvailableLeafIndex),
      l1_to_l2_message_root: header.state.l1ToL2MessageTree.root,
      l1_to_l2_message_next_leaf: String(header.state.l1ToL2MessageTree.nextAvailableLeafIndex),

      // Transaction summary
      tx_count: String(block.txEffects.length),

      // Aggregated tx effect counts
      total_note_hashes: String(block.txEffects.reduce((n, tx) => n + (tx.noteHashes?.length ?? 0), 0)),
      total_nullifiers: String(block.txEffects.reduce((n, tx) => n + (tx.nullifiers?.length ?? 0), 0)),
      total_l2_to_l1_msgs: String(block.txEffects.reduce((n, tx) => n + (tx.l2ToL1Msgs?.length ?? 0), 0)),
      total_public_data_writes: String(block.txEffects.reduce((n, tx) => n + (tx.publicDataWrites?.length ?? 0), 0)),
    };
  }
}

// --- Aztec ProofSink (no-op) ---

/**
 * No-op proof sink for Aztec — proofs are saved locally.
 * Aztec doesn't have an external proof submission API;
 * proofs are submitted on-chain by the prover node.
 */
export class AztecProofSink implements ProofSink {
  async submitProof(proof: ProofOutput): Promise<void> {
    console.log(`[aztec] Proof for block ${proof.blockNumber} generated (${proof.provenBlocks} blocks proven)`);
    console.log(`[aztec] Proof saved locally — Aztec proofs are submitted on-chain by prover nodes`);
  }
}

// --- Factory ---

/** Create all Aztec adapter components from an RPC URL. */
export function createAztecAdapter(rpcUrl: string) {
  return {
    dataSource: new AztecDataSource(rpcUrl),
    witnessBuilder: new AztecWitnessBuilder(),
    proofSink: new AztecProofSink(),
  };
}
