//! `Verifier`: Groth16 verification against snarkjs's `verification_key.json`.
//!
//! Independence: besides Laniakea's own proofs, the verifier is checked on a proof made
//! by snarkjs (`tests/fixtures/age_check_snarkjs_*.json`, generated with
//! `snarkjs groth16 fullprove` from the repository's age_check files and accepted by
//! `snarkjs groth16 verify`), so it agrees with an outside implementation in both
//! directions. Laniakea's own proofs are also checked by snarkjs in
//! scripts/check-circuit-behavior.sh and the Swift tests.
#![cfg(not(target_os = "ios"))]

use laniakea_core::{parse_zkey_to_artifact, ProofResult, Prover, VerificationError, Verifier};
use num_bigint::BigInt;
use serde_json::Value;
use std::fs;

const CIRCUITS: &str = "../../circuits";
const FIXTURES: &str = "tests/fixtures";

fn vk_json() -> String {
    fs::read_to_string(format!("{CIRCUITS}/age_check/verification_key.json")).expect("read vk")
}

fn verifier() -> Verifier {
    Verifier::from_snarkjs_json(&vk_json()).expect("verification_key.json is a usable key")
}

fn prove(age: i64) -> ProofResult {
    let zkey = fs::read(format!("{CIRCUITS}/age_check/age_check_final.zkey")).expect("zkey");
    let wasm = fs::read(format!("{CIRCUITS}/age_check/age_check_js/age_check.wasm")).expect("wasm");
    let artifact = parse_zkey_to_artifact(&zkey).expect("parse zkey");
    let prover = Prover::new(&artifact.to_bytes(), &wasm).expect("prover");
    prover
        .prove(&[
            ("age".to_string(), vec![BigInt::from(age)]),
            ("threshold".to_string(), vec![BigInt::from(18)]),
        ])
        .expect("prove")
}

fn signals(values: &[&str]) -> Vec<String> {
    values.iter().map(|s| s.to_string()).collect()
}

fn snarkjs_proof() -> String {
    fs::read_to_string(format!("{FIXTURES}/age_check_snarkjs_proof.json")).expect("fixture")
}

fn snarkjs_signals() -> Vec<String> {
    let text =
        fs::read_to_string(format!("{FIXTURES}/age_check_snarkjs_public.json")).expect("fixture");
    serde_json::from_str(&text).expect("public.json is an array of strings")
}

/// `vk_json()` with one top-level field replaced (or removed with `None`).
fn vk_with(field: &str, value: Option<Value>) -> String {
    let mut vk: Value = serde_json::from_str(&vk_json()).unwrap();
    let object = vk.as_object_mut().unwrap();
    match value {
        Some(v) => object.insert(field.to_string(), v),
        None => object.remove(field),
    };
    vk.to_string()
}

/// `proof` with one coordinate of `pi_a` replaced.
fn proof_with_pi_a(proof: &str, index: usize, value: &str) -> String {
    let mut p: Value = serde_json::from_str(proof).unwrap();
    p["pi_a"][index] = Value::String(value.to_string());
    p.to_string()
}

// ------------------------------------------------------------------ accepts

#[test]
fn accepts_laniakea_proofs_for_both_outcomes() {
    let v = verifier();
    assert_eq!(v.num_public_signals(), 2);
    let eligible = prove(25);
    let ineligible = prove(10);
    assert_eq!(eligible.public_signals, ["1", "18"]);
    assert_eq!(ineligible.public_signals, ["0", "18"]);
    // Both are valid: verification says the circuit was satisfied, not that out == 1.
    assert_eq!(
        v.verify(&eligible.proof_json(), &eligible.public_signals),
        Ok(true)
    );
    assert_eq!(
        v.verify(&ineligible.proof_json(), &ineligible.public_signals),
        Ok(true)
    );
}

#[test]
fn accepts_a_proof_made_by_snarkjs() {
    assert_eq!(
        verifier().verify(&snarkjs_proof(), &snarkjs_signals()),
        Ok(true)
    );
}

#[test]
fn one_verifier_serves_many_calls_and_threads() {
    let v = std::sync::Arc::new(verifier());
    let proof = prove(30);
    let handles: Vec<_> = (0..4)
        .map(|_| {
            let (v, proof) = (v.clone(), proof.clone());
            std::thread::spawn(move || v.verify(&proof.proof_json(), &proof.public_signals))
        })
        .collect();
    for h in handles {
        assert_eq!(h.join().unwrap(), Ok(true));
    }
}

