use ark_bn254::{Bn254, Fr, G1Affine, G2Affine};
use ark_groth16::Groth16;
use ark_serialize::CanonicalDeserialize;
use ark_snark::SNARK;
use ark_std::io::Cursor;
use std::str::FromStr;

use super::{ProofOutput, ProvingArtifacts, WitnessInputs, ZkBackend};
use crate::error::LaniakeaError;

/// Legacy trait-based Groth16 backend. New code should use [`crate::Prover`].
/// - `verify`: pure ark-groth16, all platforms.
/// - `prove`: a convenience wrapper over [`crate::Prover`] for callers holding a
///   raw `.zkey` (desktop only, since parsing it needs ark-circom).
pub struct Groth16Backend;

impl ZkBackend for Groth16Backend {
    #[cfg(not(target_os = "ios"))]
    fn prove(
        &self,
        artifacts: &ProvingArtifacts,
        inputs: &WitnessInputs,
    ) -> Result<ProofOutput, LaniakeaError> {
        // Same validated pipeline as `Prover`: zkey -> ProvingArtifact (validated),
        // Wasmi witness, portable CircomReduction. No filesystem access, no
        // ark-circom witness engine. Output formats follow `ProofResult`.
        let artifact = crate::artifacts::parse_zkey_to_artifact(&artifacts.zkey_bytes)
            .map_err(LaniakeaError::ArtifactLoad)?;
        let result =
            crate::Prover::from_artifact(artifact, &artifacts.wasm_bytes)?.prove(inputs)?;
        Ok(ProofOutput {
            proof_json: result.proof_json(),
            public_signals_json: result.public_signals_json(),
        })
    }

    #[cfg(target_os = "ios")]
    fn prove(
        &self,
        _artifacts: &ProvingArtifacts,
        _inputs: &WitnessInputs,
    ) -> Result<ProofOutput, LaniakeaError> {
        Err(LaniakeaError::ProofGeneration(
            "a raw .zkey cannot be parsed on iOS (ark-circom is desktop-only). \
             Convert it to a ProvingArtifact at build time and use laniakea_core::Prover."
                .into(),
        ))
    }

    fn verify(
        &self,
        proof_json: &str,
        public_signals_json: &str,
        vk_bytes: &[u8],
    ) -> Result<bool, LaniakeaError> {
        // Deserialize verifying key from bytes (pure ark-groth16, platform-independent)
        let vk: ark_groth16::VerifyingKey<Bn254> =
            CanonicalDeserialize::deserialize_uncompressed(&mut Cursor::new(vk_bytes))
                .map_err(|e| LaniakeaError::ArtifactLoad(e.to_string()))?;

        // Deserialize proof from JSON directly to ark_groth16::Proof (no ark-circom needed)
        let proof = proof_from_json(proof_json)?;

        // Deserialize public signals (strings to Fr)
        let public_signal_strings: Vec<String> = serde_json::from_str(public_signals_json)
            .map_err(|e| LaniakeaError::Serialization(e.to_string()))?;
        let public_signals: Vec<Fr> = public_signal_strings
            .iter()
            .map(|s| {
                Fr::from_str(s)
                    .map_err(|_| LaniakeaError::Serialization("invalid field element".into()))
            })
            .collect::<Result<Vec<_>, _>>()?;

        // Process VK for efficient verification
        let pvk = Groth16::<Bn254>::process_vk(&vk)
            .map_err(|e| LaniakeaError::Verification(e.to_string()))?;

        // Verify the proof
        let verified = Groth16::<Bn254>::verify_with_processed_vk(&pvk, &public_signals, &proof)
            .map_err(|e| LaniakeaError::Verification(e.to_string()))?;

        Ok(verified)
    }
}

