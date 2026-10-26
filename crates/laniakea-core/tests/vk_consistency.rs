//! Consistency of the age_check verification key across the repository's artifacts.
//!
//! Three things carry (or are derived from) the Groth16 verifying key:
//!   * `age_check_final.zkey`: the source of truth; its parse embeds `proving_key.vk`;
//!   * `examples/ios-age-app/AgeCheckApp/Resources/age_check.artifact`: the file the
//!     app bundles, a serialized `ProvingArtifact` that also embeds `proving_key.vk`;
//!   * `circuits/age_check/verification_key.json`: the snarkjs-format key that
//!     verifiers (snarkjs, `Groth16Backend::verify`) are given.
//!
//! A proof made from a proving key whose `vk` differs from the verifier's key does
//! not verify, but only as an opaque "false". These tests compare the keys directly
//! and name the component that differs. They do NOT say the keys come from a sound
//! setup, or that the circuit expresses the intended policy.
//!
//! Independent derivation of the JSON key from the zkey by snarkjs is checked by
//! `scripts/check-vk-consistency.sh`, not here.
#![cfg(not(target_os = "ios"))]

use ark_bn254::{Bn254, Fq12};
use ark_groth16::{Groth16, VerifyingKey};
use ark_snark::SNARK;
use laniakea_core::backend::prover::parse_vk_from_json;
use laniakea_core::{parse_zkey_to_artifact, ProvingArtifact};
use serde_json::Value;
use std::fs;

const ZKEY: &str = "../../circuits/age_check/age_check_final.zkey";
const VK_JSON: &str = "../../circuits/age_check/verification_key.json";
const BUNDLED: &str = "../../examples/ios-age-app/AgeCheckApp/Resources/age_check.artifact";

fn read(path: &str) -> Vec<u8> {
    fs::read(path).unwrap_or_else(|e| panic!("cannot read {path}: {e}"))
}

fn json_vk_text() -> String {
    String::from_utf8(read(VK_JSON)).expect("verification_key.json is not UTF-8")
}

fn json_vk() -> VerifyingKey<Bn254> {
    parse_vk_from_json(&json_vk_text())
        .expect("verification_key.json does not parse as a valid key")
}

/// Names of the components that differ; empty when the keys are identical.
fn vk_differences(a: &VerifyingKey<Bn254>, b: &VerifyingKey<Bn254>) -> Vec<String> {
    let mut d = Vec::new();
    if a.alpha_g1 != b.alpha_g1 {
        d.push("alpha_g1".to_string());
    }
    if a.beta_g2 != b.beta_g2 {
        d.push("beta_g2".to_string());
    }
    if a.gamma_g2 != b.gamma_g2 {
        d.push("gamma_g2".to_string());
    }
    if a.delta_g2 != b.delta_g2 {
        d.push("delta_g2".to_string());
    }
    if a.gamma_abc_g1.len() != b.gamma_abc_g1.len() {
        d.push(format!(
            "IC length ({} vs {})",
            a.gamma_abc_g1.len(),
            b.gamma_abc_g1.len()
        ));
    } else {
        for (i, (x, y)) in a.gamma_abc_g1.iter().zip(&b.gamma_abc_g1).enumerate() {
            if x != y {
                d.push(format!("IC[{i}]"));
            }
        }
    }
    d
}

fn assert_same_vk(what_a: &str, a: &VerifyingKey<Bn254>, what_b: &str, b: &VerifyingKey<Bn254>) {
    let diff = vk_differences(a, b);
    assert!(
        diff.is_empty(),
        "verifying key mismatch between {what_a} and {what_b}; differing components: {}",
        diff.join(", ")
    );
}

#[test]
fn the_zkeys_embedded_key_equals_verification_key_json() {
    let artifact = parse_zkey_to_artifact(&read(ZKEY)).expect("parse zkey");
    assert_same_vk(
        "age_check_final.zkey",
        &artifact.proving_key.vk,
        "verification_key.json",
        &json_vk(),
    );
}

#[test]
fn the_bundled_artifacts_embedded_key_equals_verification_key_json() {
    let bundled = ProvingArtifact::from_bytes(&read(BUNDLED)).expect("bundled artifact decodes");
    assert_same_vk(
        "the bundled age_check.artifact",
        &bundled.proving_key.vk,
        "verification_key.json",
        &json_vk(),
    );
}

