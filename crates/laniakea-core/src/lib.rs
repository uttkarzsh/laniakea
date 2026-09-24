//! laniakea-core: pure Rust proving logic

pub mod backend;
pub mod error;
pub mod witness;

pub use backend::groth16::Groth16Backend;
pub use backend::{ProofOutput, ProvingArtifacts, WitnessInputs, ZkBackend};
pub use error::LaniakeaError;

