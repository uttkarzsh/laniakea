//! High-level proving API: circuit inputs in, Groth16 proof and public signals out.
//!
//! ```text
//! inputs ──► Wasmi witness engine ──► witness ──► shape check ──► Groth16 prover ──► ProofResult
//!                                       ▲                              ▲
//!                       circuit .wasm ──┘          proving artifact ───┘ (validated once, at construction)
//! ```
//!
//! Everything here is the portable, interpreter-only path: no ark-circom, no
//! Wasmer, no JIT, no filesystem access. Callers hand in bytes.
//!
//! # What a proof does and does not tell you
//!
//! A returned proof says "some private inputs make the circuit produce these
//! public signals". It does **not** say the application condition holds. The
//! age-check circuit, for instance, outputs `out = 1` when `age >= threshold`
//! and `out = 0` otherwise, and a valid proof exists for either. Callers must
//! read the relevant entry of [`ProofResult::public_signals`] themselves.

use crate::artifacts::{check_witness_shape, ProvingArtifact};
use crate::backend::prover::{extract_public_signals, prove_validated};
use crate::error::LaniakeaError;
use ark_bn254::{Bn254, Fq, Fr};
use ark_ff::PrimeField;
use ark_groth16::{Proof, ProvingKey};
use ark_relations::r1cs::ConstraintMatrices;
use num_bigint::BigInt;
use wasmi_witness::{WasmiWitnessCalculator, WasmiWitnessError};

/// A Groth16 proof over BN254 as plain decimal strings, so callers need no
/// Arkworks types. Coordinates are canonical (`"0"` for zero).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Groth16Proof {
    /// G1 point `A`: `[x, y]`.
    pub a: [String; 2],
    /// G2 point `B`: `[[x.c0, x.c1], [y.c0, y.c1]]`.
    pub b: [[String; 2]; 2],
    /// G1 point `C`: `[x, y]`.
    pub c: [String; 2],
}

fn fq(v: &Fq) -> String {
    v.into_bigint().to_string()
}

fn fr(v: &Fr) -> String {
    v.into_bigint().to_string()
}

impl From<&Proof<Bn254>> for Groth16Proof {
    fn from(p: &Proof<Bn254>) -> Self {
        Self {
            a: [fq(&p.a.x), fq(&p.a.y)],
            b: [
                [fq(&p.b.x.c0), fq(&p.b.x.c1)],
                [fq(&p.b.y.c0), fq(&p.b.y.c1)],
            ],
            c: [fq(&p.c.x), fq(&p.c.y)],
        }
    }
}

impl Groth16Proof {
    /// The proof in snarkjs's `proof.json` layout (projective `z` coordinates
    /// included), accepted by `snarkjs groth16 verify` and by
    /// [`crate::Groth16Backend`]'s verifier.
    pub fn to_snarkjs_json(&self) -> String {
        serde_json::json!({
            "pi_a": [self.a[0], self.a[1], "1"],
            "pi_b": [self.b[0], self.b[1], ["1", "0"]],
            "pi_c": [self.c[0], self.c[1], "1"],
            "protocol": "groth16",
            "curve": "bn128",
        })
        .to_string()
    }
}

/// A proof together with the public signals it was generated for.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProofResult {
    pub proof: Groth16Proof,
    /// Public signals as canonical decimal strings, in the circuit's order:
    /// public outputs first, then public inputs (`witness[1..n_public + 1]`).
    /// For age_check: `[out, threshold]`. Nothing here is interpreted: whether
    /// `out` means success is the caller's decision.
    pub public_signals: Vec<String>,
}

impl ProofResult {
    /// The proof as snarkjs `proof.json`.
    pub fn proof_json(&self) -> String {
        self.proof.to_snarkjs_json()
    }

    /// The public signals as snarkjs `public.json`: a JSON array of decimal strings.
    pub fn public_signals_json(&self) -> String {
        serde_json::json!(self.public_signals).to_string()
    }
}

/// Proves statements about one Circom circuit.
///
/// A `Prover` is built once from the circuit's WASM and its proving artifact and
/// then used for any number of [`Prover::prove`] calls.
///
/// # Ownership and mutability
///
/// * The `Prover` owns the proving key, the constraint matrices (converted once,
///   not per call) and the compiled WASM module. Nothing borrows from the byte
///   slices passed to the constructors; callers may drop them afterwards.
/// * Those fields are private and never modified after construction, so the
///   validation done in the constructor holds for the `Prover`'s whole life.
/// * [`Prover::prove`] takes `&self`. Each call runs the witness engine on a
///   fresh WASM instance (see [`WasmiWitnessCalculator::calculate_witness`]), so
///   a failed call leaves nothing behind and the next call is unaffected. The
///   type is `Send + Sync`: one `Prover` can serve several threads, which prove
///   independently.
///
/// # Validation
///
/// The artifact is validated once, in the constructor
/// ([`ProvingArtifact::validate`]). Each call checks the witness against it
/// ([`ProvingArtifact::validate_witness`]) before proving. These are structural
/// checks; see their documentation for what they cannot establish. In
/// particular the artifact carries no circuit identity, so the constructor can
/// only catch a WASM/artifact pair whose wire counts disagree, not every
/// mismatch.
pub struct Prover {
    proving_key: ProvingKey<Bn254>,
    matrices: ConstraintMatrices<Fr>,
    witness_engine: WasmiWitnessCalculator,
}

