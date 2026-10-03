use crate::error::LaniakeaError;
use ark_bn254::Fr;
use num_bigint::BigInt;

/// Artifacts required for witness generation.
/// Desktop (ark-circom) requires both WASM and R1CS.
/// iOS (wasmi-witness) requires only WASM.
pub struct WitnessArtifacts {
    pub wasm_bytes: Vec<u8>,
    pub r1cs_bytes: Option<Vec<u8>>, // None on iOS, Some on desktop
}

/// Trait for generating a Circom witness from WASM (+ R1CS on desktop) + inputs.
/// Returns a BN254 witness vector: [1, public_inputs..., private_wires...]
pub trait WitnessCalculator {
    /// Create a new calculator from artifacts.
    fn new(artifacts: WitnessArtifacts) -> Result<Self, LaniakeaError>
    where
        Self: Sized;

    /// Calculate the witness as BN254 scalar field elements (Fr).
    /// Returns witness in Arkworks format: [1, public_inputs..., private_wires...]
    fn calculate_witness(
        &mut self,
        inputs: &[(String, Vec<BigInt>)],
    ) -> Result<Vec<Fr>, LaniakeaError>;

    /// Get the number of public inputs (including the implicit "1" at index 0).
    fn num_public_inputs(&self) -> usize;
}
