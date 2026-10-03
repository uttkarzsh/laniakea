pragma circom 2.0.0;

include "node_modules/circomlib/circuits/comparators.circom";

template AgeCheck() {
    signal input age;
    signal input threshold;
    signal output out;

    component gte = GreaterEqThan(8);
    gte.in[0] <== age;
    gte.in[1] <== threshold;
    out <== gte.out;
}

component main { public [threshold] } = AgeCheck();