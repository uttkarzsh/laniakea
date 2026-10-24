use ark_bn254::{Bn254, Fr, G1Affine, G2Affine};
use ark_groth16::{Groth16, Proof, ProvingKey, VerifyingKey};
use ark_relations::r1cs::ConstraintMatrices;
use ark_std::UniformRand;
use rand::thread_rng;

use crate::artifacts::ProvingArtifact;
use crate::backend::circom_reduction::CircomReduction;
use crate::backend::points;
use crate::error::LaniakeaError;

/// Generate a Groth16 proof using the portable CircomReduction.
///
/// This function does NOT depend on ark-circom or Wasmer.
/// It uses only pure-Rust Arkworks crates.
///
/// # Arguments
/// * `artifact` - The preprocessed proving artifact (from zkey)
/// * `witness` - The full witness vector [1, public_inputs..., private_wires...]
///
/// # Returns
/// * `Proof<Bn254>` - The Groth16 proof
///
/// # Validation
/// Before any proving work, the artifact is checked with
/// [`ProvingArtifact::validate`] and the witness with
/// [`ProvingArtifact::validate_witness`], so inconsistent inputs produce
/// [`LaniakeaError::InvalidArtifact`] / [`LaniakeaError::InvalidWitness`]
/// instead of a panic, an oversized allocation, or a silently wrong proof.
/// The artifact check is linear in the number of matrix entries, which is small
/// next to the FFTs and multi-scalar multiplications that follow; it is
/// repeated here because `ProvingArtifact`'s fields are public, so a value
/// need not have come through [`ProvingArtifact::from_bytes`]. These are
/// structural checks: they do not verify that the witness satisfies the
/// constraints (an unsatisfying witness yields a proof that fails to verify).
pub fn prove_with_artifact(
    artifact: &ProvingArtifact,
    witness: &[Fr],
) -> Result<Proof<Bn254>, LaniakeaError> {
    artifact.validate()?;
    artifact.validate_witness(witness)?;

    let matrices: ConstraintMatrices<Fr> = artifact.matrices.clone().into();
    prove_validated(&artifact.proving_key, &matrices, witness)
}

/// The proving step shared by [`prove_with_artifact`] and the high-level
/// [`crate::Prover`], with no validation of its own.
///
/// Crate-private on purpose: callers must already have established everything
/// [`ProvingArtifact::validate`] and [`ProvingArtifact::validate_witness`] check
/// (the key and matrices are consistent and `witness` fits them). Called with
/// anything else it can index out of bounds or return a wrong proof. The
/// `Prover` runs `validate` once at construction and `validate_witness` on every
/// call; there is deliberately no public unchecked entry point.
pub(crate) fn prove_validated(
    proving_key: &ProvingKey<Bn254>,
    matrices: &ConstraintMatrices<Fr>,
    witness: &[Fr],
) -> Result<Proof<Bn254>, LaniakeaError> {
    // The witness has one entry per circuit wire (`a_query.len()`), which is
    // `num_instance_variables + l_query.len()`. Do not compare it with
    // `num_instance_variables + num_witness_variables`: ark-circom reports
    // `num_witness_variables` one higher than the number of auxiliary wires.

    // Generate random r, s for proof
    let mut rng = thread_rng();
    let r = Fr::rand(&mut rng);
    let s = Fr::rand(&mut rng);

    // Create proof using CircomReduction (handles Circom's QAP transformation)
    Groth16::<Bn254, CircomReduction>::create_proof_with_reduction_and_matrices(
        proving_key,
        r,
        s,
        matrices,
        matrices.num_instance_variables,
        matrices.num_constraints,
        witness,
    )
    .map_err(|e| LaniakeaError::ProofGeneration(e.to_string()))
}

