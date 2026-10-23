//! Phase 5b: structural validation of proving artifacts and witnesses.
//!
//! These tests check *structure* (lengths, indices, trailing bytes). They say
//! nothing about cryptographic validity of the keys, which the artifact format
//! gives no way to check.
#![cfg(not(target_os = "ios"))]

use ark_bn254::Fr;
use ark_ff::One;
use ark_serialize::CanonicalSerialize;
use laniakea_core::backend::prover::prove_with_artifact;
use laniakea_core::{parse_zkey_to_artifact, LaniakeaError, ProvingArtifact};
use std::fs;

fn age_check_artifact() -> ProvingArtifact {
    let zkey = fs::read("../../circuits/age_check/age_check_final.zkey").expect("read zkey");
    parse_zkey_to_artifact(&zkey).expect("parse zkey")
}

/// The Circom witness for age = 25, threshold = 18 (15 wires), as produced by
/// both the Wasmi and ark-circom calculators in `witness_equivalence.rs`.
fn age_check_witness() -> Vec<Fr> {
    [1u64, 1, 18, 25, 26, 0, 0, 0, 1, 1, 1, 1, 1, 0, 248]
        .iter()
        .map(|v| Fr::from(*v))
        .collect()
}

fn invalid_artifact_message(err: LaniakeaError) -> String {
    match err {
        LaniakeaError::InvalidArtifact(m) => m,
        other => panic!("expected InvalidArtifact, got {other:?}"),
    }
}

fn invalid_witness_message(err: LaniakeaError) -> String {
    match err {
        LaniakeaError::InvalidWitness(m) => m,
        other => panic!("expected InvalidWitness, got {other:?}"),
    }
}

// ---------------------------------------------------------------- baseline

#[test]
fn valid_artifact_validates_roundtrips_and_proves() {
    let artifact = age_check_artifact();
    artifact
        .validate()
        .expect("zkey-derived artifact is consistent");
    assert_eq!(artifact.witness_len(), 15);

    let restored = ProvingArtifact::from_bytes(&artifact.to_bytes()).expect("roundtrip");
    assert_eq!(restored, artifact);

    // The pre-existing valid path still works end to end.
    prove_with_artifact(&artifact, &age_check_witness()).expect("valid witness proves");
}

// ----------------------------------------------------------------- witness

#[test]
fn witness_one_element_too_short_is_rejected() {
    let artifact = age_check_artifact();
    let mut witness = age_check_witness();
    witness.pop();
    let msg = invalid_witness_message(artifact.validate_witness(&witness).unwrap_err());
    assert!(msg.contains("14") && msg.contains("15"), "{msg}");
    // And through the proving entry point, as an error rather than a panic.
    let err = prove_with_artifact(&artifact, &witness).unwrap_err();
    assert!(matches!(err, LaniakeaError::InvalidWitness(_)), "{err:?}");
}

#[test]
fn witness_one_element_too_long_is_rejected() {
    // Without the check the MSM would silently ignore the extra element and
    // return a proof, so the length is the only thing that catches this.
    let artifact = age_check_artifact();
    let mut witness = age_check_witness();
    witness.push(Fr::from(7u64));
    let msg = invalid_witness_message(artifact.validate_witness(&witness).unwrap_err());
    assert!(msg.contains("16") && msg.contains("15"), "{msg}");
    let err = prove_with_artifact(&artifact, &witness).unwrap_err();
    assert!(matches!(err, LaniakeaError::InvalidWitness(_)), "{err:?}");
}

#[test]
fn empty_and_grossly_wrong_length_witnesses_are_rejected() {
    let artifact = age_check_artifact();
    for len in [0usize, 1, 3, 14, 16, 1000] {
        let witness = vec![Fr::one(); len];
        assert!(
            matches!(
                prove_with_artifact(&artifact, &witness),
                Err(LaniakeaError::InvalidWitness(_))
            ),
            "len {len}"
        );
    }
}

