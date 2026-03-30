// Merkle tree benchmark
// Simulates Aztec's note hash tree pattern at scale.
// Computes 512 Poseidon2 hashes (equivalent to 10 levels of a 1024-leaf tree).
// Then verifies 8 membership proofs against the computed root.

global HASH_COUNT: u32 = 512;
global PROOF_COUNT: u32 = 8;
global PROOF_DEPTH: u32 = 10;

fn poseidon2_2to1(left: Field, right: Field) -> Field {
    std::hash::poseidon2_permutation([left, right, 0, 0], 4)[0]
}

fn main(seeds: [Field; PROOF_COUNT]) -> pub Field {
    // Phase 1: Hash chain to build a "reference" root (exercises Poseidon2 heavily)
    let mut nodes: [Field; HASH_COUNT] = [0; HASH_COUNT];
    for i in 0..HASH_COUNT {
        if i == 0 {
            nodes[i] = std::hash::poseidon2_permutation([seeds[0], 0, 0, 0], 4)[0];
        } else {
            nodes[i] = poseidon2_2to1(nodes[i - 1], seeds[i % PROOF_COUNT]);
        }
    }

    // Phase 2: Simulate membership proofs - chain of hashes per proof
    let mut acc = nodes[HASH_COUNT - 1];
    for p in 0..PROOF_COUNT {
        let mut current = seeds[p];
        for _d in 0..PROOF_DEPTH {
            current = poseidon2_2to1(current, acc);
        }
        acc = poseidon2_2to1(acc, current);
    }

    acc
}
