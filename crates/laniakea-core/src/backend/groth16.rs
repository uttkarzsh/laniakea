use ark_bn254::{Bn254, Fr, G1Affine, G2Affine};
use ark_groth16::Groth16;
use ark_serialize::CanonicalDeserialize;
use ark_snark::SNARK;
use ark_std::io::Cursor;

use super::points;
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
                points::canonical_field::<Fr>(s)
                    .ok_or_else(|| LaniakeaError::Serialization("invalid field element".into()))
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

/// Parse proof from JSON directly to ark_groth16::Proof (supports both snarkjs and internal formats).
/// Every point is validated (on-curve, subgroup) before it can reach a pairing.
pub(crate) fn proof_from_json(json_str: &str) -> Result<ark_groth16::Proof<Bn254>, LaniakeaError> {
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

    let a = parse_g1_affine(a_val, "proof.a")?;
    let b = parse_g2_affine(b_val, "proof.b")?;
    let c = parse_g1_affine(c_val, "proof.c")?;

    Ok(ark_groth16::Proof { a, b, c })
}

/// Accepts `[x, y]` or snarkjs's `[x, y, z]` (with `z == 1`). The point is
/// validated: on the curve and in the right subgroup.
fn parse_g1_affine(value: &serde_json::Value, what: &str) -> Result<G1Affine, LaniakeaError> {
    let bad = |m: &str| LaniakeaError::Serialization(format!("{what}: {m}"));
    let arr = value.as_array().ok_or_else(|| bad("G1 must be an array"))?;
    if arr.len() != 2 && arr.len() != 3 {
        return Err(bad("G1 tuple must have 2 or 3 elements"));
    }
    if let Some(z) = arr.get(2) {
        points::check_z_is_one(z, false, what)?;
    }
    let x = arr[0]
        .as_str()
        .ok_or_else(|| bad("G1 x must be a string"))?;
    let y = arr[1]
        .as_str()
        .ok_or_else(|| bad("G1 y must be a string"))?;
    points::g1_from_decimals(x, y, what)
}

/// Accepts `[x, y]` or snarkjs's `[x, y, z]` (with `z == ["1","0"]`), `x` and
/// `y` being `[c0, c1]`. The point is validated: on the curve and in the
/// prime-order subgroup.
fn parse_g2_affine(value: &serde_json::Value, what: &str) -> Result<G2Affine, LaniakeaError> {
    let bad = |m: &str| LaniakeaError::Serialization(format!("{what}: {m}"));
    let arr = value.as_array().ok_or_else(|| bad("G2 must be an array"))?;
    if arr.len() != 2 && arr.len() != 3 {
        return Err(bad("G2 tuple must have 2 or 3 elements"));
    }
    if let Some(z) = arr.get(2) {
        points::check_z_is_one(z, true, what)?;
    }
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
