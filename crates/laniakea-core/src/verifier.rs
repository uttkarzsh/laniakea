//! Groth16 verification against a snarkjs `verification_key.json`.
//!
//! ```text
//! verification_key.json ──► Verifier (parsed, validated, prepared once)
//!                                │
//!        proof.json + public signals ──► verify ──► true / false
//! ```
//!
//! Portable (pure arkworks, no ark-circom), so it runs on iOS as well as on the desktop.
//!
//! # Results
//!
//! * `Ok(true)`: the proof is valid for these public signals under this key.
//! * `Ok(false)`: everything was well formed, but the pairing check failed (a forged
//!   or altered proof, other public signals, or a proof made for another key).
//! * `Err(_)`: something could not be checked at all: a malformed key, a malformed proof
//!   (bad JSON, a coordinate that is not a canonical field element, a point off the
//!   curve or outside the prime-order subgroup) or malformed public signals (wrong count,
//!   a value that is not a canonical decimal below the scalar field modulus).
//!
//! A caller deciding whether to trust a proof must treat `Ok(false)` and `Err(_)` alike:
//! only `Ok(true)` accepts.
//!
//! # What `Ok(true)` does and does not mean
//!
//! It means: some private inputs satisfy the circuit's constraints with exactly these
//! public signals, *assuming the key comes from an honest setup for that circuit*. It does
//! not mean the application's condition holds (read the public signals: age_check
//! produces valid proofs with `out = 0`), and it does not identify the circuit. The key
//! must be one the verifier chose and trusts; a key supplied along with the proof proves
//! nothing.

use ark_bn254::{Bn254, Fr};
use ark_groth16::{prepare_verifying_key, Groth16, PreparedVerifyingKey};
use thiserror::Error;

use crate::backend::groth16::proof_from_json;
use crate::backend::points::canonical_field;
use crate::backend::prover::parse_vk_from_json;

/// Why a verification could not be carried out. Match on the variant; the strings are
/// diagnostics for people. None of these is a proof that "failed": that is `Ok(false)`.
#[derive(Clone, Debug, PartialEq, Eq, Error)]
#[non_exhaustive]
pub enum VerificationError {
    /// The verification key is not a usable snarkjs Groth16 BN254 key.
    #[error("invalid verification key: {0}")]
    InvalidVerificationKey(String),
    /// The proof is not a well-formed Groth16 BN254 proof.
    #[error("invalid proof: {0}")]
    InvalidProof(String),
    /// The public signals do not fit the key: wrong count or a non-canonical value.
    #[error("invalid public signals: {0}")]
    InvalidPublicSignals(String),
}

/// Verifies Groth16 proofs for one verification key.
///
/// Built once from the key (parsing, point validation and the pairing precomputation of
/// [`prepare_verifying_key`] happen here), then usable for any number of
/// [`Verifier::verify`] calls. `Send + Sync`; `verify` takes `&self` and keeps no state.
pub struct Verifier {
    pvk: PreparedVerifyingKey<Bn254>,
    num_public_signals: usize,
}

impl Verifier {
    /// Reads a snarkjs `verification_key.json` (`snarkjs zkey export verificationkey`).
    ///
    /// Requires `"protocol": "groth16"`, `"curve": "bn128"` (snarkjs's name for BN254), and
    /// `"nPublic"` equal to the number of `IC` points minus one. Every point is checked to
    /// be on the curve and in the prime-order subgroup.
    pub fn from_snarkjs_json(verification_key_json: &str) -> Result<Self, VerificationError> {
        let bad = |m: String| VerificationError::InvalidVerificationKey(m);
        let value: serde_json::Value =
            serde_json::from_str(verification_key_json).map_err(|e| bad(e.to_string()))?;

        match value.get("protocol").and_then(|v| v.as_str()) {
            Some("groth16") => {}
            other => {
                return Err(bad(format!(
                    "protocol must be \"groth16\", found {}",
                    describe(other)
                )))
            }
        }
        match value.get("curve").and_then(|v| v.as_str()) {
            Some("bn128") => {}
            other => {
                return Err(bad(format!(
                    "curve must be \"bn128\" (BN254), found {}",
                    describe(other)
                )))
            }
        }
        let n_public = value
            .get("nPublic")
            .and_then(|v| v.as_u64())
            .ok_or_else(|| bad("nPublic must be a non-negative integer".into()))?;

        let vk = parse_vk_from_json(verification_key_json).map_err(|e| bad(e.to_string()))?;
        if vk.gamma_abc_g1.is_empty() {
            return Err(bad("IC must contain at least one point".into()));
        }
        let num_public_signals = vk.gamma_abc_g1.len() - 1;
        if u64::try_from(num_public_signals).ok() != Some(n_public) {
            return Err(bad(format!(
                "nPublic is {n_public} but IC has {} points (expected nPublic + 1)",
                vk.gamma_abc_g1.len()
            )));
        }

        Ok(Self {
            pvk: prepare_verifying_key(&vk),
            num_public_signals,
        })
    }

    /// Number of public signals a proof for this key carries.
    pub fn num_public_signals(&self) -> usize {
        self.num_public_signals
    }

    /// Checks `proof_json` (snarkjs `proof.json`, as [`crate::ProofResult::proof_json`]
    /// writes it) against `public_signals` (canonical decimal strings, in the order
    /// snarkjs's `public.json` uses: outputs first, then public inputs).
    ///
    /// See the module documentation for what `Ok(true)`, `Ok(false)` and `Err` mean.
    pub fn verify(
        &self,
        proof_json: &str,
        public_signals: &[String],
    ) -> Result<bool, VerificationError> {
        let proof = proof_from_json(proof_json)
            .map_err(|e| VerificationError::InvalidProof(e.to_string()))?;

        if public_signals.len() != self.num_public_signals {
            return Err(VerificationError::InvalidPublicSignals(format!(
                "the key expects {} public signals, got {}",
                self.num_public_signals,
                public_signals.len()
            )));
        }
        let inputs = public_signals
            .iter()
            .enumerate()
            .map(|(i, s)| {
                canonical_field::<Fr>(s).ok_or_else(|| {
                    VerificationError::InvalidPublicSignals(format!(
                        "public signal {i} (`{}`) is not a canonical decimal below the BN254 \
                         scalar field modulus",
                        s.chars().take(80).collect::<String>()
                    ))
                })
            })
            .collect::<Result<Vec<Fr>, _>>()?;

        // The only error arkworks reports here is an input count that does not match the
        // key, which was checked above.
        Groth16::<Bn254>::verify_proof(&self.pvk, &proof, &inputs)
            .map_err(|e| VerificationError::InvalidPublicSignals(e.to_string()))
    }
}

fn describe(found: Option<&str>) -> String {
    match found {
        Some(s) => format!("\"{}\"", s.chars().take(40).collect::<String>()),
        None => "nothing".into(),
    }
}
