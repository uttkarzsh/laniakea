use crate::{
    error::LaniakeaError,
    witness::{WitnessArtifacts, WitnessCalculator},
};
use ark_bn254::Fr;
use num_bigint::BigInt;

/// Adapter that implements laniakea-core's WitnessCalculator trait
/// by delegating to wasmi_witness::WasmiWitnessCalculator.
pub struct WasmiWitnessAdapter {
    inner: wasmi_witness::WasmiWitnessCalculator,
}

impl WitnessCalculator for WasmiWitnessAdapter {
    fn new(artifacts: WitnessArtifacts) -> Result<Self, LaniakeaError> {
        // iOS path ignores R1CS
        let inner = wasmi_witness::WasmiWitnessCalculator::new(&artifacts.wasm_bytes)
            .map_err(|e| LaniakeaError::WitnessGeneration(e.to_string()))?;
        Ok(Self { inner })
    }

    fn calculate_witness(
        &mut self,
        inputs: &[(String, Vec<BigInt>)],
    ) -> Result<Vec<Fr>, LaniakeaError> {
        self.inner
            .calculate_witness(inputs)
            .map_err(|e| LaniakeaError::WitnessGeneration(e.to_string()))
    }

    fn num_public_inputs(&self) -> usize {
        self.inner.num_public()
    }
}
