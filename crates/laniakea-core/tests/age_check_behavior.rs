//! Pins what the committed age_check circuit actually does, as opposed to what its
//! name suggests. These tests document current behavior; they are not a statement
//! that the behavior is desirable or secure.
//!
//! The circuit (`circuits/age_check/age_check.circom`) is
//! `out <== GreaterEqThan(8)(age, threshold)` with only `threshold` marked public
//! (the output is public too, so the public signals are `[out, threshold]`).
//! circomlib's `GreaterEqThan(8)` is `LessThan(8)(threshold, age + 1)`, and
//! `LessThan(8)` decomposes `v = threshold + 256 - (age + 1)` into 9 bits with
//! `Num2Bits(9)` and outputs `1 - bit8`. The 13 constraints (checked with
//! `snarkjs r1cs print`) are: 9 booleanity constraints on the bits, the two
//! linear definitions of `age + 1` and `v`, `out = 1 - bit8`, and
//! `sum(bit_i * 2^i) = v`. Consequences, all pinned below:
//!
//!   * nothing constrains `out == 1`: a valid proof exists for `out = 0`;
//!   * nothing constrains `age` or `threshold` to 8 bits. The only requirement
//!     is that `v`, as a field element, fits in 9 bits, i.e. `0 <= v < 512`
//!     reading `v` as an integer in [0, p). With threshold 18 that accepts the
//!     ages 0..=273 (256..=273 give `out = 1`) and the field elements
//!     p-238..=p-1 ("negative" ages, `out = 0`); everything else violates the
//!     `Num2Bits` equality and aborts witness generation with `AssertionFailed`;
//!   * `threshold` is unconstrained too (it is only public): the same rule bounds
//!     which (age, threshold) pairs are provable at all.
//!
//! Failure classes: a Circom assertion (`WitnessError::AssertionFailed`) is the
//! circuit rejecting the input. `MissingInputs`, `InputSize`, ... come from the
//! witness engine before the circuit runs. Reducing an input modulo p is input
//! encoding, not a circuit property.
//!
//! Proofs are verified against `verification_key.json` (not the key inside the
//! artifact). When `LANIAKEA_PROOF_DIR` is set, the proofs marked below are also
//! written there so `scripts/check-circuit-behavior.sh` can have snarkjs verify them.
#![cfg(not(target_os = "ios"))]

use ark_bn254::Fr;
use ark_ff::PrimeField;
use ark_serialize::CanonicalSerialize;
use laniakea_core::backend::prover::parse_vk_from_json;
use laniakea_core::{
    parse_zkey_to_artifact, Groth16Backend, LaniakeaError, ProofResult, Prover, WitnessError,
    ZkBackend,
};
use num_bigint::{BigInt, BigUint};
use std::fs;

const CIRCUITS: &str = "../../circuits/age_check";

fn p() -> BigInt {
    BigInt::from(BigUint::from(Fr::MODULUS))
}

fn read(name: &str) -> Vec<u8> {
    let path = format!("{CIRCUITS}/{name}");
    fs::read(&path).unwrap_or_else(|e| panic!("cannot read {path}: {e}"))
}

fn artifact() -> laniakea_core::ProvingArtifact {
    parse_zkey_to_artifact(&read("age_check_final.zkey")).expect("parse zkey")
}

fn prover() -> Prover {
    Prover::new(&artifact().to_bytes(), &read("age_check_js/age_check.wasm")).expect("prover")
}

fn vk_bytes() -> Vec<u8> {
    let json = String::from_utf8(read("verification_key.json")).unwrap();
    let mut bytes = Vec::new();
    parse_vk_from_json(&json)
        .expect("parse vk")
        .serialize_uncompressed(&mut bytes)
        .unwrap();
    bytes
}

fn inputs(age: &BigInt, threshold: &BigInt) -> Vec<(String, Vec<BigInt>)> {
    vec![
        ("age".to_string(), vec![age.clone()]),
        ("threshold".to_string(), vec![threshold.clone()]),
    ]
}

fn verifies(result: &ProofResult) -> bool {
    Groth16Backend
        .verify(
            &result.proof_json(),
            &result.public_signals_json(),
            &vk_bytes(),
        )
        .expect("verification ran")
}

/// Proves, verifies against the independent key, and returns the public signals.
/// `record` names the proof for snarkjs verification when LANIAKEA_PROOF_DIR is set.
fn prove_ok(
    prover: &Prover,
    age: &BigInt,
    threshold: &BigInt,
    record: Option<&str>,
) -> Vec<String> {
    let result = prover
        .prove(&inputs(age, threshold))
        .unwrap_or_else(|e| panic!("age={age} threshold={threshold} should prove but failed: {e}"));
    assert!(
        verifies(&result),
        "the proof for age={age} threshold={threshold} does not verify against verification_key.json"
    );
    if let (Some(name), Ok(dir)) = (record, std::env::var("LANIAKEA_PROOF_DIR")) {
        fs::create_dir_all(&dir).unwrap();
        fs::write(format!("{dir}/{name}.proof.json"), result.proof_json()).unwrap();
        fs::write(
            format!("{dir}/{name}.public.json"),
            result.public_signals_json(),
        )
        .unwrap();
    }
    result.public_signals.clone()
}

/// The circuit itself rejected the input: a failed Circom assertion.
fn assert_circuit_rejects(prover: &Prover, age: &BigInt, threshold: &BigInt) {
    match prover.prove(&inputs(age, threshold)) {
        Err(LaniakeaError::WitnessGeneration(WitnessError::AssertionFailed { .. })) => {}
        Ok(r) => panic!(
            "age={age} threshold={threshold} was accepted (signals {:?}); the circuit's \
             range behavior changed",
            r.public_signals
        ),
        Err(e) => panic!(
            "age={age} threshold={threshold} failed, but not with a circuit assertion: {e:?}"
        ),
    }
}

