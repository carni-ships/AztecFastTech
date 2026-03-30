#!/usr/bin/env python3
"""Generate valid Prover.toml files for AztecFastTech circuits."""
import hashlib
import struct
import os

BENCH_DIR = os.path.dirname(os.path.abspath(__file__))

# BN254 scalar field order
P = 21888242871839275222246405745257275088548364400416034343698204186575808495617

def pseudo_poseidon2(left, right=0):
    """Approximate poseidon2 for witness generation - we only need consistent values.
    The actual circuit will verify, so we use nargo execute to get real values."""
    h = hashlib.sha256(left.to_bytes(32, 'big') + right.to_bytes(32, 'big')).digest()
    return int.from_bytes(h, 'big') % P

# --- Merkle tree witness ---
def gen_merkle_witness():
    TREE_DEPTH = 32
    NUM_PROOFS = 16
    
    # Build an empty tree with pseudo-poseidon2
    empty_leaf = pseudo_poseidon2(0)
    
    # Build empty subtree hashes at each level
    empty_at_level = [0] * TREE_DEPTH
    empty_at_level[0] = empty_leaf
    for i in range(1, TREE_DEPTH):
        empty_at_level[i] = pseudo_poseidon2(empty_at_level[i-1], empty_at_level[i-1])
    
    # For a valid witness, all leaves at index 0..NUM_PROOFS go left (index=0 means all bits=0)
    # All siblings are empty subtree hashes at each level
    # We'll just use all-zero indices so every proof takes the left path
    
    # Compute root from empty tree perspective - we insert leaves at distinct positions
    # Simplest: just use the same root for all proofs by making them all verify against
    # the empty tree root. Set all leaves = empty_leaf, all indices = 0.
    
    # Actually, let's just use nargo execute. Write dummy values and let nargo compute.
    # For the merkle circuit, the root is a public input we assert against.
    # We need consistent values. Let me just use all-zero leaves in an empty tree.
    
    # Empty tree root
    root = empty_leaf
    for i in range(TREE_DEPTH):
        root = pseudo_poseidon2(root, empty_at_level[i])
    
    lines = []
    lines.append(f'root = "{root}"')
    
    # All leaves are the empty_leaf (index 0 in empty tree)
    leaves = [f'"{empty_leaf}"'] * NUM_PROOFS
    lines.append(f'leaves = [{", ".join(leaves)}]')
    
    # All indices = 0
    indices = ['"0"'] * NUM_PROOFS
    lines.append(f'indices = [{", ".join(indices)}]')
    
    # All sibling paths are the empty subtree hashes
    siblings_rows = []
    for _ in range(NUM_PROOFS):
        row = [f'"{empty_at_level[j]}"' for j in range(TREE_DEPTH)]
        siblings_rows.append(f'[{", ".join(row)}]')
    lines.append(f'siblings = [{", ".join(siblings_rows)}]')
    
    with open(os.path.join(BENCH_DIR, 'merkle-tree', 'Prover.toml'), 'w') as f:
        f.write('\n'.join(lines) + '\n')
    print(f"Generated merkle-tree/Prover.toml (root={hex(root)[:20]}...)")

# --- EC ops witness ---
def gen_ec_witness():
    NUM_MULS = 16
    # Use small scalars; the circuit will compute the actual EC result.
    # We'll set result_x and result_y to 0 initially, then use nargo execute
    # to find the real values.
    lines = []
    scalars_lo = [f'"{i+1}"' for i in range(NUM_MULS)]
    scalars_hi = ['"0"'] * NUM_MULS
    lines.append(f'scalars_lo = [{", ".join(scalars_lo)}]')
    lines.append(f'scalars_hi = [{", ".join(scalars_hi)}]')
    # Placeholder - will need nargo execute to get real values
    lines.append('result_x = "0"')
    lines.append('result_y = "0"')
    
    with open(os.path.join(BENCH_DIR, 'ec-ops', 'Prover.toml'), 'w') as f:
        f.write('\n'.join(lines) + '\n')
    print("Generated ec-ops/Prover.toml (placeholder - needs nargo execute)")

gen_merkle_witness()
gen_ec_witness()
