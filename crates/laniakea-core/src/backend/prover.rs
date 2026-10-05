use ark_bn254::{Bn254, Fq, Fq2, Fr, G1Affine, G2Affine};
use ark_groth16::{Groth16, Proof, ProvingKey, VerifyingKey};
use ark_relations::r1cs::ConstraintMatrices;
use ark_std::UniformRand;
use rand::thread_rng;
use std::str::FromStr;

use crate::artifacts::ProvingArtifact;
use crate::backend::circom_reduction::CircomReduction;
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
pub fn prove_with_artifact(
    artifact: &ProvingArtifact,
    witness: &[Fr],
) -> Result<Proof<Bn254>, LaniakeaError> {
    // Extract components from artifact
    let proving_key: &ProvingKey<Bn254> = &artifact.proving_key;
    let matrices: ConstraintMatrices<Fr> = artifact.matrices.clone().into();

    let num_inputs = artifact.num_public_inputs();
    let num_constraints = artifact.num_constraints();

    // Note: witness length may differ from num_inputs + num_witness_vars
    // because the zkey matrices may include variables not in the Wasmi witness
    // (e.g., output signals). The CircomReduction only uses num_inputs and num_constraints.

    // Generate random r, s for proof
    let mut rng = thread_rng();
    let r = Fr::rand(&mut rng);
    let s = Fr::rand(&mut rng);

    // Create proof using CircomReduction (handles Circom's QAP transformation)
    let proof = Groth16::<Bn254, CircomReduction>::create_proof_with_reduction_and_matrices(
        proving_key,
        r,
        s,
        &matrices,
        num_inputs,
        num_constraints,
        witness,
    )
    .map_err(|e| LaniakeaError::ProofGeneration(e.to_string()))?;

    Ok(proof)
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
/// Public signals are witness[1..num_inputs] (excluding the leading "1")
pub fn extract_public_signals(witness: &[Fr], num_public_inputs: usize) -> Vec<Fr> {
    // num_public_inputs includes the constant "1" at index 0
    witness[1..num_public_inputs].to_vec()
}

/// Parse a snarkjs-format verification_key.json into ark_groth16::VerifyingKey<Bn254>
pub fn parse_vk_from_json(json_str: &str) -> Result<VerifyingKey<Bn254>, LaniakeaError> {
    let value: serde_json::Value =
        serde_json::from_str(json_str).map_err(|e| LaniakeaError::Serialization(e.to_string()))?;

    // Parse alpha_1 (G1)
    let alpha_1 = parse_g1_affine_from_json(&value["vk_alpha_1"])?;

    // Parse beta_2 (G2)
    let beta_2 = parse_g2_affine_from_json(&value["vk_beta_2"])?;

    // Parse gamma_2 (G2)
    let gamma_2 = parse_g2_affine_from_json(&value["vk_gamma_2"])?;

    // Parse delta_2 (G2)
    let delta_2 = parse_g2_affine_from_json(&value["vk_delta_2"])?;

    // Parse IC (Vec<G1>)
    let ic_arr = value["IC"]
        .as_array()
        .ok_or_else(|| LaniakeaError::Serialization("IC must be array".into()))?;
    let mut gamma_abc_g1 = Vec::with_capacity(ic_arr.len());
    for ic_item in ic_arr {
        gamma_abc_g1.push(parse_g1_affine_from_json(ic_item)?);
    }

    Ok(VerifyingKey {
        alpha_g1: alpha_1,
        beta_g2: beta_2,
        gamma_g2: gamma_2,
        delta_g2: delta_2,
        gamma_abc_g1,
    })
}

fn parse_g1_affine_from_json(value: &serde_json::Value) -> Result<G1Affine, LaniakeaError> {
    let arr = value
        .as_array()
        .ok_or_else(|| LaniakeaError::Serialization("G1 must be array".into()))?;
    if arr.len() != 3 {
        return Err(LaniakeaError::Serialization(
            "G1 must have 3 elements (x, y, z)".into(),
        ));
    }
    let x_str = arr[0]
        .as_str()
        .ok_or_else(|| LaniakeaError::Serialization("G1 x must be string".into()))?;
    let y_str = arr[1]
        .as_str()
        .ok_or_else(|| LaniakeaError::Serialization("G1 y must be string".into()))?;
    // z coordinate (projective) is arr[2], should be "1" for affine
    let x = Fq::from_str(x_str).map_err(|e| LaniakeaError::Serialization(format!("{:?}", e)))?;
    let y = Fq::from_str(y_str).map_err(|e| LaniakeaError::Serialization(format!("{:?}", e)))?;
    Ok(G1Affine::new_unchecked(x, y))
}

fn parse_g2_affine_from_json(value: &serde_json::Value) -> Result<G2Affine, LaniakeaError> {
    let arr = value
        .as_array()
        .ok_or_else(|| LaniakeaError::Serialization("G2 must be array".into()))?;
    if arr.len() != 3 {
        return Err(LaniakeaError::Serialization(
            "G2 must have 3 elements (x, y, z)".into(),
        ));
    }
    let x_arr = arr[0]
        .as_array()
        .ok_or_else(|| LaniakeaError::Serialization("G2 x must be array".into()))?;
    let y_arr = arr[1]
        .as_array()
        .ok_or_else(|| LaniakeaError::Serialization("G2 y must be array".into()))?;
    // z coordinate is arr[2], should be [1, 0] for affine
    if x_arr.len() != 2 || y_arr.len() != 2 {
        return Err(LaniakeaError::Serialization(
            "G2 x/y must have 2 elements".into(),
        ));
    }
    let x0_str = x_arr[0]
        .as_str()
        .ok_or_else(|| LaniakeaError::Serialization("G2 x[0] must be string".into()))?;
    let x1_str = x_arr[1]
        .as_str()
        .ok_or_else(|| LaniakeaError::Serialization("G2 x[1] must be string".into()))?;
    let y0_str = y_arr[0]
        .as_str()
        .ok_or_else(|| LaniakeaError::Serialization("G2 y[0] must be string".into()))?;
    let y1_str = y_arr[1]
        .as_str()
        .ok_or_else(|| LaniakeaError::Serialization("G2 y[1] must be string".into()))?;

    let x0 = Fq::from_str(x0_str).map_err(|e| LaniakeaError::Serialization(format!("{:?}", e)))?;
    let x1 = Fq::from_str(x1_str).map_err(|e| LaniakeaError::Serialization(format!("{:?}", e)))?;
    let y0 = Fq::from_str(y0_str).map_err(|e| LaniakeaError::Serialization(format!("{:?}", e)))?;
    let y1 = Fq::from_str(y1_str).map_err(|e| LaniakeaError::Serialization(format!("{:?}", e)))?;

    let x_fq2 = Fq2::new(x0, x1);
    let y_fq2 = Fq2::new(y0, y1);

    Ok(G2Affine::new_unchecked(x_fq2, y_fq2))
}

#[cfg(test)]
mod tests {
    use super::*;
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
        let public_signals = extract_public_signals(&witness, artifact.num_public_inputs());

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
