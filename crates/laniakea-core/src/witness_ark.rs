use crate::{
    error::LaniakeaError,
    witness::{WitnessArtifacts, WitnessCalculator},
};
use ark_bn254::{Bn254, Fr};
use ark_circom::{CircomBuilder, CircomConfig};
use num_bigint::BigInt;
use std::io::Write;

pub struct ArkCircomWitness {
    cfg: CircomConfig<Bn254>,
}

impl WitnessCalculator for ArkCircomWitness {
    fn new(artifacts: WitnessArtifacts) -> Result<Self, LaniakeaError> {
        let r1cs_bytes = artifacts.r1cs_bytes.ok_or_else(|| {
            LaniakeaError::WitnessGeneration(
                "R1CS required for ark-circom witness generation".into(),
            )
        })?;

        // Write WASM and R1CS bytes to temporary files for CircomConfig::new
        let temp_dir = tempfile::tempdir().map_err(|e| {
            LaniakeaError::WitnessGeneration(format!("Failed to create temp dir: {}", e))
        })?;

        let wasm_path = temp_dir.path().join("circuit.wasm");
        let r1cs_path = temp_dir.path().join("circuit.r1cs");

        std::fs::write(&wasm_path, &artifacts.wasm_bytes).map_err(|e| {
            LaniakeaError::WitnessGeneration(format!("Failed to write WASM: {}", e))
        })?;
        std::fs::write(&r1cs_path, &r1cs_bytes).map_err(|e| {
            LaniakeaError::WitnessGeneration(format!("Failed to write R1CS: {}", e))
        })?;

        let cfg = CircomConfig::<Bn254>::new(&wasm_path, &r1cs_path)
            .map_err(|e| LaniakeaError::WitnessGeneration(e.to_string()))?;

        // Keep temp_dir alive by storing it (it will be cleaned up when dropped)
        // For now, we just leak it since the config doesn't depend on the files after creation
        std::mem::forget(temp_dir);

        Ok(Self { cfg })
    }

    fn calculate_witness(
        &mut self,
        inputs: &[(String, Vec<BigInt>)],
    ) -> Result<Vec<Fr>, LaniakeaError> {
        let mut builder = CircomBuilder::new(self.cfg.clone());
        for (name, values) in inputs {
            for v in values {
                builder.push_input(name, v.clone());
            }
        }
        let circom = builder
            .build()
            .map_err(|e| LaniakeaError::WitnessGeneration(e.to_string()))?;
        Ok(circom.witness.unwrap())
    }

    fn num_public_inputs(&self) -> usize {
        self.cfg.r1cs.num_inputs
    }
}