fn load_wasm(wasm_bytes: &[u8]) -> Result<WasmiWitnessCalculator, LaniakeaError> {
    WasmiWitnessCalculator::new(wasm_bytes)
        .map_err(|e| LaniakeaError::ArtifactLoad(format!("circuit WASM: {e}")))
}

impl Prover {
    /// Build a prover from serialized artifacts: the output of
    /// [`ProvingArtifact::to_bytes`] and the circuit's `.wasm`.
    ///
    /// Errors: [`LaniakeaError::ArtifactLoad`] for unreadable bytes or an
    /// unusable WASM module, [`LaniakeaError::InvalidArtifact`] for an
    /// inconsistent artifact or a WASM/artifact pair with different wire counts.
    pub fn new(artifact_bytes: &[u8], wasm_bytes: &[u8]) -> Result<Self, LaniakeaError> {
        // `from_bytes` has already validated.
        Self::assemble(ProvingArtifact::from_bytes(artifact_bytes)?, wasm_bytes)
    }

    /// Like [`Prover::new`], for an artifact already in memory (for example one
    /// just produced by `parse_zkey_to_artifact`). The artifact's fields are
    /// public, so it is validated here.
    pub fn from_artifact(
        artifact: ProvingArtifact,
        wasm_bytes: &[u8],
    ) -> Result<Self, LaniakeaError> {
        artifact.validate()?;
        Self::assemble(artifact, wasm_bytes)
    }

    /// `artifact` must already have passed [`ProvingArtifact::validate`].
    fn assemble(artifact: ProvingArtifact, wasm_bytes: &[u8]) -> Result<Self, LaniakeaError> {
        let witness_engine = load_wasm(wasm_bytes)?;

        let expected = artifact.witness_len();
        if witness_engine.witness_size() != expected {
            return Err(LaniakeaError::InvalidArtifact(format!(
                "the circuit WASM produces {} wires but the proving artifact expects {expected}; \
                 they were not built from the same circuit",
                witness_engine.witness_size()
            )));
        }

        // Take the parts, converting the matrices by move: no second copy.
        let ProvingArtifact {
            proving_key,
            matrices,
        } = artifact;
        Ok(Self {
            proving_key,
            matrices: matrices.into(),
            witness_engine,
        })
    }

    /// Number of wires in the circuit's witness, constant `1` included.
    pub fn witness_len(&self) -> usize {
        self.proving_key.a_query.len()
    }

    /// Number of public signals a proof carries (public outputs and inputs,
    /// excluding the constant `1`).
    pub fn num_public_signals(&self) -> usize {
        self.matrices.num_instance_variables - 1
    }

    /// Generate a proof for `inputs`.
    ///
    /// `inputs` uses the witness engine's representation: `(signal name, values)`
    /// pairs, arrays flattened under the array's name (`"v"`, not `"v[0]"`),
    /// values reduced modulo the BN254 scalar field with negatives wrapping.
    ///
    /// Steps: compute the witness; check it fits the artifact; prove. Errors:
    ///
    /// * [`LaniakeaError::WitnessGeneration`]: unknown, repeated or missing
    ///   inputs, a wrong array length, or the circuit aborting (a failed
    ///   `assert` or `===`). No proof is attempted.
    /// * [`LaniakeaError::InvalidWitness`]: the engine's witness does not fit the
    ///   artifact.
    /// * [`LaniakeaError::ProofGeneration`]: the Groth16 prover failed.
    ///
    /// Success means a proof was produced for the circuit's computed outputs.
    /// It says nothing about their *meaning*: check `public_signals` yourself
    /// (see the module documentation).
    ///
    /// Proofs are randomised: two calls with the same inputs return different
    /// proofs and identical public signals.
    pub fn prove(&self, inputs: &[(String, Vec<BigInt>)]) -> Result<ProofResult, LaniakeaError> {
        let witness = self
            .witness_engine
            .calculate_witness(inputs)
            .map_err(|e: WasmiWitnessError| LaniakeaError::WitnessGeneration(e.to_string()))?;

        let n_inst = self.matrices.num_instance_variables;
        check_witness_shape(&witness, self.witness_len(), n_inst)?;

        let proof = prove_validated(&self.proving_key, &self.matrices, &witness)?;

        // Safe after the shape check: witness.len() == wire count >= n_inst >= 1.
        let public_signals = extract_public_signals(&witness, n_inst)
            .iter()
            .map(fr)
            .collect();

        Ok(ProofResult {
            proof: Groth16Proof::from(&proof),
            public_signals,
        })
    }
}