fn b(v: i64) -> BigInt {
    BigInt::from(v)
}

#[test]
fn the_circuit_has_the_traced_shape() {
    let a = artifact();
    assert_eq!(a.num_constraints(), 13, "constraint count changed");
    assert_eq!(a.witness_len(), 15, "wire count changed");
    // [1, out, threshold]: the constant, one output and one public input.
    assert_eq!(a.num_public_inputs(), 3);
}

#[test]
fn ordinary_ages_compare_correctly() {
    let pr = prover();
    for (age, thr, out) in [
        (25, 18, "1"),
        (18, 18, "1"),
        (17, 18, "0"),
        (10, 18, "0"),
        (0, 18, "0"),
        (255, 18, "1"),
        (0, 0, "1"),
        (254, 255, "0"),
        (255, 255, "1"),
    ] {
        let record = match (age, thr) {
            (25, 18) => Some("eligible_25"),
            (10, 18) => Some("ineligible_10"),
            _ => None,
        };
        assert_eq!(
            prove_ok(&pr, &b(age), &b(thr), record),
            [out.to_string(), thr.to_string()],
            "age={age} threshold={thr}"
        );
    }
}

#[test]
fn the_circuit_does_not_require_out_to_be_one() {
    // A valid proof exists for an ineligible age; verifiers must read `out`.
    let pr = prover();
    assert_eq!(prove_ok(&pr, &b(10), &b(18), None), ["0", "18"]);
}

#[test]
fn ages_above_255_are_not_rejected_up_to_threshold_plus_255() {
    let pr = prover();
    // 256..=273 are not valid 8-bit ages but the circuit accepts them, with out = 1.
    for age in 256..=273 {
        let record = match age {
            256 => Some("age_256"),
            273 => Some("age_273"),
            _ => None,
        };
        assert_eq!(
            prove_ok(&pr, &b(age), &b(18), record),
            ["1", "18"],
            "age {age}"
        );
    }
}

#[test]
fn the_first_rejected_age_is_274_for_threshold_18() {
    let pr = prover();
    for age in [274, 275, 300, 511, 1000, 1_000_000, i64::MAX] {
        assert_circuit_rejects(&pr, &b(age), &b(18));
    }
    // Large field elements that are not near p are rejected too.
    assert_circuit_rejects(&pr, &(BigInt::from(1u8) << 200), &b(18));
    assert_circuit_rejects(&pr, &(p() / 2), &b(18));
}

#[test]
fn the_accepted_range_moves_with_the_threshold() {
    // v = threshold + 255 - age must lie in [0, 511]: the largest accepted age is
    // threshold + 255, and the next one up is rejected. `threshold` is only public,
    // not range-checked.
    let pr = prover();
    for thr in [0i64, 1, 18, 100, 255, 256, 1000] {
        assert_eq!(
            prove_ok(&pr, &b(thr + 255), &b(thr), None),
            ["1".to_string(), thr.to_string()],
            "threshold {thr}: largest accepted age {}",
            thr + 255
        );
        assert_circuit_rejects(&pr, &b(thr + 256), &b(thr));
    }
}

#[test]
fn the_threshold_itself_is_unconstrained_beyond_the_same_rule() {
    let pr = prover();
    // v = 256 + 255 - 0 = 511 still fits in 9 bits...
    assert_eq!(
        prove_ok(&pr, &b(0), &b(256), Some("threshold_256")),
        ["0", "256"]
    );
    // ...v = 512 does not.
    assert_circuit_rejects(&pr, &b(0), &b(257));
}

#[test]
fn field_elements_just_below_p_prove_as_negative_ages_with_out_zero() {
    let pr = prover();
    // p - k plays "-k": v = 273 + k, which fits in 9 bits for k <= 238.
    assert_eq!(
        prove_ok(&pr, &(p() - 1), &b(18), Some("age_p_minus_1")),
        ["0", "18"]
    );
    assert_eq!(
        prove_ok(&pr, &(p() - 238), &b(18), Some("age_p_minus_238")),
        ["0", "18"]
    );
    assert_circuit_rejects(&pr, &(p() - 239), &b(18));
}

#[test]
fn inputs_are_reduced_modulo_p_before_the_circuit_sees_them() {
    // Input encoding, not a circuit constraint: the witness engine takes inputs
    // modulo p and wraps negatives, so these are the same field elements.
    let pr = prover();
    assert_eq!(prove_ok(&pr, &(p() + 25), &b(18), None), ["1", "18"]);
    assert_eq!(
        prove_ok(&pr, &b(-1), &b(18), None),
        prove_ok(&pr, &(p() - 1), &b(18), None)
    );
    assert_circuit_rejects(&pr, &(p() + 274), &b(18));
}

#[test]
fn input_shape_errors_are_not_circuit_rejections() {
    let pr = prover();
    // Rejected by the witness engine before the circuit runs.
    let missing = pr.prove(&[("age".to_string(), vec![b(25)])]).unwrap_err();
    assert!(
        matches!(
            missing,
            LaniakeaError::WitnessGeneration(WitnessError::MissingInputs { .. })
        ),
        "{missing:?}"
    );
    let two_values = pr
        .prove(&[
            ("age".to_string(), vec![b(25), b(26)]),
            ("threshold".to_string(), vec![b(18)]),
        ])
        .unwrap_err();
    assert!(
        matches!(
            two_values,
            LaniakeaError::WitnessGeneration(WitnessError::InputSize { .. })
        ),
        "{two_values:?}"
    );
}