#[test]
fn witness_must_start_with_the_constant_one() {
    let artifact = age_check_artifact();
    let mut witness = age_check_witness();
    witness[0] = Fr::from(2u64);
    let msg = invalid_witness_message(artifact.validate_witness(&witness).unwrap_err());
    assert!(msg.contains("witness[0]"), "{msg}");
    assert!(matches!(
        prove_with_artifact(&artifact, &witness),
        Err(LaniakeaError::InvalidWitness(_))
    ));
}

#[test]
fn validate_witness_does_not_panic_on_an_artifact_with_no_wires() {
    // `validate_witness` is public and may be called without `validate`.
    let mut artifact = age_check_artifact();
    artifact.proving_key.a_query.clear();
    assert_eq!(artifact.witness_len(), 0);
    let err = artifact.validate_witness(&[]).unwrap_err();
    assert!(matches!(err, LaniakeaError::InvalidWitness(_)), "{err:?}");
}

#[test]
fn witness_errors_are_distinct_from_witness_generation_errors() {
    let err = age_check_artifact().validate_witness(&[]).unwrap_err();
    assert!(!matches!(err, LaniakeaError::WitnessGeneration(_)));
    assert!(err.to_string().starts_with("invalid witness"), "{err}");
}

// ------------------------------------------------------ serialized artifact

#[test]
fn empty_input_is_rejected() {
    let err = ProvingArtifact::from_bytes(&[]).unwrap_err();
    assert!(
        matches!(err, LaniakeaError::ArtifactLoad(ref m) if m.contains("empty")),
        "{err:?}"
    );
}

#[test]
fn every_truncation_is_rejected_without_panic() {
    let bytes = age_check_artifact().to_bytes();
    let n = bytes.len();
    // Strided sweep plus the boundaries where an off-by-one would hide.
    // Each attempt runs full point validation (slow in unoptimised builds), so
    // the stride is coarse.
    let mut cuts: Vec<usize> = (0..n).step_by(401).collect();
    cuts.extend([1, 7, 8, 9, 31, 32, 33, n - 33, n - 9, n - 8, n - 1]);
    for cut in cuts {
        let err = ProvingArtifact::from_bytes(&bytes[..cut]).expect_err(&format!("cut at {cut}"));
        assert!(
            matches!(err, LaniakeaError::ArtifactLoad(_)),
            "cut {cut}: {err:?}"
        );
    }
}

#[test]
fn trailing_bytes_are_rejected() {
    let mut bytes = age_check_artifact().to_bytes();
    bytes.push(0);
    let err = ProvingArtifact::from_bytes(&bytes).unwrap_err();
    assert!(
        matches!(err, LaniakeaError::ArtifactLoad(ref m) if m.contains("trailing")),
        "{err:?}"
    );
    bytes.extend_from_slice(&[0xAB; 100]);
    assert!(matches!(
        ProvingArtifact::from_bytes(&bytes),
        Err(LaniakeaError::ArtifactLoad(_))
    ));
}

#[test]
fn corrupted_bytes_never_panic_and_accepted_results_are_consistent() {
    let bytes = age_check_artifact().to_bytes();
    let (mut rejected, mut accepted) = (0, 0);
    for offset in (0..bytes.len()).step_by(331) {
        let mut corrupt = bytes.clone();
        corrupt[offset] ^= 0xFF;
        match ProvingArtifact::from_bytes(&corrupt) {
            Err(_) => rejected += 1,
            // A flip inside e.g. a matrix coefficient keeps the structure
            // intact: structural validation cannot detect it, by design.
            Ok(artifact) => {
                artifact
                    .validate()
                    .expect("from_bytes only returns validated artifacts");
                accepted += 1;
            }
        }
    }
    // Most of the artifact is group elements, which fail curve/subgroup checks.
    assert!(
        rejected > accepted,
        "rejected={rejected}, accepted={accepted}"
    );
}

