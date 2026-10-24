//! Phase 5d: curve points decoded from JSON or bytes are validated before they
//! can reach a pairing.
//!
//! Vectors are deterministic. The off-curve points are valid coordinates with
//! one value nudged; the wrong-subgroup G2 point is found by scanning x = (i, 1)
//! upward until a point lies on the twist curve but outside the prime-order
//! subgroup (the same i each run).
//!
//! BN254's G1 has cofactor 1, so every on-curve G1 point is in the subgroup and
//! there is no "wrong-subgroup G1" vector to construct. G2 has a large
//! cofactor, so there the subgroup check is real.
#![cfg(not(target_os = "ios"))]

use ark_bn254::{Fq, Fq2, G2Affine};
use ark_ff::PrimeField;
use ark_serialize::CanonicalSerialize;
use laniakea_core::backend::prover::parse_vk_from_json;
use laniakea_core::{
    parse_zkey_to_artifact, Groth16Backend, LaniakeaError, PointFault, ProofResult, Prover,
    ZkBackend,
};
use num_bigint::BigInt;
use serde_json::{json, Value};
use std::fs;
use std::str::FromStr;

const CIRCUITS: &str = "../../circuits";
/// The BN254 base field modulus.
const FQ_MODULUS: &str =
    "21888242871839275222246405745257275088696311157297823662689037894645226208583";

fn prover() -> Prover {
    let zkey = fs::read(format!("{CIRCUITS}/age_check/age_check_final.zkey")).unwrap();
    let wasm = fs::read(format!("{CIRCUITS}/age_check/age_check_js/age_check.wasm")).unwrap();
    let artifact = parse_zkey_to_artifact(&zkey).unwrap();
    Prover::new(&artifact.to_bytes(), &wasm).unwrap()
}

fn prove(age: i64) -> ProofResult {
    prover()
        .prove(&[
            ("age".to_string(), vec![BigInt::from(age)]),
            ("threshold".to_string(), vec![BigInt::from(18)]),
        ])
        .unwrap()
}

fn vk_json() -> Value {
    let text = fs::read_to_string(format!("{CIRCUITS}/age_check/verification_key.json")).unwrap();
    serde_json::from_str(&text).unwrap()
}

fn vk_bytes_from(vk: &Value) -> Vec<u8> {
    let mut bytes = Vec::new();
    parse_vk_from_json(&vk.to_string())
        .expect("valid vk")
        .serialize_uncompressed(&mut bytes)
        .unwrap();
    bytes
}

