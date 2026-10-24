//! The error type Swift sees.
//!
//! A dedicated, flat enum so the Swift API does not depend on `laniakea-core`'s
//! internal error types, which may grow. Every variant is a stable category;
//! the `detail` strings are diagnostics for humans and must not be parsed.
//!
//! Field names avoid `message`, which collides with `Throwable.message` in
//! Kotlin bindings should those ever be generated.

use laniakea_core::{CircuitLoadError, LaniakeaError, WitnessError};

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum ProverError {
    // ---- the caller's input values and names
    /// An input value is not a canonical decimal below the BN254 scalar modulus.
    /// `value` is truncated.
    #[error(
        "input `{signal}`[{index}] is not a canonical decimal below the field modulus: `{value}`"
    )]
    InvalidInputValue {
        signal: String,
        index: u32,
        value: String,
    },
    #[error("unknown input signal `{name}`")]
    UnknownSignal { name: String },
    #[error("input signal `{name}` was provided more than once")]
    DuplicateSignal { name: String },
    #[error("input signal `{signal}` expects {expected} value(s), got {got}")]
    InputSize {
        signal: String,
        expected: u64,
        got: u64,
    },
    #[error("not all inputs were set: {set} of {expected} values provided")]
    MissingInputs { set: u64, expected: u64 },

    // ---- the circuit ran and failed
    /// The circuit rejected the inputs (a failed `assert` or `===`).
    #[error("circuit assertion failed: {detail}")]
    AssertionFailed { detail: String },
    /// The circuit's module could not get the memory it needed.
    #[error("circuit ran out of memory: {detail}")]
    ResourceExhausted { detail: String },
    /// Any other Circom exception, with Circom's code. Not necessarily bad input.
    #[error("circuit aborted: {reason} (code {code}): {detail}")]
    CircuitAbort {
        code: i32,
        reason: String,
        detail: String,
    },
    /// The witness engine failed (not a Circom exception).
    #[error("witness engine error: {detail}")]
    WitnessEngine { detail: String },

    // ---- loading the proving material
    #[error("artifact loading failed: {detail}")]
    ArtifactLoad { detail: String },
    #[error("invalid proving artifact: {detail}")]
    InvalidArtifact { detail: String },
    #[error("invalid circuit module: {detail}")]
    InvalidCircuitModule { detail: String },
    #[error("unsupported field: {detail}")]
    UnsupportedField { detail: String },
    #[error("circuit engine error: {detail}")]
    CircuitEngine { detail: String },

    // ---- proving
    #[error("invalid witness: {detail}")]
    InvalidWitness { detail: String },
    #[error("proof generation failed: {detail}")]
    ProofGeneration { detail: String },

    /// Anything not covered above: errors that `prove` cannot currently produce
    /// (verification, JSON, curve points) and variants added to the core later.
    /// A bug or a version mismatch, never the caller's input.
    #[error("internal error: {detail}")]
    Internal { detail: String },
}

fn from_witness(e: WitnessError) -> ProverError {
    match e {
        WitnessError::UnknownSignal { name } => ProverError::UnknownSignal { name },
        WitnessError::DuplicateSignal { name } => ProverError::DuplicateSignal { name },
        WitnessError::InputSize {
            signal,
            expected,
            got,
        } => ProverError::InputSize {
            signal,
            expected: expected as u64,
            got: got as u64,
        },
        WitnessError::MissingInputs { set, expected } => ProverError::MissingInputs {
            set: set as u64,
            expected: expected as u64,
        },
        WitnessError::AssertionFailed { detail } => ProverError::AssertionFailed { detail },
        WitnessError::ResourceExhausted { detail } => ProverError::ResourceExhausted { detail },
        WitnessError::CircuitAbort {
            code,
            reason,
            detail,
        } => ProverError::CircuitAbort {
            code,
            reason,
            detail,
        },
        WitnessError::Engine(detail) => ProverError::WitnessEngine { detail },
        // `WitnessError` is #[non_exhaustive]: a variant added to the core later
        // lands here, as an internal error, never as a caller error.
        other => ProverError::Internal {
            detail: format!("unrecognised witness error: {other}"),
        },
    }
}

fn from_circuit_load(e: CircuitLoadError) -> ProverError {
    match e {
        CircuitLoadError::InvalidModule(detail) => ProverError::InvalidCircuitModule { detail },
        CircuitLoadError::UnsupportedField(detail) => ProverError::UnsupportedField { detail },
        CircuitLoadError::Engine(detail) => ProverError::CircuitEngine { detail },
        other => ProverError::Internal {
            detail: format!("unrecognised circuit load error: {other}"),
        },
    }
}

