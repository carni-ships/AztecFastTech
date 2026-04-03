// Poseidon2 hash chain benchmark
// Exercises the core hashing primitive used throughout Aztec's circuits.
// 1024 sequential hashes to stress the constraint system.

global CHAIN_LENGTH: u32 = 1024;

fn poseidon2_hash(input: Field) -> Field {
    std::hash::poseidon2_permutation([input, 0, 0, 0], 4)[0]
}

fn main(seed: pub Field) -> pub Field {
    let mut state = seed;
    for _ in 0..CHAIN_LENGTH {
        state = poseidon2_hash(state);
    }
    state
}
