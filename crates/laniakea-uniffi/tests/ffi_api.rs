//! Phase 6a: the Rust side of the Swift API, end to end on age_check.
//!
//! Proofs are verified against `verification_key.json` (from the snarkjs
//! ceremony), not the key inside the artifact. Needs `parse_zkey_to_artifact`,
//! which is desktop-only.
#![cfg(not(target_os = "ios"))]

use ark_serialize::CanonicalSerialize;
use laniakea_core::backend::prover::parse_vk_from_json;
use laniakea_core::{parse_zkey_to_artifact, Groth16Backend, ZkBackend};
use laniakea_uniffi::{CircuitInput, LaniakeaProver, ProofResult, ProverError};
use std::fs;
use std::sync::Arc;

const CIRCUITS: &str = "../../circuits";

fn wasm() -> Vec<u8> {
    fs::read(format!("{CIRCUITS}/age_check/age_check_js/age_check.wasm")).unwrap()
}

fn artifact_bytes() -> Vec<u8> {
    let zkey = fs::read(format!("{CIRCUITS}/age_check/age_check_final.zkey")).unwrap();
    parse_zkey_to_artifact(&zkey).unwrap().to_bytes()
}

fn prover() -> Arc<LaniakeaProver> {
    LaniakeaProver::new(artifact_bytes(), wasm()).expect("build prover")
}

fn input(name: &str, values: &[&str]) -> CircuitInput {
    CircuitInput {
        name: name.into(),
        values: values.iter().map(|s| s.to_string()).collect(),
    }
}

fn age(age: &str, threshold: &str) -> Vec<CircuitInput> {
    vec![input("age", &[age]), input("threshold", &[threshold])]
}

fn independent_vk_bytes() -> Vec<u8> {
    let json = fs::read_to_string(format!("{CIRCUITS}/age_check/verification_key.json")).unwrap();
    let mut bytes = Vec::new();
    parse_vk_from_json(&json)
        .unwrap()
        .serialize_uncompressed(&mut bytes)
        .unwrap();
    bytes
}

fn verifies(r: &ProofResult) -> bool {
    Groth16Backend
        .verify(
            &r.proof_json,
            &serde_json::to_string(&r.public_signals).unwrap(),
            &independent_vk_bytes(),
        )
        .expect("verification ran")
}

#[test]
fn wrapper_is_send_and_sync() {
    fn assert_send_sync<T: Send + Sync>() {}
    assert_send_sync::<LaniakeaProver>();
}

#[test]
fn proves_age_check_and_verifies_against_the_independent_key() {
    let p = prover();
    assert_eq!(p.num_public_signals(), 2);

    let r = p.prove(age("25", "18")).expect("prove");
    // Outputs first, then public inputs: [out, threshold].
    assert_eq!(r.public_signals, ["1", "18"]);
    assert!(verifies(&r));

    let v: serde_json::Value = serde_json::from_str(&r.proof_json).unwrap();
    assert_eq!(v["protocol"], "groth16");
}

#[test]
fn a_valid_proof_can_carry_out_zero() {
    let r = prover().prove(age("10", "18")).expect("prove");
    assert_eq!(r.public_signals, ["0", "18"]);
    assert!(
        verifies(&r),
        "valid proof, but out says the condition fails"
    );
}

#[test]
fn input_order_does_not_change_the_result() {
    let mut reversed = age("25", "18");
    reversed.reverse();
    let r = prover().prove(reversed).expect("prove");
    assert_eq!(r.public_signals, ["1", "18"]);
}