// ------------------------------------------------------------------ rejects (Ok(false))

#[test]
fn rejects_changed_public_signals() {
    let v = verifier();
    let proof = prove(25);
    assert_eq!(
        v.verify(&proof.proof_json(), &signals(&["0", "18"])),
        Ok(false)
    );
    assert_eq!(
        v.verify(&proof.proof_json(), &signals(&["1", "17"])),
        Ok(false)
    );
    assert_eq!(
        v.verify(&snarkjs_proof(), &signals(&["0", "18"])),
        Ok(false)
    );
}

#[test]
fn rejects_a_proof_paired_with_another_proofs_signals() {
    let v = verifier();
    let (eligible, ineligible) = (prove(25), prove(10));
    assert_eq!(
        v.verify(&ineligible.proof_json(), &eligible.public_signals),
        Ok(false)
    );
}

#[test]
fn rejects_a_proof_with_swapped_valid_points() {
    // Every point is a valid group element, so this reaches the pairing and fails there.
    let v = verifier();
    let mut p: Value = serde_json::from_str(&prove(25).proof_json()).unwrap();
    let a = p["pi_a"].clone();
    p["pi_a"] = p["pi_c"].clone();
    p["pi_c"] = a;
    assert_eq!(v.verify(&p.to_string(), &signals(&["1", "18"])), Ok(false));
}

#[test]
fn rejects_a_proof_under_a_different_key() {
    // Same circuit shape, different key: delta replaced by gamma.
    let mut vk: Value = serde_json::from_str(&vk_json()).unwrap();
    vk["vk_delta_2"] = vk["vk_gamma_2"].clone();
    let other = Verifier::from_snarkjs_json(&vk.to_string()).expect("still a well-formed key");
    let proof = prove(25);
    assert_eq!(
        other.verify(&proof.proof_json(), &proof.public_signals),
        Ok(false)
    );
}

// ------------------------------------------------------------------ malformed input (Err)

#[test]
fn malformed_proofs_are_errors_not_false() {
    let v = verifier();
    let good = prove(25).proof_json();
    let ok_signals = signals(&["1", "18"]);
    let cases = [
        "not json".to_string(),
        "{}".to_string(),
        // y + 1 (almost surely off the curve) and a non-canonical coordinate.
        proof_with_pi_a(&good, 1, "1"),
        proof_with_pi_a(&good, 0, "007"),
        // A projective z other than 1.
        proof_with_pi_a(&good, 2, "2"),
    ];
    for proof in cases {
        assert!(
            matches!(
                v.verify(&proof, &ok_signals),
                Err(VerificationError::InvalidProof(_))
            ),
            "{proof}"
        );
    }
}

#[test]
fn malformed_public_signals_are_errors_not_false() {
    let v = verifier();
    let proof = prove(25).proof_json();
    // The BN254 scalar field modulus itself is not canonical.
    let modulus = "21888242871839275222246405745257275088548364400416034343698204186575808495617";
    for bad in [
        signals(&["1"]),
        signals(&["1", "18", "0"]),
        signals(&[]),
        signals(&["01", "18"]),
        signals(&["-1", "18"]),
        signals(&["1", modulus]),
        signals(&["one", "18"]),
    ] {
        assert!(
            matches!(
                v.verify(&proof, &bad),
                Err(VerificationError::InvalidPublicSignals(_))
            ),
            "{bad:?}"
        );
    }
}

#[test]
fn malformed_keys_are_rejected() {
    let ic_off_curve = {
        let mut vk: Value = serde_json::from_str(&vk_json()).unwrap();
        vk["IC"][1][1] = Value::String("1".into());
        vk.to_string()
    };
    let cases = [
        "not json".to_string(),
        vk_with("protocol", Some(Value::String("plonk".into()))),
        vk_with("protocol", None),
        vk_with("curve", Some(Value::String("bls12381".into()))),
        vk_with("nPublic", Some(Value::from(3))),
        vk_with("nPublic", None),
        vk_with("IC", Some(Value::Array(vec![]))),
        vk_with("vk_alpha_1", None),
        ic_off_curve,
    ];
    for key in cases {
        assert!(
            matches!(
                Verifier::from_snarkjs_json(&key),
                Err(VerificationError::InvalidVerificationKey(_))
            ),
            "{}",
            key.chars().take(120).collect::<String>()
        );
    }
}
