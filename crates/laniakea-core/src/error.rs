use thiserror::Error;

#[derive(Debug, Error)]
pub enum LaniakeaError {
    /// Witness generation failed. The payload says why, as a matchable
    /// category rather than a message; see [`WitnessError`].
    #[error("witness generation failed: {0}")]
    WitnessGeneration(WitnessError),

    #[error("proof generation failed: {0}")]
    ProofGeneration(String),

    #[error("verification failed: {0}")]
    Verification(String),

    /// Artifact bytes could not be read: empty, truncated, malformed, a point
    /// that fails curve/subgroup validation, or trailing data.
    #[error("artifact loading failed: {0}")]
    ArtifactLoad(String),

    /// The circuit's WASM module could not be loaded. Distinct from
    /// [`ArtifactLoad`](Self::ArtifactLoad), which is about the proving artifact.
    #[error("circuit loading failed: {0}")]
    CircuitLoad(CircuitLoadError),

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

    /// Input could not be parsed (bad JSON, a coordinate or field element that
    /// is not a canonical decimal, wrong tuple shape).
    #[error("serialization error: {0}")]
    Serialization(String),

    /// A curve point was decoded but is not a valid group element. `what` names
    /// the point (`"proof.a"`, `"vk.IC[2]"`). Returned instead of ever feeding
    /// such a point to a pairing. This is an error in the *input*, unlike a
    /// well-formed proof that simply does not verify, which is `Ok(false)`.
    #[error("invalid curve point {what}: {fault}")]
    InvalidPoint { what: String, fault: PointFault },
}

/// Why a decoded curve point was rejected.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Error)]
pub enum PointFault {
    #[error("not on the curve")]
    NotOnCurve,
    #[error("on the curve but not in the prime-order subgroup")]
    NotInSubgroup,
}

/// Why the circuit's WASM module could not be loaded.
#[derive(Clone, Debug, PartialEq, Eq, Error)]
#[non_exhaustive]
pub enum CircuitLoadError {
    /// Not a usable Circom witness-calculator module: it does not parse or
    /// validate as WebAssembly, lacks an expected export, or reports nonsense
    /// (such as negative sizes).
    #[error("invalid circuit module: {0}")]
    InvalidModule(String),

    /// The circuit works over a field other than the BN254 scalar field.
    #[error("unsupported field: {0}")]
    UnsupportedField(String),

    /// The module was valid but the engine failed while reading its constants
    /// (a trap or memory error). Diagnostic text only.
    #[error("witness engine error: {0}")]
    Engine(String),
}

impl From<wasmi_witness::WasmiWitnessError> for CircuitLoadError {
    fn from(e: wasmi_witness::WasmiWitnessError) -> Self {
        use wasmi_witness::WasmiWitnessError as W;
        match e {
            W::Module(m) | W::Instantiation(m) => Self::InvalidModule(m),
            W::UnsupportedField(m) => Self::UnsupportedField(m),
            other => Self::Engine(other.to_string()),
        }
    }
}

/// Circom's exception codes, as raised by the generated module's
/// `exceptionHandler` (same numbering as the JS calculator).
mod circom_code {
    pub const ASSERT_FAILED: i32 = 4;
    pub const NOT_ENOUGH_MEMORY: i32 = 5;
}

/// Why witness generation failed. Match on the variant, never on the message.
///
/// * input problems, detected on the host side before the circuit runs:
///   [`UnknownSignal`](Self::UnknownSignal), [`DuplicateSignal`](Self::DuplicateSignal),
///   [`InputSize`](Self::InputSize), [`MissingInputs`](Self::MissingInputs);
/// * the circuit evaluated the inputs and rejected them:
///   [`AssertionFailed`](Self::AssertionFailed) (Circom code 4, a failed
///   `assert` or `===`);
/// * the module could not grow its memory: [`ResourceExhausted`](Self::ResourceExhausted)
///   (code 5, insufficient memory). Not an input error and not an assertion;
/// * any other Circom exception: [`CircuitAbort`](Self::CircuitAbort), with the
///   original code and diagnostic context preserved.
///   - Codes 1, 2, 3 and 6 are input-signal handling errors raised by the
///     generated `$setInputSignal` function (signal not found, too many
///     signals set, signal already set, index beyond the input's size). The
///     host-side checks above normally catch these cases first, so one
///     reaching the witness engine indicates an input-layout or host/module
///     disagreement. They are deliberately not classified as caller errors.
///   - Any other code is passed through as is, without assuming it represents
///     invalid user input;
/// * everything else (trap, memory read error): [`Engine`](Self::Engine).
#[derive(Clone, Debug, PartialEq, Eq, Error)]
#[non_exhaustive]
pub enum WitnessError {
    #[error("unknown input signal `{name}`")]
    UnknownSignal { name: String },

