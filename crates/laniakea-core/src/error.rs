use thiserror::Error;

#[derive(Debug, Error)]
pub enum LaniakeaError {
    #[error("witness generation failed: {0}")]
    WitnessGeneration(String),

    #[error("proof generation failed: {0}")]
    ProofGeneration(String),

    #[error("verification failed: {0}")]
    Verification(String),

    #[error("artifact loading failed: {0}")]
    ArtifactLoad(String),

    #[error("serialization error: {0}")]
    Serialization(String),
}
