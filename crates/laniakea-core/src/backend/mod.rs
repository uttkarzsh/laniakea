use crate::error::LaniakeaError;

/// Inputs to the witness generator: a map of signal name → field element values.
pub type WitnessInputs = Vec<(String, Vec<num_bigint::BigInt>)>;

/// The proving artifact bundle loaded from disk/bytes.
pub struct ProvingArtifacts {
    pub zkey_bytes: Vec<u8>,
    pub wasm_bytes: Vec<u8>,
}

/// Returned proof + public signals in a serializable form.
pub struct ProofOutput {
    pub proof_json: String,
    pub public_signals_json: String,
}

pub trait ZkBackend {
    fn prove(
        &self,
        artifacts: &ProvingArtifacts,
        inputs: &WitnessInputs,
    ) -> Result<ProofOutput, LaniakeaError>;

    fn verify(
        &self,
        proof_json: &str,
        public_signals_json: &str,
        vk_bytes: &[u8],
    ) -> Result<bool, LaniakeaError>;
}

pub mod circom_reduction;
pub mod groth16;
pub mod prover;
