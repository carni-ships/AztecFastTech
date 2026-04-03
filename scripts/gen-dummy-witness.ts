#!/usr/bin/env tsx
// Generate a dummy witness .gz file for benchmarking bb prove time.
// Format: msgpack WitnessStack { stack: [{ index: 0, witness: Map<u32, bytes[32]> }] } → gzip
//
// Usage: tsx gen-dummy-witness.ts <circuit.json> [output.gz] [--count N]

import { readFileSync, writeFileSync } from "fs";
import { gzipSync } from "zlib";
import { pack } from "msgpackr";

const circuitPath = process.argv[2];
if (!circuitPath) {
  console.error("Usage: tsx gen-dummy-witness.ts <circuit.json> [output.gz] [--count N]");
  process.exit(1);
}

const outputPath = process.argv[3] && !process.argv[3].startsWith("--") ? process.argv[3] : "witness.gz";
const countIdx = process.argv.indexOf("--count");
let explicitCount = countIdx >= 0 ? parseInt(process.argv[countIdx + 1]) : 0;

// Read circuit to find witness count from ABI
const circuit = JSON.parse(readFileSync(circuitPath, "utf-8"));

function countFieldsInType(typ: any): number {
  if (!typ) return 0;
  switch (typ.kind) {
    case "field":
    case "integer":
    case "boolean":
      return 1;
    case "array":
      return typ.length * countFieldsInType(typ.type);
    case "tuple":
      return (typ.fields || []).reduce((acc: number, f: any) => acc + countFieldsInType(f), 0);
    case "struct":
      return (typ.fields || []).reduce((acc: number, f: any) => acc + countFieldsInType(f.type), 0);
    case "string":
      return typ.length || 1;
    default:
      return 1;
  }
}

let abiSlots = 0;
if (circuit.abi?.parameters) {
  for (const param of circuit.abi.parameters) {
    abiSlots += countFieldsInType(param.type);
  }
}
if (circuit.abi?.return_type) {
  abiSlots += countFieldsInType(circuit.abi.return_type);
}

// Noir generates internal witness variables beyond the ABI slots.
// The actual max_witness_index is embedded in the bytecode, not the ABI.
// Use 2x the ABI count as a reasonable estimate, or explicit count.
const witnessCount = explicitCount || Math.max(abiSlots + 1, 100);

console.log(`Circuit: ${circuitPath}`);
console.log(`ABI fields: ${abiSlots}`);
console.log(`Generating ${witnessCount} witness entries...`);

// Build WitnessMap as a Map<number, Buffer>
// msgpackr encodes Maps natively
const witnessMap = new Map<number, Buffer>();
const zeroField = Buffer.alloc(32);
for (let i = 0; i < witnessCount; i++) {
  witnessMap.set(i, zeroField);
}

// WitnessStack = { stack: [StackItem] }
// StackItem = { index: 0, witness: WitnessMap }
const stack = { stack: [{ index: 0, witness: witnessMap }] };

const packed = pack(stack);
const compressed = gzipSync(packed);

writeFileSync(outputPath, compressed);
console.log(`Written ${outputPath} (${compressed.length} bytes compressed, ${packed.length} bytes raw)`);
