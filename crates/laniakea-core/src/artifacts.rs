use ark_bn254::Fr;
use ark_groth16::ProvingKey;
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

    /// Deserialize from bytes using Arkworks canonical serialization.
    pub fn from_bytes(bytes: &[u8]) -> Result<Self, ark_serialize::SerializationError> {
        CanonicalDeserialize::deserialize_uncompressed(bytes)
    }
}

/// Desktop-only: convert a `.zkey` file into a `ProvingArtifact`.
#[cfg(not(target_os = "ios"))]
pub fn parse_zkey_to_artifact(zkey_bytes: &[u8]) -> Result<ProvingArtifact, String> {
    use ark_circom::read_zkey;
    use ark_std::io::Cursor;

    let (proving_key, matrices) = read_zkey(&mut Cursor::new(zkey_bytes))
        .map_err(|e| format!("failed to parse zkey: {}", e))?;

    Ok(ProvingArtifact::new(proving_key, matrices))
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