/// Serialize a Groth16 proof to JSON (snarkjs-compatible format).
pub fn proof_to_json(proof: &Proof<Bn254>) -> Result<String, serde_json::Error> {
    let a = proof.a;
    let b = proof.b;
    let c = proof.c;
    // Fq2 elements have .c0 and .c1 fields for the coefficients
    serde_json::to_string(&serde_json::json!({
        "pi_a": [a.x.to_string(), a.y.to_string()],
        "pi_b": [[b.x.c0.to_string(), b.x.c1.to_string()], [b.y.c0.to_string(), b.y.c1.to_string()]],
        "pi_c": [c.x.to_string(), c.y.to_string()],
    }))
}

/// Extract public signals from witness.
/// The witness layout is: [1, public_inputs..., private_wires...]
/// Public signals are `witness[1..num_instance]`, excluding the leading "1";
/// `num_instance` counts that constant.
///
/// Crate-private: callers outside the crate use [`crate::Prover`]. Still
/// returns an error rather than indexing out of bounds.
pub(crate) fn extract_public_signals(
    witness: &[Fr],
    num_instance: usize,
) -> Result<Vec<Fr>, LaniakeaError> {
    if num_instance == 0 {
        return Err(LaniakeaError::InvalidWitness(
            "an instance of zero variables has no constant 1".into(),
        ));
    }
    witness
        .get(1..num_instance)
        .map(<[Fr]>::to_vec)
        .ok_or_else(|| {
            LaniakeaError::InvalidWitness(format!(
                "witness has {} entries but {num_instance} instance variables are expected",
                witness.len()
            ))
        })
}

/// Parse a snarkjs-format verification_key.json into ark_groth16::VerifyingKey<Bn254>.
/// Every point is validated (on-curve, subgroup); an invalid one is an error.
pub fn parse_vk_from_json(json_str: &str) -> Result<VerifyingKey<Bn254>, LaniakeaError> {
    let value: serde_json::Value =
        serde_json::from_str(json_str).map_err(|e| LaniakeaError::Serialization(e.to_string()))?;

    // Parse alpha_1 (G1)
    let alpha_1 = parse_g1_affine_from_json(&value["vk_alpha_1"], "vk.alpha_1")?;

    // Parse beta_2 (G2)
    let beta_2 = parse_g2_affine_from_json(&value["vk_beta_2"], "vk.beta_2")?;

    // Parse gamma_2 (G2)
    let gamma_2 = parse_g2_affine_from_json(&value["vk_gamma_2"], "vk.gamma_2")?;

    // Parse delta_2 (G2)
    let delta_2 = parse_g2_affine_from_json(&value["vk_delta_2"], "vk.delta_2")?;

    // Parse IC (Vec<G1>)
    let ic_arr = value["IC"]
        .as_array()
        .ok_or_else(|| LaniakeaError::Serialization("IC must be array".into()))?;
    let mut gamma_abc_g1 = Vec::with_capacity(ic_arr.len());
    for (i, ic_item) in ic_arr.iter().enumerate() {
        gamma_abc_g1.push(parse_g1_affine_from_json(ic_item, &format!("vk.IC[{i}]"))?);
    }

    Ok(VerifyingKey {
        alpha_g1: alpha_1,
        beta_g2: beta_2,
        gamma_g2: gamma_2,
        delta_g2: delta_2,
        gamma_abc_g1,
    })
}

fn parse_g1_affine_from_json(
    value: &serde_json::Value,
    what: &str,
) -> Result<G1Affine, LaniakeaError> {
    let bad = |m: &str| LaniakeaError::Serialization(format!("{what}: {m}"));
    let arr = value.as_array().ok_or_else(|| bad("G1 must be an array"))?;
    if arr.len() != 3 {
        return Err(bad("G1 must have 3 elements (x, y, z)"));
    }
    points::check_z_is_one(&arr[2], false, what)?;
    let x = arr[0]
        .as_str()
        .ok_or_else(|| bad("G1 x must be a string"))?;
    let y = arr[1]
        .as_str()
        .ok_or_else(|| bad("G1 y must be a string"))?;
    points::g1_from_decimals(x, y, what)
}