/// Parse proof from JSON directly to ark_groth16::Proof (supports both snarkjs and internal formats)
fn proof_from_json(json_str: &str) -> Result<ark_groth16::Proof<Bn254>, LaniakeaError> {
    let value: serde_json::Value =
        serde_json::from_str(json_str).map_err(|e| LaniakeaError::Serialization(e.to_string()))?;

    // Support both internal format (a, b, c) and snarkjs format (pi_a, pi_b, pi_c)
    let a_val = value
        .get("a")
        .or_else(|| value.get("pi_a"))
        .ok_or_else(|| LaniakeaError::Serialization("missing 'a'/'pi_a' in proof".into()))?;
    let b_val = value
        .get("b")
        .or_else(|| value.get("pi_b"))
        .ok_or_else(|| LaniakeaError::Serialization("missing 'b'/'pi_b' in proof".into()))?;
    let c_val = value
        .get("c")
        .or_else(|| value.get("pi_c"))
        .ok_or_else(|| LaniakeaError::Serialization("missing 'c'/'pi_c' in proof".into()))?;

    let a = parse_g1_affine(a_val)?;
    let b = parse_g2_affine(b_val)?;
    let c = parse_g1_affine(c_val)?;

    Ok(ark_groth16::Proof { a, b, c })
}

fn parse_g1_affine(value: &serde_json::Value) -> Result<G1Affine, LaniakeaError> {
    let arr = value
        .as_array()
        .ok_or_else(|| LaniakeaError::Serialization("invalid G1 tuple".into()))?;
    // Handle both internal format [x, y] (2 elements) and snarkjs format [x, y, z] (3 elements with projective coord)
    let (x_str, y_str) = if arr.len() == 2 {
        let x = arr[0]
            .as_str()
            .ok_or_else(|| LaniakeaError::Serialization("G1 x must be string".into()))?;
        let y = arr[1]
            .as_str()
            .ok_or_else(|| LaniakeaError::Serialization("G1 y must be string".into()))?;
        (x, y)
    } else if arr.len() == 3 {
        let x = arr[0]
            .as_str()
            .ok_or_else(|| LaniakeaError::Serialization("G1 x must be string".into()))?;
        let y = arr[1]
            .as_str()
            .ok_or_else(|| LaniakeaError::Serialization("G1 y must be string".into()))?;
        (x, y)
    } else {
        return Err(LaniakeaError::Serialization(
            "G1 tuple must have 2 or 3 elements".into(),
        ));
    };
    let x = ark_bn254::Fq::from_str(x_str)
        .map_err(|e| LaniakeaError::Serialization(format!("{:?}", e)))?;
    let y = ark_bn254::Fq::from_str(y_str)
        .map_err(|e| LaniakeaError::Serialization(format!("{:?}", e)))?;

    Ok(G1Affine::new_unchecked(x, y))
}

fn parse_g2_affine(value: &serde_json::Value) -> Result<G2Affine, LaniakeaError> {
    let arr = value
        .as_array()
        .ok_or_else(|| LaniakeaError::Serialization("invalid G2 tuple".into()))?;
    // Handle both internal format [x, y] (2 elements) and snarkjs format [x, y, z] (3 elements with projective coord)
    let (x_arr, y_arr) = if arr.len() == 2 {
        let x = arr[0]
            .as_array()
            .ok_or_else(|| LaniakeaError::Serialization("G2 x must be array".into()))?;
        let y = arr[1]
            .as_array()
            .ok_or_else(|| LaniakeaError::Serialization("G2 y must be array".into()))?;
        (x, y)
    } else if arr.len() == 3 {
        let x = arr[0]
            .as_array()
            .ok_or_else(|| LaniakeaError::Serialization("G2 x must be array".into()))?;
        let y = arr[1]
            .as_array()
            .ok_or_else(|| LaniakeaError::Serialization("G2 y must be array".into()))?;
        (x, y)
    } else {
        return Err(LaniakeaError::Serialization(
            "G2 tuple must have 2 or 3 elements".into(),
        ));
    };
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

    let x0 = ark_bn254::Fq::from_str(x0_str)
        .map_err(|e| LaniakeaError::Serialization(format!("{:?}", e)))?;
    let x1 = ark_bn254::Fq::from_str(x1_str)
        .map_err(|e| LaniakeaError::Serialization(format!("{:?}", e)))?;
    let y0 = ark_bn254::Fq::from_str(y0_str)
        .map_err(|e| LaniakeaError::Serialization(format!("{:?}", e)))?;
    let y1 = ark_bn254::Fq::from_str(y1_str)
        .map_err(|e| LaniakeaError::Serialization(format!("{:?}", e)))?;

    let x_fq2 = ark_bn254::Fq2::new(x0, x1);
    let y_fq2 = ark_bn254::Fq2::new(y0, y1);

    Ok(G2Affine::new_unchecked(x_fq2, y_fq2))
}