    #[error("input signal `{name}` was provided more than once")]
    DuplicateSignal { name: String },

    #[error("input signal `{signal}` expects {expected} value(s), got {got}")]
    InputSize {
        signal: String,
        expected: usize,
        got: usize,
    },

    #[error("not all inputs were set: {set} of {expected} values provided")]
    MissingInputs { set: usize, expected: usize },

    /// A failed `assert` or `===` in the circuit (Circom exception code 4).
    /// `detail` is the template trace the module reported, if any.
    #[error("circuit assertion failed{}", fmt_detail(.detail))]
    AssertionFailed { detail: String },

    /// The module ran out of memory (Circom exception code 5).
    #[error("circuit ran out of memory{}", fmt_detail(.detail))]
    ResourceExhausted { detail: String },

    /// Any other Circom exception. `code` is Circom's, `reason` its name.
    #[error("circuit aborted: {reason} (code {code}){}", fmt_detail(.detail))]
    CircuitAbort {
        code: i32,
        reason: String,
        detail: String,
    },

    /// The witness engine itself failed: a trap that is not a Circom exception,
    /// a memory read error, or a non-wasmi engine's own error. Diagnostic text
    /// only.
    #[error("witness engine error: {0}")]
    Engine(String),
}

fn fmt_detail(detail: &str) -> String {
    if detail.is_empty() {
        String::new()
    } else {
        format!(": {detail}")
    }
}

impl From<wasmi_witness::WasmiWitnessError> for WitnessError {
    fn from(e: wasmi_witness::WasmiWitnessError) -> Self {
        use wasmi_witness::WasmiWitnessError as W;
        match e {
            W::UnknownSignal(name) => Self::UnknownSignal { name },
            W::DuplicateSignal(name) => Self::DuplicateSignal { name },
            W::InputSize {
                signal,
                expected,
                got,
            } => Self::InputSize {
                signal,
                expected,
                got,
            },
            W::MissingInputs { set, expected } => Self::MissingInputs { set, expected },
            W::Circom {
                code,
                reason,
                detail,
            } => {
                let detail = detail.trim_end().replace('\n', "; ");
                match code {
                    circom_code::ASSERT_FAILED => Self::AssertionFailed { detail },
                    circom_code::NOT_ENOUGH_MEMORY => Self::ResourceExhausted { detail },
                    _ => Self::CircuitAbort {
                        code,
                        reason: reason.to_string(),
                        detail,
                    },
                }
            }
            other => Self::Engine(other.to_string()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wasmi_witness::WasmiWitnessError as W;

    fn circom(code: i32) -> W {
        W::Circom {
            code,
            reason: "r",
            detail: "Template.a line 3\n".into(),
        }
    }

    #[test]
    fn circom_codes_map_to_distinct_categories() {
        assert_eq!(
            WitnessError::from(circom(4)),
            WitnessError::AssertionFailed {
                detail: "Template.a line 3".into()
            }
        );
        assert!(matches!(
            WitnessError::from(circom(5)),
            WitnessError::ResourceExhausted { .. }
        ));
        // Everything else keeps its code and is neither assertion nor resource.
        for code in [1, 2, 3, 6, 7, -1] {
            assert!(
                matches!(WitnessError::from(circom(code)), WitnessError::CircuitAbort { code: c, .. } if c == code),
                "code {code}"
            );
        }
    }

    #[test]
    fn engine_failures_stay_distinct_from_circuit_failures() {
        for e in [
            W::Execution("trap".into()),
            W::MemoryRead("oob".into()),
            W::WitnessGeneration("non-canonical".into()),
        ] {
            assert!(matches!(WitnessError::from(e), WitnessError::Engine(_)));
        }
    }

    #[test]
    fn load_errors_are_categorised() {
        assert!(matches!(
            CircuitLoadError::from(W::Module("x".into())),
            CircuitLoadError::InvalidModule(_)
        ));
        assert!(matches!(
            CircuitLoadError::from(W::Instantiation("missing export".into())),
            CircuitLoadError::InvalidModule(_)
        ));
        assert!(matches!(
            CircuitLoadError::from(W::UnsupportedField("p".into())),
            CircuitLoadError::UnsupportedField(_)
        ));
        assert!(matches!(
            CircuitLoadError::from(W::Execution("trap".into())),
            CircuitLoadError::Engine(_)
        ));
    }
}
