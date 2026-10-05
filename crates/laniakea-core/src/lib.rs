//! laniakea-core: pure Rust proving logic

pub mod artifacts;
pub mod backend;
pub mod error;
pub mod witness;
#[cfg(not(target_os = "ios"))]
pub mod witness_ark;
#[cfg(any(target_os = "ios", target_os = "macos"))]
pub mod witness_wasmi;

#[cfg(not(target_os = "ios"))]
pub use artifacts::parse_zkey_to_artifact;
pub use artifacts::ProvingArtifact;
pub use backend::groth16::Groth16Backend;
pub use backend::{ProofOutput, ProvingArtifacts, WitnessInputs, ZkBackend};
pub use error::LaniakeaError;
pub use witness::{WitnessArtifacts, WitnessCalculator};
