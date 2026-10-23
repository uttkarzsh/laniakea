pragma circom 2.0.0;

// Minimal circuit used only to exercise the witness calculator (Phase 5a).
// It covers what age_check cannot: full-width field values, array inputs,
// field wraparound, and failing assertions. It is not a proving circuit.
template WitnessProbe() {
    signal input a;       // private scalar
    signal input b;       // public scalar
    signal input v[3];    // array input (signal size > 1)
    signal input flag;    // must be 0 or 1

    signal output prod;   // a * b  (mod p)
    signal output diff;   // a - b  (mod p, wraps for a < b)
    signal output sum;    // v[0] + v[1] + v[2]  (mod p)

    prod <== a * b;
    diff <== a - b;
    sum  <== v[0] + v[1] + v[2];

    flag * (flag - 1) === 0;  // constraint -> assertion during witness generation
    assert(b != 7);           // explicit runtime assert
}

component main { public [b] } = WitnessProbe();