impl From<LaniakeaError> for ProverError {
    fn from(e: LaniakeaError) -> Self {
        // No catch-all: `LaniakeaError` is not #[non_exhaustive], so a variant
        // added to the core fails to compile here until it is mapped on purpose.
        match e {
            LaniakeaError::WitnessGeneration(w) => from_witness(w),
            LaniakeaError::CircuitLoad(c) => from_circuit_load(c),
            LaniakeaError::ArtifactLoad(detail) => ProverError::ArtifactLoad { detail },
            LaniakeaError::InvalidArtifact(detail) => ProverError::InvalidArtifact { detail },
            LaniakeaError::InvalidWitness(detail) => ProverError::InvalidWitness { detail },
            LaniakeaError::ProofGeneration(detail) => ProverError::ProofGeneration { detail },
            e @ (LaniakeaError::Verification(_)
            | LaniakeaError::Serialization(_)
            | LaniakeaError::InvalidPoint { .. }) => ProverError::Internal {
                detail: e.to_string(),
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use laniakea_core::PointFault;

    fn map(e: LaniakeaError) -> ProverError {
        e.into()
    }
    fn w(e: WitnessError) -> ProverError {
        map(LaniakeaError::WitnessGeneration(e))
    }
    fn c(e: CircuitLoadError) -> ProverError {
        map(LaniakeaError::CircuitLoad(e))
    }

    #[test]
    fn witness_errors_map_one_to_one() {
        assert!(matches!(
            w(WitnessError::UnknownSignal { name: "a".into() }),
            ProverError::UnknownSignal { name } if name == "a"
        ));
        assert!(matches!(
            w(WitnessError::DuplicateSignal { name: "a".into() }),
            ProverError::DuplicateSignal { name } if name == "a"
        ));
        assert!(matches!(
            w(WitnessError::InputSize { signal: "v".into(), expected: 3, got: 2 }),
            ProverError::InputSize { signal, expected: 3, got: 2 } if signal == "v"
        ));
        assert!(matches!(
            w(WitnessError::MissingInputs {
                set: 1,
                expected: 2
            }),
            ProverError::MissingInputs {
                set: 1,
                expected: 2
            }
        ));
        assert!(matches!(
            w(WitnessError::AssertionFailed { detail: "t".into() }),
            ProverError::AssertionFailed { detail } if detail == "t"
        ));
        assert!(matches!(
            w(WitnessError::ResourceExhausted { detail: "t".into() }),
            ProverError::ResourceExhausted { detail } if detail == "t"
        ));
        assert!(matches!(
            w(WitnessError::CircuitAbort { code: 6, reason: "r".into(), detail: "t".into() }),
            ProverError::CircuitAbort { code: 6, reason, detail } if reason == "r" && detail == "t"
        ));
        assert!(matches!(
            w(WitnessError::Engine("e".into())),
            ProverError::WitnessEngine { detail } if detail == "e"
        ));
    }

    #[test]
    fn circuit_load_errors_map_one_to_one() {
        assert!(matches!(
            c(CircuitLoadError::InvalidModule("m".into())),
            ProverError::InvalidCircuitModule { detail } if detail == "m"
        ));
        assert!(matches!(
            c(CircuitLoadError::UnsupportedField("f".into())),
            ProverError::UnsupportedField { detail } if detail == "f"
        ));
        assert!(matches!(
            c(CircuitLoadError::Engine("e".into())),
            ProverError::CircuitEngine { detail } if detail == "e"
        ));
    }

    #[test]
    fn top_level_errors_map_to_their_own_categories() {
        assert!(matches!(
            map(LaniakeaError::ArtifactLoad("a".into())),
            ProverError::ArtifactLoad { detail } if detail == "a"
        ));
        assert!(matches!(
            map(LaniakeaError::InvalidArtifact("a".into())),
            ProverError::InvalidArtifact { detail } if detail == "a"
        ));
        assert!(matches!(
            map(LaniakeaError::InvalidWitness("a".into())),
            ProverError::InvalidWitness { detail } if detail == "a"
        ));
        assert!(matches!(
            map(LaniakeaError::ProofGeneration("a".into())),
            ProverError::ProofGeneration { detail } if detail == "a"
        ));
    }

    #[test]
    fn errors_prove_cannot_produce_become_internal_not_user_errors() {
        for e in [
            LaniakeaError::Verification("v".into()),
            LaniakeaError::Serialization("s".into()),
            LaniakeaError::InvalidPoint {
                what: "proof.a".into(),
                fault: PointFault::NotOnCurve,
            },
        ] {
            let text = e.to_string();
            match map(e) {
                ProverError::Internal { detail } => assert_eq!(detail, text),
                other => panic!("expected Internal, got {other:?}"),
            }
        }
    }

    #[test]
    fn display_carries_the_detail() {
        let e = w(WitnessError::AssertionFailed {
            detail: "Error in template X".into(),
        });
        assert!(e.to_string().contains("Error in template X"));
    }
}