type Mutation = (&'static str, Box<dyn Fn(&mut Value)>);

fn verify(proof: &Value, signals: &str, vk_bytes: &[u8]) -> Result<bool, LaniakeaError> {
    Groth16Backend.verify(&proof.to_string(), signals, vk_bytes)
}

fn proof_json(r: &ProofResult) -> Value {
    serde_json::from_str(&r.proof_json()).unwrap()
}

/// Canonical decimal of an Fq element (`Display` prints zero as an empty string).
fn dec(f: &Fq) -> String {
    f.into_bigint().to_string()
}

/// `s + 1` in Fq, as a decimal string: a different coordinate that is still canonical.
fn bump(s: &str) -> String {
    dec(&(Fq::from_str(s).unwrap() + Fq::from(1u64)))
}

/// A point on the G2 twist curve that is not in the prime-order subgroup,
/// as snarkjs-style `[[x0,x1],[y0,y1],["1","0"]]`.
fn g2_outside_subgroup() -> Value {
    for i in 0u64.. {
        let x = Fq2::new(Fq::from(i), Fq::from(1u64));
        if let Some(p) = G2Affine::get_point_from_x_unchecked(x, false) {
            if p.is_on_curve() && !p.is_in_correct_subgroup_assuming_on_curve() {
                return json!([
                    [dec(&p.x.c0), dec(&p.x.c1)],
                    [dec(&p.y.c0), dec(&p.y.c1)],
                    ["1", "0"]
                ]);
            }
        }
    }
    unreachable!()
}

fn assert_point_fault(r: Result<bool, LaniakeaError>, what: &str, fault: PointFault) {
    match r {
        Err(LaniakeaError::InvalidPoint { what: w, fault: f }) => {
            assert_eq!((w.as_str(), f), (what, fault))
        }
        other => panic!("expected InvalidPoint({what}, {fault:?}), got {other:?}"),
    }
}

// ------------------------------------------------------------ proof points

#[test]
fn a_valid_proof_still_verifies() {
    let r = prove(25);
    let vk = vk_bytes_from(&vk_json());
    assert!(verify(&proof_json(&r), &r.public_signals_json(), &vk).unwrap());
}

#[test]
fn a_well_formed_but_wrong_proof_is_ok_false_not_an_error() {
    // A from one proof, B and C from another: every point is valid, the
    // pairing equation does not hold.
    let (r1, r2) = (prove(25), prove(30));
    let (p1, mut p2) = (proof_json(&r1), proof_json(&r2));
    p2["pi_a"] = p1["pi_a"].clone();
    let vk = vk_bytes_from(&vk_json());
    assert!(!verify(&p2, &r1.public_signals_json(), &vk).unwrap());
}

#[test]
fn off_curve_g1_proof_points_are_rejected() {
    let r = prove(25);
    let vk = vk_bytes_from(&vk_json());
    for (key, what) in [("pi_a", "proof.a"), ("pi_c", "proof.c")] {
        let mut p = proof_json(&r);
        let y = bump(p[key][1].as_str().unwrap());
        p[key][1] = json!(y);
        assert_point_fault(
            verify(&p, &r.public_signals_json(), &vk),
            what,
            PointFault::NotOnCurve,
        );
    }
}

#[test]
fn off_curve_g2_proof_point_is_rejected() {
    let r = prove(25);
    let mut p = proof_json(&r);
    let y0 = bump(p["pi_b"][1][0].as_str().unwrap());
    p["pi_b"][1][0] = json!(y0);
    assert_point_fault(
        verify(&p, &r.public_signals_json(), &vk_bytes_from(&vk_json())),
        "proof.b",
        PointFault::NotOnCurve,
    );
}

#[test]
fn g2_proof_point_outside_the_subgroup_is_rejected() {
    let r = prove(25);
    let mut p = proof_json(&r);
    p["pi_b"] = g2_outside_subgroup();
    assert_point_fault(
        verify(&p, &r.public_signals_json(), &vk_bytes_from(&vk_json())),
        "proof.b",
        PointFault::NotInSubgroup,
    );
}

#[test]
fn the_all_zero_point_is_rejected_not_treated_as_infinity() {
    let r = prove(25);
    let mut p = proof_json(&r);
    p["pi_a"] = json!(["0", "0", "1"]);
    assert_point_fault(
        verify(&p, &r.public_signals_json(), &vk_bytes_from(&vk_json())),
        "proof.a",
        PointFault::NotOnCurve,
    );
}

#[test]
fn malformed_proof_coordinates_are_serialization_errors_and_never_panic() {
    let r = prove(25);
    let vk = vk_bytes_from(&vk_json());
    let signals = r.public_signals_json();
    let bad_coords = [
        json!(FQ_MODULUS), // not reduced: equals 0 mod p, but not canonical
        json!("-1"),
        json!(""),
        json!("0x10"),
        json!("abc"),
        json!("1".repeat(5000)),
        json!(12345), // a number, not a string
        Value::Null,
    ];
    for bad in bad_coords {
        let mut p = proof_json(&r);
        p["pi_a"][0] = bad.clone();
        assert!(
            matches!(
                verify(&p, &signals, &vk),
                Err(LaniakeaError::Serialization(_))
            ),
            "G1 x = {bad}"
        );
        let mut p = proof_json(&r);
        p["pi_b"][0][1] = bad.clone();
        assert!(
            matches!(
                verify(&p, &signals, &vk),
                Err(LaniakeaError::Serialization(_))
            ),
            "G2 x1 = {bad}"
        );
    }
}

#[test]
fn malformed_proof_shapes_are_serialization_errors() {
    let r = prove(25);
    let vk = vk_bytes_from(&vk_json());
    let signals = r.public_signals_json();
    let shapes: Vec<Mutation> = vec![
        ("G1 not an array", Box::new(|p| p["pi_a"] = json!("1"))),
        ("G1 one element", Box::new(|p| p["pi_a"] = json!(["1"]))),
        (
            "G1 projective z is not 1",
            Box::new(|p| p["pi_a"][2] = json!("2")),
        ),
        (
            "G2 projective z is not [1,0]",
            Box::new(|p| p["pi_b"][2] = json!(["2", "0"])),
        ),
        (
            "G2 coordinate not a pair",
            Box::new(|p| p["pi_b"][0] = json!(["1"])),
        ),
        (
            "missing pi_c",
            Box::new(|p| {
                p.as_object_mut().unwrap().remove("pi_c");
            }),
        ),
    ];
    for (name, mutate) in shapes {
        let mut p = proof_json(&r);
        mutate(&mut p);
        assert!(
            matches!(
                verify(&p, &signals, &vk),
                Err(LaniakeaError::Serialization(_))
            ),
            "{name}"
        );
    }
}

// --------------------------------------------------------- verifying key

#[test]
fn the_snarkjs_verification_key_still_parses() {
    let vk = parse_vk_from_json(&vk_json().to_string()).expect("valid vk");
    assert_eq!(vk.gamma_abc_g1.len(), 3);
}

fn vk_error(vk: &Value) -> LaniakeaError {
    parse_vk_from_json(&vk.to_string()).expect_err("vk should be rejected")
}

fn assert_vk_fault(vk: &Value, what: &str, fault: PointFault) {
    match vk_error(vk) {
        LaniakeaError::InvalidPoint { what: w, fault: f } => {
            assert_eq!((w.as_str(), f), (what, fault))
        }
        other => panic!("expected InvalidPoint({what}), got {other:?}"),
    }
}

#[test]
fn off_curve_vk_points_are_rejected() {
    let mut vk = vk_json();
    let y = bump(vk["vk_alpha_1"][1].as_str().unwrap());
    vk["vk_alpha_1"][1] = json!(y);
    assert_vk_fault(&vk, "vk.alpha_1", PointFault::NotOnCurve);

    for (key, what) in [
        ("vk_beta_2", "vk.beta_2"),
        ("vk_gamma_2", "vk.gamma_2"),
        ("vk_delta_2", "vk.delta_2"),
    ] {
        let mut vk = vk_json();
        let x0 = bump(vk[key][0][0].as_str().unwrap());
        vk[key][0][0] = json!(x0);
        assert_vk_fault(&vk, what, PointFault::NotOnCurve);
    }

    let mut vk = vk_json();
    let y = bump(vk["IC"][2][1].as_str().unwrap());
    vk["IC"][2][1] = json!(y);
    assert_vk_fault(&vk, "vk.IC[2]", PointFault::NotOnCurve);
}

#[test]
fn vk_g2_points_outside_the_subgroup_are_rejected() {
    for (key, what) in [
        ("vk_beta_2", "vk.beta_2"),
        ("vk_gamma_2", "vk.gamma_2"),
        ("vk_delta_2", "vk.delta_2"),
    ] {
        let mut vk = vk_json();
        vk[key] = g2_outside_subgroup();
        assert_vk_fault(&vk, what, PointFault::NotInSubgroup);
    }
}

#[test]
fn malformed_vk_coordinates_and_shapes_are_serialization_errors() {
    let mutations: Vec<Mutation> = vec![
        (
            "non-numeric",
            Box::new(|v| v["vk_alpha_1"][0] = json!("abc")),
        ),
        (
            "unreduced",
            Box::new(|v| v["vk_alpha_1"][0] = json!(FQ_MODULUS)),
        ),
        (
            "number not string",
            Box::new(|v| v["vk_alpha_1"][1] = json!(7)),
        ),
        (
            "G2 component",
            Box::new(|v| v["vk_beta_2"][0][0] = json!("-3")),
        ),
        (
            "missing alpha",
            Box::new(|v| {
                v.as_object_mut().unwrap().remove("vk_alpha_1");
            }),
        ),
        ("IC not an array", Box::new(|v| v["IC"] = json!("x"))),
        (
            "IC entry malformed",
            Box::new(|v| v["IC"][0] = json!(["1", "2"])),
        ),
        (
            "G1 z is not 1",
            Box::new(|v| v["vk_alpha_1"][2] = json!("0")),
        ),
        (
            "G2 z is not [1,0]",
            Box::new(|v| v["vk_beta_2"][2] = json!(["0", "0"])),
        ),
    ];
    for (name, mutate) in mutations {
        let mut vk = vk_json();
        mutate(&mut vk);
        assert!(
            matches!(vk_error(&vk), LaniakeaError::Serialization(_)),
            "{name}: {:?}",
            vk_error(&vk)
        );
    }
}

#[test]
fn a_corrupted_binary_verifying_key_is_rejected_on_load() {
    // `verify` takes the key as ark-serialize bytes; deserialization validates.
    // Layout: alpha_g1 starts with x then y, 32 little-endian bytes each.
    let r = prove(25);
    let mut vk = vk_bytes_from(&vk_json());
    vk[32] ^= 1; // perturb y of alpha_g1 -> off the curve
    let p = proof_json(&r);
    assert!(
        matches!(
            verify(&p, &r.public_signals_json(), &vk),
            Err(LaniakeaError::ArtifactLoad(_))
        ),
        "off-curve key bytes must not load"
    );
}

#[test]
fn public_signals_must_be_canonical_field_elements() {
    // r + 1 would otherwise be silently reduced to 1, so the same statement
    // would have several encodings.
    const FR_MODULUS_PLUS_ONE: &str =
        "21888242871839275222246405745257275088548364400416034343698204186575808495618";
    let r = prove(25);
    let vk = vk_bytes_from(&vk_json());
    for bad in [
        format!(r#"["{FR_MODULUS_PLUS_ONE}","18"]"#),
        r#"["01","18"]"#.to_string(),
        r#"["-1","18"]"#.to_string(),
    ] {
        assert!(
            matches!(
                verify(&proof_json(&r), &bad, &vk),
                Err(LaniakeaError::Serialization(_))
            ),
            "{bad}"
        );
    }
}
