use super::{ProvingArtifacts, ProofOutput, WitnessInputs, ZkBackend};
use crate::error::LaniakeaError;

pub struct Groth16Backend;

impl ZkBackend for Groth16Backend {
    fn prove(
        &self,
        _artifacts: &ProvingArtifacts,
        _inputs: &WitnessInputs,
    ) -> Result<ProofOutput, LaniakeaError> {
        Err(LaniakeaError::ProofGeneration("not implemented".into()))
    }

    fn verify(
        &self,
        _proof_json: &str,
        _public_signals_json: &str,
        _vk_bytes: &[u8],
    ) -> Result<bool, LaniakeaError> {
        Err(LaniakeaError::Verification("not implemented".into()))
    }
}