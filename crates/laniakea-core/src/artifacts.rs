use crate::error::LaniakeaError;
use ark_bn254::Fr;
use ark_ff::One;
use ark_groth16::ProvingKey;
use ark_poly::{EvaluationDomain, GeneralEvaluationDomain};
use ark_relations::r1cs::ConstraintMatrices;
use ark_serialize::{CanonicalDeserialize, CanonicalSerialize};
use ark_std::vec::Vec;

/// The 8 magic bytes that start every `.artifact` file: `\x89LNKART\n`. The
/// non-ASCII first byte keeps a text file from matching; the final newline catches
/// line-ending conversion.
pub const ARTIFACT_MAGIC: [u8; 8] = [0x89, b'L', b'N', b'K', b'A', b'R', b'T', 0x0A];
/// The artifact format version this build reads and writes. It defines the whole
/// payload encoding (see `docs/ARTIFACT_FORMAT.md`).
pub const ARTIFACT_FORMAT_VERSION: u16 = 1;
/// Header length: magic (8) + version u16 LE (2) + payload length u64 LE (8).
pub const ARTIFACT_HEADER_LEN: usize = 18;

/// Checks the fixed 18-byte header of an `.artifact` file and returns the payload.
///
/// Everything here is constant-time and allocation-free: the declared payload length
/// is only compared with the number of bytes actually present, never used to size a
/// buffer. Order: empty input; magic (a strict prefix of the magic is a truncated
/// file, anything else is not an artifact, including a pre-format-1 raw artifact);
/// complete header; format version (before anything else in the header is trusted);
/// declared length against the bytes present, both too few and too many.
pub fn split_artifact_header(bytes: &[u8]) -> Result<&[u8], LaniakeaError> {
    let load = |msg: String| Err(LaniakeaError::ArtifactLoad(msg));
    if bytes.is_empty() {
        return load("proving artifact input is empty".into());
    }
    let seen = bytes.len().min(ARTIFACT_MAGIC.len());
    if bytes[..seen] != ARTIFACT_MAGIC[..seen] {
        return load(
            "not a Laniakea proving artifact: the file lacks the Laniakea artifact header. \
             Artifacts made before format 1 are raw data and are no longer read; re-export \
             the artifact from its .zkey with the updated export_artifact \
             (cargo run -p laniakea-cli --bin export_artifact -- <circuit.zkey> <out.artifact>)"
                .into(),
        );
    }
    if bytes.len() < ARTIFACT_HEADER_LEN {
        return load(format!(
            "truncated proving artifact: {} bytes, but the header alone is {ARTIFACT_HEADER_LEN}",
            bytes.len()
        ));
    }
    let version = u16::from_le_bytes([bytes[8], bytes[9]]);
    if version != ARTIFACT_FORMAT_VERSION {
        return Err(LaniakeaError::UnsupportedArtifactVersion {
            found: version,
            supported: ARTIFACT_FORMAT_VERSION,
        });
    }
    let mut len = [0u8; 8];
    len.copy_from_slice(&bytes[10..ARTIFACT_HEADER_LEN]);
    let declared = u64::from_le_bytes(len);
    let payload = &bytes[ARTIFACT_HEADER_LEN..];
    let actual = payload.len() as u64;
    if declared > actual {
        return load(format!(
            "truncated proving artifact: the header declares a {declared}-byte payload but only {actual} byte(s) follow it"
        ));
    }
    if declared < actual {
        return load(format!(
            "{} unexpected trailing byte(s) after the declared {declared}-byte payload",
            actual - declared
        ));
    }
    Ok(payload)
}

/// A wrapper around `ConstraintMatrices<Fr>` that implements
/// `CanonicalSerialize` and `CanonicalDeserialize`.
///
/// The inner `ConstraintMatrices` from ark-relations does not implement
/// these traits by default, so we provide a thin wrapper that does.
#[derive(Clone, Debug, PartialEq, CanonicalSerialize, CanonicalDeserialize)]
pub struct SerializableConstraintMatrices {
    pub num_instance_variables: usize,
    pub num_witness_variables: usize,
    pub num_constraints: usize,
    pub a_num_non_zero: usize,
    pub b_num_non_zero: usize,
    pub c_num_non_zero: usize,
    pub a: Vec<Vec<(Fr, usize)>>,
    pub b: Vec<Vec<(Fr, usize)>>,
    pub c: Vec<Vec<(Fr, usize)>>,
}

impl From<ConstraintMatrices<Fr>> for SerializableConstraintMatrices {
    fn from(matrices: ConstraintMatrices<Fr>) -> Self {
        Self {
            num_instance_variables: matrices.num_instance_variables,
            num_witness_variables: matrices.num_witness_variables,
            num_constraints: matrices.num_constraints,
            a_num_non_zero: matrices.a_num_non_zero,
            b_num_non_zero: matrices.b_num_non_zero,
            c_num_non_zero: matrices.c_num_non_zero,
            a: matrices.a,
            b: matrices.b,
            c: matrices.c,
        }
    }
}

