// Elliptic curve operations benchmark
// Exercises embedded curve scalar multiplications (Grumpkin curve)
// that dominate Aztec's Schnorr verification and Pedersen commitments.

use std::embedded_curve_ops::{EmbeddedCurvePoint, EmbeddedCurveScalar, multi_scalar_mul};

global NUM_MULS: u32 = 16;

fn main(scalars_lo: [Field; NUM_MULS], scalars_hi: [Field; NUM_MULS]) -> pub [Field; 2] {
    // Grumpkin generator
    let gen = EmbeddedCurvePoint {
        x: 1,
        y: 17631683881184975370165255887551781615748388533673675138860,
        is_infinite: false,
    };

    let mut acc = EmbeddedCurvePoint { x: 0, y: 0, is_infinite: true };

    for i in 0..NUM_MULS {
        let scalar = EmbeddedCurveScalar { lo: scalars_lo[i], hi: scalars_hi[i] };
        let pt = multi_scalar_mul([gen], [scalar]);
        if acc.is_infinite {
            acc = pt;
        } else {
            let one = EmbeddedCurveScalar { lo: 1, hi: 0 };
            acc = multi_scalar_mul([acc, pt], [one, one]);
        }
    }

    [acc.x, acc.y]
}