#[test]
fn invalid_decimals_are_typed_errors_with_signal_index_and_value() {
    let p = prover();
    let long = "7".repeat(100);
    let cases: Vec<(Vec<CircuitInput>, &str, u32, String)> = vec![
        (age("-1", "18"), "age", 0, "-1".into()),
        (age("25", "018"), "threshold", 0, "018".into()),
        (age("25", ""), "threshold", 0, "".into()),
        (age("25", "1e1"), "threshold", 0, "1e1".into()),
        (age(" 25", "18"), "age", 0, " 25".into()),
        // Equal to the scalar modulus r: must not be reduced to 0.
        (
            age(
                "21888242871839275222246405745257275088548364400416034343698204186575808495617",
                "18",
            ),
            "age",
            0,
            "21888242871839275222246405745257…".into(),
        ),
        // Index within an array-valued input, and truncation of long values.
        (
            vec![input("age", &["25", &long]), input("threshold", &["18"])],
            "age",
            1,
            format!("{}…", "7".repeat(32)),
        ),
    ];
    for (inputs, signal, index, value) in cases {
        match p.prove(inputs) {
            Err(ProverError::InvalidInputValue {
                signal: s,
                index: i,
                value: v,
            }) => assert_eq!((s, i, v), (signal.to_string(), index, value)),
            other => panic!("expected InvalidInputValue for {signal}[{index}], got {other:?}"),
        }
    }
}

#[test]
fn witness_failures_map_to_distinct_variants() {
    let p = prover();

    assert!(matches!(
        p.prove(age("300", "18")),
        Err(ProverError::AssertionFailed { .. })
    ));
    assert!(matches!(
        p.prove(vec![input("age", &["25"])]),
        Err(ProverError::MissingInputs {
            set: 1,
            expected: 2
        })
    ));
    assert!(matches!(
        p.prove(vec![]),
        Err(ProverError::MissingInputs {
            set: 0,
            expected: 2
        })
    ));
    assert!(matches!(
        p.prove([age("25", "18"), vec![input("nope", &["1"])]].concat()),
        Err(ProverError::UnknownSignal { name }) if name == "nope"
    ));
    assert!(matches!(
        p.prove([age("25", "18"), age("26", "18")].concat()),
        Err(ProverError::DuplicateSignal { name }) if name == "age"
    ));
    assert!(matches!(
        p.prove(vec![input("age", &["25", "26"]), input("threshold", &["18"])]),
        Err(ProverError::InputSize { signal, expected: 1, got: 2 }) if signal == "age"
    ));
}

#[test]
fn a_failed_attempt_does_not_prevent_a_later_success() {
    let p = prover();
    assert!(p.prove(age("300", "18")).is_err());
    assert!(p.prove(age("x", "18")).is_err());
    let r = p.prove(age("25", "18")).expect("prove after failures");
    assert!(verifies(&r));
}

#[test]
fn construction_errors_are_typed() {
    let art = artifact_bytes();
    let wasm = wasm();

    assert!(matches!(
        LaniakeaProver::new(vec![], wasm.clone()),
        Err(ProverError::ArtifactLoad { .. })
    ));
    assert!(matches!(
        LaniakeaProver::new(art[..art.len() / 2].to_vec(), wasm.clone()),
        Err(ProverError::ArtifactLoad { .. })
    ));
    assert!(matches!(
        LaniakeaProver::new(art.clone(), b"not wasm".to_vec()),
        Err(ProverError::InvalidCircuitModule { .. })
    ));
    // A valid module without the Circom exports.
    assert!(matches!(
        LaniakeaProver::new(art.clone(), b"\0asm\x01\0\0\0".to_vec()),
        Err(ProverError::InvalidCircuitModule { .. })
    ));
    // A different circuit's WASM: wire counts disagree with the artifact.
    let other = fs::read(format!(
        "{CIRCUITS}/witness_probe/witness_probe_js/witness_probe.wasm"
    ))
    .unwrap();
    assert!(matches!(
        LaniakeaProver::new(art, other),
        Err(ProverError::InvalidArtifact { .. })
    ));
}

#[test]
fn one_prover_serves_concurrent_calls() {
    let p = prover();
    std::thread::scope(|s| {
        let handles: Vec<_> = [("25", "18", "1"), ("10", "18", "0"), ("30", "21", "1")]
            .into_iter()
            .map(|(a, t, out)| {
                let p = Arc::clone(&p);
                s.spawn(move || (out, p.prove(age(a, t)).expect("prove")))
            })
            .collect();
        for h in handles {
            let (out, r) = h.join().unwrap();
            assert_eq!(r.public_signals[0], out);
            assert!(verifies(&r));
        }
    });
}