#[test]
fn the_bundled_artifact_is_the_one_derived_from_the_zkey() {
    let bytes = read(BUNDLED);
    let bundled = ProvingArtifact::from_bytes(&bytes).expect("bundled artifact decodes");
    let fresh = parse_zkey_to_artifact(&read(ZKEY)).expect("parse zkey");
    // Whole-artifact equality: proving key and constraint matrices, not just the vk.
    assert!(
        bundled == fresh,
        "the bundled age_check.artifact differs from the artifact derived from \
         age_check_final.zkey (stale? rerun scripts/prepare-ios-app-resources.sh)"
    );
    // And the exact bytes. Equal values can still have different encodings (the
    // decoder ignores the coordinates of a point at infinity), so a value comparison
    // alone would accept a modified file.
    assert!(
        bytes == fresh.to_bytes(),
        "the bundled age_check.artifact decodes to the right artifact but is not its \
         canonical encoding (rerun scripts/prepare-ios-app-resources.sh)"
    );
}

#[test]
fn the_public_input_count_agrees_everywhere() {
    let artifact = parse_zkey_to_artifact(&read(ZKEY)).expect("parse zkey");
    let json: Value = serde_json::from_str(&json_vk_text()).unwrap();
    let n_public = json["nPublic"].as_u64().expect("nPublic") as usize;
    // The artifact's count and the IC length both include the constant 1.
    assert_eq!(
        artifact.num_public_inputs(),
        n_public + 1,
        "instance variables (incl. the constant 1): zkey vs verification_key.json nPublic + 1"
    );
    assert_eq!(
        json_vk().gamma_abc_g1.len(),
        n_public + 1,
        "IC length vs nPublic + 1"
    );
    assert_eq!(
        artifact.proving_key.vk.gamma_abc_g1.len(),
        n_public + 1,
        "zkey vk IC length vs nPublic + 1"
    );
}

/// snarkjs verifies with the `vk_alphabeta_12` field, not by recomputing it, and
/// `parse_vk_from_json` ignores it. A key whose alpha/beta were changed without
/// refreshing this field would be accepted by one verifier and rejected by the other.
#[test]
fn vk_alphabeta_12_equals_the_pairing_of_alpha_and_beta() {
    let vk = json_vk();
    let pvk = Groth16::<Bn254>::process_vk(&vk).expect("process vk");
    let expected: &Fq12 = &pvk.alpha_g1_beta_g2;

    let json: Value = serde_json::from_str(&json_vk_text()).unwrap();
    let ab = &json["vk_alphabeta_12"];
    let fq = |v: &Value| -> String { v.as_str().expect("decimal string").to_string() };
    let fq2 = |c: &ark_bn254::Fq2, v: &Value| {
        assert_eq!(c.c0.to_string(), fq(&v[0]), "Fq2.c0");
        assert_eq!(c.c1.to_string(), fq(&v[1]), "Fq2.c1");
    };
    for (ark6, json6) in [(&expected.c0, &ab[0]), (&expected.c1, &ab[1])] {
        fq2(&ark6.c0, &json6[0]);
        fq2(&ark6.c1, &json6[1]);
        fq2(&ark6.c2, &json6[2]);
    }
}

// The comparison must actually detect each kind of mismatch.
#[test]
fn the_comparison_detects_a_changed_key() {
    let reference = json_vk();
    assert!(vk_differences(&reference, &reference.clone()).is_empty());

    let mut other = reference.clone();
    other.gamma_abc_g1.swap(1, 2);
    assert_eq!(vk_differences(&reference, &other), ["IC[1]", "IC[2]"]);

    let mut other = reference.clone();
    std::mem::swap(&mut other.gamma_g2, &mut other.delta_g2);
    assert_eq!(vk_differences(&reference, &other), ["gamma_g2", "delta_g2"]);

    let mut other = reference.clone();
    other.alpha_g1 = other.gamma_abc_g1[0];
    assert_eq!(vk_differences(&reference, &other), ["alpha_g1"]);

    let mut other = reference.clone();
    other.gamma_abc_g1.pop();
    assert_eq!(vk_differences(&reference, &other), ["IC length (3 vs 2)"]);
}
