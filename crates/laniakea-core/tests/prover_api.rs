//! Phase 5c: the high-level `Prover` API, end to end on the age_check circuit.
//!
//! Proofs are verified against `verification_key.json` (produced by snarkjs from
//! the same ceremony), not against the verifying key embedded in the artifact,
//! so a self-consistent but wrong artifact could not pass.
#![cfg(not(target_os = "ios"))]

use ark_serialize::CanonicalSerialize;
use laniakea_core::backend::prover::parse_vk_from_json;
use laniakea_core::{
    parse_zkey_to_artifact, CircuitLoadError, Groth16Backend, LaniakeaError, ProofResult, Prover,
    ProvingArtifact, ProvingArtifacts, WitnessError, ZkBackend,
};
use num_bigint::BigInt;
use std::fs;

const CIRCUITS: &str = "../../circuits";

type Inputs = Vec<(String, Vec<BigInt>)>;

fn wasm() -> Vec<u8> {
    fs::read(format!("{CIRCUITS}/age_check/age_check_js/age_check.wasm")).expect("read wasm")
}

fn zkey() -> Vec<u8> {
    fs::read(format!("{CIRCUITS}/age_check/age_check_final.zkey")).expect("read zkey")
}

fn artifact() -> ProvingArtifact {
    parse_zkey_to_artifact(&zkey()).expect("parse zkey")
}

fn prover() -> Prover {
    Prover::new(&artifact().to_bytes(), &wasm()).expect("build prover")
}