fn parse_g2_affine_from_json(
    value: &serde_json::Value,
    what: &str,
) -> Result<G2Affine, LaniakeaError> {
    let bad = |m: &str| LaniakeaError::Serialization(format!("{what}: {m}"));
    let arr = value.as_array().ok_or_else(|| bad("G2 must be an array"))?;
    if arr.len() != 3 {
        return Err(bad("G2 must have 3 elements (x, y, z)"));
    }
    points::check_z_is_one(&arr[2], true, what)?;
    let pair = |v: &serde_json::Value| -> Result<[String; 2], LaniakeaError> {
        let a = v
            .as_array()
            .filter(|a| a.len() == 2)
            .ok_or_else(|| bad("G2 coordinates must be [c0, c1] arrays"))?;
        let s = |i: usize| {
            a[i].as_str()
                .map(str::to_owned)
                .ok_or_else(|| bad("G2 coordinate components must be strings"))
        };
        Ok([s(0)?, s(1)?])
    };
    let (x, y) = (pair(&arr[0])?, pair(&arr[1])?);
    points::g2_from_decimals([&x[0], &x[1]], [&y[0], &y[1]], what)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extract_public_signals_never_panics_on_bad_lengths() {
        let w = [Fr::from(1u64), Fr::from(7u64), Fr::from(9u64)];
        assert_eq!(extract_public_signals(&w, 1).unwrap(), vec![]);
        assert_eq!(extract_public_signals(&w, 3).unwrap().len(), 2);
        for (witness, n) in [(&w[..0], 1), (&w[..], 0), (&w[..], 4), (&w[..1], 5)] {
            assert!(
                matches!(
                    extract_public_signals(witness, n),
                    Err(LaniakeaError::InvalidWitness(_))
                ),
                "({}, {n})",
                witness.len()
            );
        }
    }
    use crate::artifacts::parse_zkey_to_artifact;
    use crate::witness::{WitnessArtifacts, WitnessCalculator};
    use crate::witness_wasmi::WasmiWitnessAdapter;
    use ark_snark::SNARK;
    use num_bigint::BigInt;
    use std::fs;

    #[test]
    fn test_portable_proving_age_check() {
        // Load zkey and create artifact
        let zkey_bytes =
            fs::read("../../circuits/age_check/age_check_final.zkey").expect("failed to read zkey");
        let artifact = parse_zkey_to_artifact(&zkey_bytes).expect("failed to parse zkey");

        // Generate witness using Wasmi (not ark-circom)
        let wasm_bytes = fs::read("../../circuits/age_check/age_check_js/age_check.wasm")
            .expect("failed to read wasm");

        let mut witness_calc = WasmiWitnessAdapter::new(WitnessArtifacts {
            wasm_bytes,
            r1cs_bytes: None,
        })
        .expect("failed to create WasmiWitnessAdapter");

        let inputs = vec![
            ("age".to_string(), vec![BigInt::from(25u32)]),
            ("threshold".to_string(), vec![BigInt::from(18u32)]),
        ];

        let witness = witness_calc
            .calculate_witness(&inputs)
            .expect("wasmi witness generation failed");

        // Prove using portable prover
        let proof = prove_with_artifact(&artifact, &witness).expect("portable proving failed");

        // Verify the proof using ark-groth16 verification
        // Parse VK from snarkjs JSON format
        let vk_json = fs::read_to_string("../../circuits/age_check/verification_key.json")
            .expect("failed to read verification_key.json");
        let vk = parse_vk_from_json(&vk_json).expect("failed to parse VK from JSON");

        // Extract public signals from witness
        let public_signals =
            extract_public_signals(&witness, artifact.num_public_inputs()).unwrap();

        // Process VK and verify
        let pvk = Groth16::<Bn254>::process_vk(&vk).expect("failed to process VK");
        let verified = Groth16::<Bn254>::verify_with_processed_vk(&pvk, &public_signals, &proof)
            .expect("verification failed");

        assert!(verified, "proof verification failed");
        println!("Portable proving test PASSED - proof verified with ark-groth16");

        // Also test JSON serialization
        let proof_json = proof_to_json(&proof).expect("proof JSON serialization failed");
        println!("Proof JSON: {}", proof_json);
    }
}