impl From<SerializableConstraintMatrices> for ConstraintMatrices<Fr> {
    fn from(wrapper: SerializableConstraintMatrices) -> Self {
        Self {
            num_instance_variables: wrapper.num_instance_variables,
            num_witness_variables: wrapper.num_witness_variables,
            num_constraints: wrapper.num_constraints,
            a_num_non_zero: wrapper.a_num_non_zero,
            b_num_non_zero: wrapper.b_num_non_zero,
            c_num_non_zero: wrapper.c_num_non_zero,
            a: wrapper.a,
            b: wrapper.b,
            c: wrapper.c,
        }
    }
}

/// Preprocessed proving artifact containing everything needed for
/// Groth16 proving after `.zkey` parsing.
///
/// This artifact is created at build time on desktop (where ark-circom/Wasmer
/// are available) and then serialized for use on iOS (where only pure-Rust
/// crates are available).
#[derive(Clone, Debug, PartialEq, CanonicalSerialize, CanonicalDeserialize)]
pub struct ProvingArtifact {
    /// The Groth16 proving key extracted from the zkey.
    pub proving_key: ProvingKey<ark_bn254::Bn254>,
    /// The R1CS constraint matrices extracted from the zkey.
    pub matrices: SerializableConstraintMatrices,
}

impl ProvingArtifact {
    /// Create a new proving artifact from the raw components.
    pub fn new(
        proving_key: ProvingKey<ark_bn254::Bn254>,
        matrices: ConstraintMatrices<Fr>,
    ) -> Self {
        Self {
            proving_key,
            matrices: matrices.into(),
        }
    }

    /// Get the number of public inputs (including the implicit "1").
    pub fn num_public_inputs(&self) -> usize {
        self.matrices.num_instance_variables
    }

    /// Get the number of constraints.
    pub fn num_constraints(&self) -> usize {
        self.matrices.num_constraints
    }

