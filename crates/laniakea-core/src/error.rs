use thiserror::Error;

#[derive(Debug, Error)]
pub enum LaniakeaError {
    #[error("witness generation failed: {0}")]
    WitnessGeneration(String),

    #[error("proof generation failed: {0}")]
    ProofGeneration(String),

    #[error("verification failed: {0}")]
    Verification(String),

    /// Artifact bytes could not be read: empty, truncated, malformed, a point
    /// that fails curve/subgroup validation, or trailing data.
    #[error("artifact loading failed: {0}")]
    ArtifactLoad(String),

    /// The artifact was read but its parts are structurally inconsistent (for
    /// example query lengths that disagree). Structural only: it says nothing
    /// about whether the keys are cryptographically correct.
    #[error("invalid proving artifact: {0}")]
    InvalidArtifact(String),

    /// The witness does not fit the proving artifact (wrong length, or the
    /// leading constant is not 1). Distinct from `WitnessGeneration`, which is
    /// a failure to compute a witness at all.
    #[error("invalid witness: {0}")]
    InvalidWitness(String),

    #[error("serialization error: {0}")]
    Serialization(String),
}
