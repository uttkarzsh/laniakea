use crate::error::LaniakeaError;
use ark_bn254::Fr;
use ark_ff::One;
use ark_groth16::ProvingKey;
use ark_poly::{EvaluationDomain, GeneralEvaluationDomain};
use ark_relations::r1cs::ConstraintMatrices;
use ark_serialize::{CanonicalDeserialize, CanonicalSerialize};
use ark_std::vec::Vec;

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

    /// Serialize to bytes using Arkworks canonical serialization.
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut bytes = Vec::new();
        self.serialize_uncompressed(&mut bytes)
            .expect("serialization should not fail");
        bytes
    }

    /// Deserialize from bytes and check the result is structurally consistent.
    ///
    /// Fails with [`LaniakeaError::ArtifactLoad`] if the input is empty,
    /// truncated or malformed (Arkworks also checks that every curve point is
    /// on the curve and in the correct subgroup), or has bytes left over after
    /// the artifact. Fails with [`LaniakeaError::InvalidArtifact`] if it parses
    /// but [`Self::validate`] rejects it.
    ///
    /// Neither check proves the keys are *correct* for any circuit; see
    /// [`Self::validate`].
    pub fn from_bytes(bytes: &[u8]) -> Result<Self, LaniakeaError> {
        if bytes.is_empty() {
            return Err(LaniakeaError::ArtifactLoad(
                "proving artifact input is empty".into(),
            ));
        }
        let mut reader = bytes;
        let artifact = Self::deserialize_uncompressed(&mut reader).map_err(|e| {
            LaniakeaError::ArtifactLoad(format!(
                "could not deserialize proving artifact ({} bytes): {e}",
                bytes.len()
            ))
        })?;
        if !reader.is_empty() {
            return Err(LaniakeaError::ArtifactLoad(format!(
                "{} unexpected trailing byte(s) after the proving artifact",
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
