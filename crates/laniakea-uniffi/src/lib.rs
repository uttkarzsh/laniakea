//! Swift-facing wrapper around `laniakea-core`'s [`laniakea_core::Prover`].
//!
//! The core knows nothing about UniFFI; this crate owns the FFI vocabulary:
//! decimal-string inputs, a flat error enum, and plain records.

mod error;
mod inputs;

use std::sync::Arc;

pub use error::ProverError;

uniffi::setup_scaffolding!("laniakea");

/// One named circuit input and its values. Array signals are flattened under
/// the array's name (`"v"`, not `"v[0]"`). Each value is a canonical decimal
/// string below the BN254 scalar field modulus.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct CircuitInput {
    pub name: String,
    pub values: Vec<String>,
}

/// A Groth16 proof and the public signals it was generated for.
#[derive(Clone, Debug, PartialEq, Eq, uniffi::Record)]
pub struct ProofResult {
    /// The proof in snarkjs `proof.json` layout.
    pub proof_json: String,
    /// Public signals as canonical decimal strings, outputs first and then
    /// public inputs. A valid proof does not say the application condition
    /// holds: for age_check, read `public_signals[0]` (`out`) yourself.
    pub public_signals: Vec<String>,
}

/// Proves statements about one Circom circuit, on the Wasmi interpreter.
///
/// Built once from the serialized proving artifact and the circuit's WASM, then
/// usable for any number of [`LaniakeaProver::prove`] calls, from any thread.
/// `prove` is CPU-bound and blocks: call it off the main thread.
#[derive(uniffi::Object)]
pub struct LaniakeaProver {
    inner: laniakea_core::Prover,
}

#[uniffi::export]
impl LaniakeaProver {
    /// Validates the artifact and loads the circuit. Nothing borrows from the
    /// byte arrays afterwards.
    #[uniffi::constructor]
    pub fn new(artifact_bytes: Vec<u8>, wasm_bytes: Vec<u8>) -> Result<Arc<Self>, ProverError> {
        let inner = laniakea_core::Prover::new(&artifact_bytes, &wasm_bytes)?;
        Ok(Arc::new(Self { inner }))
    }

    /// Generate a proof. Blocking.
    pub fn prove(&self, inputs: Vec<CircuitInput>) -> Result<ProofResult, ProverError> {
        let mut parsed = Vec::with_capacity(inputs.len());
        for input in inputs {
            let mut values = Vec::with_capacity(input.values.len());
            for (index, text) in input.values.iter().enumerate() {
                let value = inputs::parse_field_decimal(text).ok_or_else(|| {
                    ProverError::InvalidInputValue {
                        signal: input.name.clone(),
                        index: u32::try_from(index).unwrap_or(u32::MAX),
                        value: inputs::truncate_for_diagnostic(text),
                    }
                })?;
                values.push(value);
            }
            parsed.push((input.name, values));
        }

        let result = self.inner.prove(&parsed)?;
        Ok(ProofResult {
            proof_json: result.proof_json(),
            public_signals: result.public_signals,
        })
    }

    /// Number of public signals a proof carries.
    pub fn num_public_signals(&self) -> u32 {
        u32::try_from(self.inner.num_public_signals()).unwrap_or(u32::MAX)
    }
}
