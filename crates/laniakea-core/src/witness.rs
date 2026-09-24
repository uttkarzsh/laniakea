use crate::error::LaniakeaError;

pub struct WitnessBuilder {
    wasm_bytes: Vec<u8>,
    r1cs_bytes: Vec<u8>,
}

impl WitnessBuilder {
    pub fn new(wasm_bytes: Vec<u8>, r1cs_bytes: Vec<u8>) -> Self {
        Self { wasm_bytes, r1cs_bytes }
    }

    pub fn build_circom(
        &self,
        _inputs: &[(String, Vec<num_bigint::BigInt>)],
    ) -> Result<(), LaniakeaError> {
        Err(LaniakeaError::WitnessGeneration("not implemented".into()))
    }
}