/// Offset of the matrices within the serialized artifact: the proving key comes
/// first, then six `usize` fields (three dimensions, three non-zero counts),
/// then the row count of A.
fn matrices_offset(artifact: &ProvingArtifact) -> usize {
    artifact.proving_key.uncompressed_size()
}

#[test]
fn forged_length_prefixes_fail_cleanly() {
    let artifact = age_check_artifact();
    let bytes = artifact.to_bytes();
    let base = matrices_offset(&artifact);

    // Row count of A claims u64::MAX rows. Arkworks reads rows one by one and
    // runs out of input; it must neither pre-allocate nor loop forever.
    let mut forged = bytes.clone();
    forged[base + 48..base + 56].copy_from_slice(&u64::MAX.to_le_bytes());
    assert!(matches!(
        ProvingArtifact::from_bytes(&forged),
        Err(LaniakeaError::ArtifactLoad(_))
    ));

    // num_constraints claims an enormous circuit while the rows are unchanged.
    // This parses, and only structural validation stops it; unchecked it would
    // make the reduction allocate a domain of that size.
    let mut forged = bytes.clone();
    forged[base + 16..base + 24].copy_from_slice(&(u64::MAX / 4).to_le_bytes());
    let msg = invalid_artifact_message(ProvingArtifact::from_bytes(&forged).unwrap_err());
    assert!(msg.contains("num_constraints"), "{msg}");
}

// -------------------------------------------------- inconsistent dimensions

type Mutation = fn(&mut ProvingArtifact);

/// Each case breaks one rule of `ProvingArtifact::validate` and names a phrase
/// the error must contain.
fn inconsistent_cases() -> Vec<(&'static str, Mutation, &'static str)> {
    vec![
        (
            "a_query shorter",
            |a| {
                a.proving_key.a_query.pop();
            },
            "b_g1_query has 15",
        ),
        (
            "b_g1_query shorter",
            |a| {
                a.proving_key.b_g1_query.pop();
            },
            "b_g1_query has 14",
        ),
        (
            "b_g2_query shorter",
            |a| {
                a.proving_key.b_g2_query.pop();
            },
            "b_g2_query has 14",
        ),
        (
            "l_query longer",
            |a| {
                let p = a.proving_key.l_query[0];
                a.proving_key.l_query.push(p);
            },
            "l_query has 13",
        ),
        (
            "l_query shorter",
            |a| {
                a.proving_key.l_query.pop();
            },
            "l_query has 11",
        ),
        (
            "vk IC shorter",
            |a| {
                a.proving_key.vk.gamma_abc_g1.pop();
            },
            "IC points",
        ),
        (
            "no instance variables",
            |a| a.matrices.num_instance_variables = 0,
            "is 0",
        ),
        (
            "more instance variables than wires",
            |a| a.matrices.num_instance_variables = 16,
            "fewer than",
        ),
        (
            "num_constraints too large",
            |a| a.matrices.num_constraints += 1,
            "num_constraints is 14",
        ),
        (
            "num_constraints inflated",
            |a| a.matrices.num_constraints = usize::MAX / 4,
            "num_constraints",
        ),
        (
            "A references a nonexistent wire",
            |a| a.matrices.a[0].push((Fr::one(), 15)),
            "references signal 15",
        ),
        (
            "B references a nonexistent wire",
            |a| a.matrices.b.iter_mut().flatten().next().unwrap().1 = usize::MAX,
            "references signal",
        ),
        (
            "A non-zero count wrong",
            |a| a.matrices.a_num_non_zero += 1,
            "non-zero entries",
        ),
        (
            "C has wrong row count",
            |a| a.matrices.c = vec![vec![]; 3],
            "matrix C has 3 rows",
        ),
        (
            "h_query too short",
            |a| a.proving_key.h_query.truncate(15),
            "h_query has 15",
        ),
        (
            "h_query longer than the domain",
            |a| {
                let p = a.proving_key.h_query[0];
                a.proving_key.h_query.push(p);
            },
            "h_query has 17",
        ),
        (
            "h_query empty",
            |a| a.proving_key.h_query.clear(),
            "h_query has 0",
        ),
    ]
}