    /// Serialize to the `.artifact` file format (see [`ARTIFACT_MAGIC`] and
    /// `docs/ARTIFACT_FORMAT.md`): an 18-byte header followed by the Arkworks
    /// canonical uncompressed serialization of `self`, byte for byte.
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut payload = Vec::new();
        self.serialize_uncompressed(&mut payload)
            .expect("serialization should not fail");
        let len = u64::try_from(payload.len()).expect("payload length fits in u64");
        let mut bytes = Vec::with_capacity(ARTIFACT_HEADER_LEN + payload.len());
        bytes.extend_from_slice(&ARTIFACT_MAGIC);
        bytes.extend_from_slice(&ARTIFACT_FORMAT_VERSION.to_le_bytes());
        bytes.extend_from_slice(&len.to_le_bytes());
        bytes.extend_from_slice(&payload);
        bytes
    }

    /// Read an `.artifact` file and check the result is structurally consistent.
    ///
    /// Order: the header is checked first ([`split_artifact_header`]: magic,
    /// version, declared payload length against the bytes present), all in constant
    /// time, so a wrong, unsupported or truncated file never reaches Arkworks. Then
    /// the payload is deserialized (Arkworks also checks that every curve point is
    /// on the curve and in the correct subgroup) and finally [`Self::validate`] runs.
    ///
    /// Fails with [`LaniakeaError::UnsupportedArtifactVersion`] for another format
    /// version, with [`LaniakeaError::ArtifactLoad`] for empty input, a missing or
    /// incomplete header (a pre-format-1 raw artifact lands here, with a re-export
    /// hint), a payload shorter or longer than declared, or a malformed payload,
    /// and with [`LaniakeaError::InvalidArtifact`] if it parses but `validate`
    /// rejects it.
    ///
    /// None of this proves the keys are *correct* for any circuit, and the format
    /// has no integrity check; see [`Self::validate`].
    pub fn from_bytes(bytes: &[u8]) -> Result<Self, LaniakeaError> {
        let payload = split_artifact_header(bytes)?;
        let mut reader = payload;
        let artifact = Self::deserialize_uncompressed(&mut reader).map_err(|e| {
            LaniakeaError::ArtifactLoad(format!(
                "malformed proving artifact payload ({} bytes): {e}",
                payload.len()
            ))
        })?;
        if !reader.is_empty() {
            return Err(LaniakeaError::ArtifactLoad(format!(
                "malformed proving artifact payload: {} unused byte(s) inside the declared payload length",
                reader.len()
            )));
        }
        artifact.validate()?;
        Ok(artifact)
    }

    /// Number of entries a witness for this artifact must have: the number of
    /// circuit wires, constant `1` included. This is `a_query.len()`.
    pub fn witness_len(&self) -> usize {
        self.proving_key.a_query.len()
    }

    /// Check that the proving key and constraint matrices agree with each other
    /// and that the proving algorithm can index into them without going out of
    /// bounds or allocating from an inflated size.
    ///
    /// **This is structural validation only.** It cannot tell whether the
    /// group elements form a valid trusted setup, whether the matrices describe
    /// the intended circuit, or whether the artifact matches a given WASM or
    /// verifying key: the artifact carries no circuit identity to check.
    /// Corruption that keeps the structure intact (for example a changed matrix
    /// coefficient) is not detected.
    ///
    /// Let `n_inst = num_instance_variables` (constant `1` plus public signals)
    /// and `n_wires = a_query.len()`. The rules, all derived from how
    /// ark-groth16 and ark-circom's zkey reader build these structures, are:
    ///
    /// * `n_inst >= 1` and `n_wires >= n_inst`;
    /// * `b_g1_query.len() == b_g2_query.len() == n_wires`;
    /// * `l_query.len() == n_wires - n_inst` (it covers auxiliary wires only);
    /// * `vk.gamma_abc_g1.len() == n_inst` (one IC point per instance variable);
    /// * `a.len() == b.len() == num_constraints`. This also bounds
    ///   `num_constraints` by the data actually present, so a forged value
    ///   cannot make the reduction allocate a huge domain;
    /// * `c` is empty (Circom artifacts carry no C matrix; the reduction derives
    ///   `C = A·B`) or has `num_constraints` rows;
    /// * the `*_num_non_zero` counters equal the matrix entry counts;
    /// * every signal index in A, B and C is `< n_wires`;
    /// * `h_query.len()` equals the size of the evaluation domain the reduction
    ///   uses for `num_constraints + n_inst`. Equality, not a lower bound: the
    ///   reduction returns one `h` value per domain point and the prover pairs
    ///   them index-by-index with `h_query`, which the setup built for its own
    ///   domain. If the two sizes differ the pairing is wrong and the proof is
    ///   invalid, and the multi-scalar multiplication silently truncates
    ///   instead of failing. snarkjs sizes that domain from the same
    ///   `nConstraints + nPublic + 1` the reduction uses (public-input
    ///   constraints always occupy the indices after the real constraints, so
    ///   ark-circom's derived `num_constraints` is exact), so every genuine zkey
    ///   satisfies equality.
    ///
    /// `num_witness_variables` is not checked: ark-circom's zkey reader reports
    /// it as `n_vars - n_public`, one more than the number of auxiliary wires,
    /// and the prover never reads it.
    pub fn validate(&self) -> Result<(), LaniakeaError> {
        let bad = |msg: String| Err(LaniakeaError::InvalidArtifact(msg));
        let pk = &self.proving_key;
        let m = &self.matrices;

        let n_inst = m.num_instance_variables;
        let n_wires = pk.a_query.len();

        if n_inst == 0 {
            return bad(
                "num_instance_variables is 0 (the constant 1 is always an instance variable)"
                    .into(),
            );
        }
        if n_wires < n_inst {
            return bad(format!(
                "a_query has {n_wires} entries, fewer than the {n_inst} instance variables"
            ));
        }
        for (name, len) in [
            ("b_g1_query", pk.b_g1_query.len()),
            ("b_g2_query", pk.b_g2_query.len()),
        ] {
            if len != n_wires {
                return bad(format!(
                    "{name} has {len} entries but a_query has {n_wires} (one per wire)"
                ));
            }
        }
        if pk.l_query.len() != n_wires - n_inst {
            return bad(format!(
                "l_query has {} entries, expected {} (= {n_wires} wires - {n_inst} instance variables)",
                pk.l_query.len(),
                n_wires - n_inst
            ));
        }
        if pk.vk.gamma_abc_g1.len() != n_inst {
            return bad(format!(
                "verifying key has {} IC points, expected {n_inst} (one per instance variable)",
                pk.vk.gamma_abc_g1.len()
            ));
        }

        if m.a.len() != m.num_constraints || m.b.len() != m.num_constraints {
            return bad(format!(
                "num_constraints is {} but matrix A has {} rows and B has {}",
                m.num_constraints,
                m.a.len(),
                m.b.len()
            ));
        }
        if !m.c.is_empty() && m.c.len() != m.num_constraints {
            return bad(format!(
                "matrix C has {} rows; expected 0 (Circom) or {}",
                m.c.len(),
                m.num_constraints
            ));
        }
        for (name, rows, declared) in [
            ("A", &m.a, m.a_num_non_zero),
            ("B", &m.b, m.b_num_non_zero),
            ("C", &m.c, m.c_num_non_zero),
        ] {
            let mut count = 0usize;
            for (row, terms) in rows.iter().enumerate() {
                count += terms.len();
                if let Some((_, idx)) = terms.iter().find(|(_, idx)| *idx >= n_wires) {
                    return bad(format!(
                        "matrix {name} row {row} references signal {idx}, but the circuit has only {n_wires} wires"
                    ));
                }
            }
            if count != declared {
                return bad(format!(
                    "matrix {name} declares {declared} non-zero entries but contains {count}"
                ));
            }
        }

        let domain_size = m
            .num_constraints
            .checked_add(n_inst)
            .and_then(GeneralEvaluationDomain::<Fr>::compute_size_of_domain);
        match domain_size {
            None => {
                return bad(format!(
                    "no evaluation domain exists for {} constraints + {n_inst} instance variables",
                    m.num_constraints
                ))
            }
            Some(size) if pk.h_query.len() != size => {
                return bad(format!(
                    "h_query has {} entries but the reduction's evaluation domain has {size}",
                    pk.h_query.len()
                ))
            }
            Some(_) => {}
        }

        Ok(())
    }

    /// Check that `witness` has the shape this artifact expects, before any
    /// proving work: exactly [`Self::witness_len`] entries, and `witness[0] == 1`
    /// (the constant wire; the reduction reads it, so anything else would give
    /// a wrong proof).
    ///
    /// The Groth16 prover cannot be relied on for this: its multi-scalar
    /// multiplication silently truncates to the shorter of bases and scalars,
    /// so a too-long witness would be ignored in part and a too-short one can
    /// panic or yield an invalid proof.
    ///
    /// This does not check that the witness *satisfies* the constraints.
    pub fn validate_witness(&self, witness: &[Fr]) -> Result<(), LaniakeaError> {
        check_witness_shape(
            witness,
            self.witness_len(),
            self.matrices.num_instance_variables,
        )
    }
}