type Case = (&'static str, Inputs, fn(&WitnessError) -> bool);

fn age_inputs(age: i64, threshold: i64) -> Inputs {
    vec![
        ("age".to_string(), vec![BigInt::from(age)]),
        ("threshold".to_string(), vec![BigInt::from(threshold)]),
    ]
}

/// The independent verifying key, in the binary form `Groth16Backend` takes.
fn independent_vk_bytes() -> Vec<u8> {
    let json = fs::read_to_string(format!("{CIRCUITS}/age_check/verification_key.json"))
        .expect("read verification_key.json");
    let mut bytes = Vec::new();
    parse_vk_from_json(&json)
        .expect("parse vk")
        .serialize_uncompressed(&mut bytes)
        .expect("serialize vk");
    bytes
}

fn verifies(result: &ProofResult) -> bool {
    verifies_with_signals(result, &result.public_signals_json())
}

fn verifies_with_signals(result: &ProofResult, public_signals_json: &str) -> bool {
    Groth16Backend
        .verify(
            &result.proof_json(),
            public_signals_json,
            &independent_vk_bytes(),
        )
        .expect("verification ran")
}

// ------------------------------------------------------------------ success

#[test]
fn proves_age_check_and_the_proof_verifies_against_the_independent_key() {
    let result = prover().prove(&age_inputs(25, 18)).expect("prove");

    // Order: public outputs first, then public inputs: [out, threshold].
    assert_eq!(result.public_signals, ["1", "18"]);
    assert!(verifies(&result));
}

#[test]
fn a_valid_proof_does_not_establish_the_age_condition() {
    // age < threshold is provable too: the circuit computes `out = 0` and the
    // proof for that is perfectly valid. The caller must read `out`.
    let result = prover().prove(&age_inputs(10, 18)).expect("prove");

    assert!(verifies(&result), "the proof is valid");
    assert_eq!(
        result.public_signals[0], "0",
        "but out says the condition is false"
    );
    assert_eq!(
        result.public_signals,
        ["0", "18"],
        "zero is rendered as \"0\", not \"\""
    );
}

#[test]
fn public_signals_are_bound_to_the_proof() {
    let result = prover().prove(&age_inputs(10, 18)).expect("prove");
    // Claiming out = 1 for the proof of out = 0 must not verify.
    assert!(!verifies_with_signals(&result, r#"["1","18"]"#));
    // Nor a different threshold.
    assert!(!verifies_with_signals(&result, r#"["0","19"]"#));
}

#[test]
fn proof_json_has_the_snarkjs_layout() {
    let result = prover().prove(&age_inputs(25, 18)).expect("prove");
    let v: serde_json::Value = serde_json::from_str(&result.proof_json()).unwrap();
    assert_eq!(v["protocol"], "groth16");
    assert_eq!(v["curve"], "bn128");
    assert_eq!(v["pi_a"].as_array().unwrap().len(), 3);
    assert_eq!(v["pi_a"][2], "1");
    assert_eq!(v["pi_b"].as_array().unwrap().len(), 3);
    assert_eq!(v["pi_b"][2], serde_json::json!(["1", "0"]));
    assert_eq!(v["pi_c"][2], "1");
    assert_eq!(result.public_signals_json(), r#"["1","18"]"#);
}

#[test]
fn prover_reports_circuit_dimensions() {
    let p = prover();
    assert_eq!(p.witness_len(), 15);
    assert_eq!(p.num_public_signals(), 2);
}

#[test]
fn prover_is_send_and_sync() {
    fn assert_send_sync<T: Send + Sync>() {}
    assert_send_sync::<Prover>();
}

#[test]
fn one_prover_serves_concurrent_calls() {
    let p = prover();
    std::thread::scope(|s| {
        let handles: Vec<_> = [(25, 18), (10, 18), (30, 21)]
            .into_iter()
            .map(|(age, thr)| {
                let p = &p;
                s.spawn(move || (age >= thr, p.prove(&age_inputs(age, thr)).expect("prove")))
            })
            .collect();
        for h in handles {
            let (expected_out, result) = h.join().unwrap();
            assert_eq!(
                result.public_signals[0],
                if expected_out { "1" } else { "0" }
            );
            assert!(verifies(&result));
        }
    });
}

// ------------------------------------------------------- repeated use

#[test]
fn repeated_calls_and_failure_followed_by_success() {
    let p = prover();

    let first = p.prove(&age_inputs(25, 18)).expect("first");

    // A circuit abort in the middle of witness generation...
    let err = p.prove(&age_inputs(300, 18)).unwrap_err();
    assert!(
        matches!(
            err,
            LaniakeaError::WitnessGeneration(WitnessError::AssertionFailed { .. })
        ),
        "{err:?}"
    );
    // ...and a rejection before the circuit runs at all.
    let err = p.prove(&[]).unwrap_err();
    assert!(
        matches!(
            err,
            LaniakeaError::WitnessGeneration(WitnessError::MissingInputs { .. })
        ),
        "{err:?}"
    );

    let second = p.prove(&age_inputs(25, 18)).expect("after failures");

    assert_eq!(first.public_signals, second.public_signals);
    assert!(verifies(&first) && verifies(&second));
    // Groth16 proofs are randomised.
    assert_ne!(first.proof, second.proof);
}

// ---------------------------------------------------------- bad inputs

#[test]
fn witness_failures_carry_a_structured_category() {
    let p = prover();
    let cases: Vec<Case> = vec![
        (
            "missing threshold",
            vec![age_inputs(25, 18).remove(0)],
            |e| {
                matches!(
                    e,
                    WitnessError::MissingInputs {
                        set: 1,
                        expected: 2
                    }
                )
            },
        ),
        ("no inputs", vec![], |e| {
            matches!(
                e,
                WitnessError::MissingInputs {
                    set: 0,
                    expected: 2
                }
            )
        }),
        (
            "unknown signal",
            [age_inputs(25, 18), vec![("nope".into(), vec![1.into()])]].concat(),
            |e| matches!(e, WitnessError::UnknownSignal { name } if name == "nope"),
        ),
        (
            "repeated signal",
            [age_inputs(25, 18), age_inputs(26, 18)].concat(),
            |e| matches!(e, WitnessError::DuplicateSignal { name } if name == "age"),
        ),
        (
            "too many values for age",
            vec![
                ("age".into(), vec![25.into(), 26.into()]),
                ("threshold".into(), vec![18.into()]),
            ],
            |e| matches!(e, WitnessError::InputSize { signal, expected: 1, got: 2 } if signal == "age"),
        ),
        (
            // Circom exception code 4 is a failed `assert`.
            "circuit assertion (age exceeds 8 bits)",
            age_inputs(300, 18),
            |e| matches!(e, WitnessError::AssertionFailed { .. }),
        ),
    ];
    for (name, inputs, is_expected) in cases {
        match p.prove(&inputs) {
            Err(LaniakeaError::WitnessGeneration(e)) => {
                assert!(is_expected(&e), "{name}: wrong category: {e:?}")
            }
            other => panic!(
                "{name}: expected WitnessGeneration, got {:?}",
                other.map(|_| "a proof")
            ),
        }
    }
}

#[test]
fn a_failed_witness_does_not_prevent_a_later_valid_proof() {
    let p = prover();
    for bad in [age_inputs(300, 18), vec![]] {
        assert!(matches!(
            p.prove(&bad),
            Err(LaniakeaError::WitnessGeneration(_))
        ));
        let ok = p.prove(&age_inputs(25, 18)).expect("prove after failure");
        assert_eq!(ok.public_signals, ["1", "18"]);
        assert!(verifies(&ok));
    }
}

// ------------------------------------------------- invalid construction

#[test]
fn invalid_serialized_artifacts_are_rejected_at_construction() {
    let bytes = artifact().to_bytes();
    let wasm = wasm();

    for (name, input) in [
        ("empty", Vec::new()),
        ("truncated", bytes[..bytes.len() / 2].to_vec()),
        ("trailing byte", [bytes.clone(), vec![0]].concat()),
    ] {
        assert!(
            matches!(
                Prover::new(&input, &wasm),
                Err(LaniakeaError::ArtifactLoad(_))
            ),
            "{name}"
        );
    }
}

#[test]
fn structurally_inconsistent_artifacts_are_rejected_at_construction() {
    let wasm = wasm();
    let mut broken = artifact();
    broken.proving_key.h_query.pop();

    // In-memory route.
    assert!(matches!(
        Prover::from_artifact(broken.clone(), &wasm),
        Err(LaniakeaError::InvalidArtifact(_))
    ));
    // Serialized route.
    assert!(matches!(
        Prover::new(&broken.to_bytes(), &wasm),
        Err(LaniakeaError::InvalidArtifact(_))
    ));
}

#[test]
fn unusable_wasm_is_rejected_at_construction() {
    let bytes = artifact().to_bytes();
    let err = Prover::new(&bytes, b"not wasm").err().expect("rejected");
    assert!(
        matches!(
            &err,
            LaniakeaError::CircuitLoad(CircuitLoadError::InvalidModule(_))
        ),
        "{err:?}"
    );
    assert!(matches!(
        Prover::new(&bytes, &[]),
        Err(LaniakeaError::CircuitLoad(_))
    ));
    // A bad artifact is still an artifact error, not a circuit error.
    assert!(matches!(
        Prover::new(&[], &wasm()),
        Err(LaniakeaError::ArtifactLoad(_))
    ));
}

#[test]
fn wasm_from_a_different_circuit_is_rejected_at_construction() {
    // witness_probe has 10 wires; the age_check artifact expects 15.
    let other = fs::read(format!(
        "{CIRCUITS}/witness_probe/witness_probe_js/witness_probe.wasm"
    ))
    .unwrap();
    let err = Prover::new(&artifact().to_bytes(), &other)
        .err()
        .expect("rejected");
    match err {
        LaniakeaError::InvalidArtifact(m) => assert!(m.contains("10") && m.contains("15"), "{m}"),
        other => panic!("expected InvalidArtifact, got {other:?}"),
    }
}

// ------------------------------------------------- the legacy backend

#[test]
fn legacy_backend_prove_uses_the_validated_path_and_needs_no_working_directory() {
    // It used to read `circuits/age_check/age_check.r1cs` relative to the
    // current directory, which does not exist from a test's working directory.
    let output = Groth16Backend
        .prove(
            &ProvingArtifacts {
                zkey_bytes: zkey(),
                wasm_bytes: wasm(),
            },
            &age_inputs(10, 18),
        )
        .expect("legacy prove");

    assert_eq!(output.public_signals_json, r#"["0","18"]"#);
    assert!(Groth16Backend
        .verify(
            &output.proof_json,
            &output.public_signals_json,
            &independent_vk_bytes()
        )
        .unwrap());
}