#[test]
fn inconsistent_artifacts_are_rejected_by_validate() {
    for (name, mutate, expected) in inconsistent_cases() {
        let mut artifact = age_check_artifact();
        mutate(&mut artifact);
        let msg = invalid_artifact_message(
            artifact
                .validate()
                .expect_err(&format!("{name}: should be rejected")),
        );
        assert!(msg.contains(expected), "{name}: `{msg}` lacks `{expected}`");
    }
}

#[test]
fn inconsistent_artifacts_are_rejected_at_the_serialization_boundary() {
    // Full deserialization (with point validation) is slow in unoptimised
    // builds, so cover every third case; `validate` has the exhaustive test.
    for (name, mutate, expected) in inconsistent_cases().into_iter().step_by(3) {
        let mut artifact = age_check_artifact();
        mutate(&mut artifact);
        let msg = invalid_artifact_message(
            ProvingArtifact::from_bytes(&artifact.to_bytes())
                .expect_err(&format!("{name}: should be rejected")),
        );
        assert!(msg.contains(expected), "{name}: `{msg}` lacks `{expected}`");
    }
}

#[test]
fn inconsistent_artifacts_are_rejected_before_proving_starts() {
    // Without validation these would index out of bounds, allocate a domain
    // sized by the forged num_constraints, or silently drop MSM terms. They
    // must come back as errors; reaching the prover would panic or abort.
    let witness = age_check_witness();
    for (name, mutate, _) in inconsistent_cases() {
        let mut artifact = age_check_artifact();
        mutate(&mut artifact);
        let result = prove_with_artifact(&artifact, &witness);
        assert!(
            matches!(result, Err(LaniakeaError::InvalidArtifact(_))),
            "{name}: {:?}",
            result.map(|_| "a proof was produced")
        );
    }
}

#[test]
fn fewer_constraint_rows_shrink_the_domain_and_are_rejected_before_proving() {
    // Keep every other relationship consistent (rows, num_constraints, non-zero
    // counters) but drop constraints so the reduction's domain falls from 16 to
    // 8 while h_query still has the setup's 16 entries. Nothing downstream
    // notices: the prover would return a proof that does not verify.
    let mut artifact = age_check_artifact();
    assert_eq!(artifact.proving_key.h_query.len(), 16);
    let m = &mut artifact.matrices;
    m.a.truncate(5);
    m.b.truncate(5);
    m.num_constraints = 5; // domain: next_pow2(5 + 3 instance) = 8
    m.a_num_non_zero = m.a.iter().map(Vec::len).sum();
    m.b_num_non_zero = m.b.iter().map(Vec::len).sum();
    assert_eq!(artifact.proving_key.h_query.len(), 16, "h_query unchanged");

    let msg = invalid_artifact_message(artifact.validate().unwrap_err());
    assert!(
        msg.contains("h_query has 16") && msg.contains("domain has 8"),
        "{msg}"
    );

    // prove_with_artifact must return the structural error, not a proof.
    let result = prove_with_artifact(&artifact, &age_check_witness());
    assert!(
        matches!(result, Err(LaniakeaError::InvalidArtifact(_))),
        "{:?}",
        result.map(|_| "a proof was produced")
    );

    // And through the serialization boundary.
    let msg =
        invalid_artifact_message(ProvingArtifact::from_bytes(&artifact.to_bytes()).unwrap_err());
    assert!(msg.contains("h_query has 16"), "{msg}");
}

#[test]
fn structural_validation_does_not_claim_to_detect_coefficient_changes() {
    // Documented limitation: a different coefficient keeps every length and
    // index valid, so validation accepts it (the proof would then fail to
    // verify). Pinned here so nobody mistakes `validate` for an integrity check.
    let mut artifact = age_check_artifact();
    artifact.matrices.a[0][0].0 += Fr::one();
    artifact.validate().expect("structurally valid");
}