/// The witness checks of [`ProvingArtifact::validate_witness`], on plain
/// numbers so that [`crate::Prover`] can apply them without retaining a second
/// copy of the artifact. `expected_len` is the wire count; `n_inst` the number
/// of instance variables (for the error message).
pub(crate) fn check_witness_shape(
    witness: &[Fr],
    expected_len: usize,
    n_inst: usize,
) -> Result<(), LaniakeaError> {
    if witness.len() != expected_len {
        return Err(LaniakeaError::InvalidWitness(format!(
            "witness has {} entries but this proving artifact expects {expected_len} \
             (one per circuit wire, constant 1 included: {n_inst} instance + {} auxiliary)",
            witness.len(),
            expected_len.saturating_sub(n_inst)
        )));
    }
    // `first()`, not indexing: this must not panic even for an artifact that
    // was never validated and has no wires.
    if witness.first() != Some(&Fr::one()) {
        return Err(LaniakeaError::InvalidWitness(
            "witness[0] must be the constant 1".into(),
        ));
    }
    Ok(())
}

/// Desktop-only: convert a `.zkey` file into a `ProvingArtifact`.
#[cfg(not(target_os = "ios"))]
pub fn parse_zkey_to_artifact(zkey_bytes: &[u8]) -> Result<ProvingArtifact, String> {
    use ark_circom::read_zkey;
    use ark_std::io::Cursor;

    let (proving_key, matrices) = read_zkey(&mut Cursor::new(zkey_bytes))
        .map_err(|e| format!("failed to parse zkey: {}", e))?;

    let artifact = ProvingArtifact::new(proving_key, matrices);
    artifact
        .validate()
        .map_err(|e| format!("zkey produced an inconsistent artifact: {e}"))?;
    Ok(artifact)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn test_artifact_roundtrip() {
        // Load the age_check zkey
        let zkey_bytes =
            fs::read("../../circuits/age_check/age_check_final.zkey").expect("failed to read zkey");

        // Parse to artifact
        let artifact = parse_zkey_to_artifact(&zkey_bytes).expect("failed to parse zkey");

        // Verify key fields
        assert_eq!(artifact.num_public_inputs(), 3); // 1 (constant) + 2 (age, threshold)
        assert!(artifact.num_constraints() > 0);

        // Serialize
        let bytes = artifact.to_bytes();
        assert!(!bytes.is_empty());

        // Deserialize
        let artifact2 = ProvingArtifact::from_bytes(&bytes).expect("failed to deserialize");

        // Verify roundtrip
        assert_eq!(artifact, artifact2);
        assert_eq!(artifact.proving_key, artifact2.proving_key);
        assert_eq!(artifact.matrices, artifact2.matrices);
    }
}
