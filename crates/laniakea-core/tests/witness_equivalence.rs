use ark_bn254::Fr;
#[cfg(not(any(target_os = "ios", target_os = "macos")))]
use laniakea_core::witness_ark::ArkCircomWitness;
#[cfg(any(target_os = "ios", target_os = "macos"))]
use laniakea_core::witness_wasmi::WasmiWitnessAdapter;
use laniakea_core::{
    error::LaniakeaError,
    witness::{WitnessArtifacts, WitnessCalculator},
};
use num_bigint::BigInt;
use std::fs;

/// Expected witness for age_check circuit with age=25, threshold=18
/// Computed by both circom/witness_calculator.js and wasmi-witness
fn expected_witness() -> Vec<Fr> {
    vec![
        Fr::from(1u64),   // witness[0] = 1 (constant)
        Fr::from(1u64),   // witness[1] = 1
        Fr::from(18u64),  // witness[2] = threshold = 18
        Fr::from(25u64),  // witness[3] = age = 25
        Fr::from(26u64),  // witness[4] = 26
        Fr::from(0u64),   // witness[5] = 0
        Fr::from(0u64),   // witness[6] = 0
        Fr::from(0u64),   // witness[7] = 0
        Fr::from(1u64),   // witness[8] = 1
        Fr::from(1u64),   // witness[9] = 1
        Fr::from(1u64),   // witness[10] = 1
        Fr::from(1u64),   // witness[11] = 1
        Fr::from(1u64),   // witness[12] = 1
        Fr::from(0u64),   // witness[13] = 0
        Fr::from(248u64), // witness[14] = 248
    ]
}

#[test]
fn test_witness_equivalence_age_check() -> Result<(), LaniakeaError> {
    let wasm_bytes = fs::read("../../circuits/age_check/age_check_js/age_check.wasm")
        .expect("failed to read age_check.wasm");
    #[cfg(not(any(target_os = "ios", target_os = "macos")))]
    let r1cs_bytes =
        fs::read("../../circuits/age_check/age_check.r1cs").expect("failed to read age_check.r1cs");

    // Test inputs matching the age_check circuit
    let inputs = vec![
        ("age".to_string(), vec![BigInt::from(25u32)]),
        ("threshold".to_string(), vec![BigInt::from(18u32)]),
    ];

    let expected = expected_witness();

    // WasmiWitnessAdapter (iOS/macOS path)
    #[cfg(any(target_os = "ios", target_os = "macos"))]
    {
        let wasmi_artifacts = WitnessArtifacts {
            wasm_bytes: wasm_bytes.clone(),
            r1cs_bytes: None,
        };

        let mut wasmi_witness_calc = WasmiWitnessAdapter::new(wasmi_artifacts)?;
        let wasmi_witness = wasmi_witness_calc.calculate_witness(&inputs)?;

        // Compare Wasmi witness with expected values
        assert_eq!(
            wasmi_witness.len(),
            expected.len(),
            "wasmi witness length mismatch: got={}, expected={}",
            wasmi_witness.len(),
            expected.len()
        );

        for (i, (wasmi_val, exp_val)) in wasmi_witness.iter().zip(expected.iter()).enumerate() {
            assert_eq!(
                wasmi_val, exp_val,
                "wasmi witness[{}] mismatch: got={}, expected={}",
                i, wasmi_val, exp_val
            );
        }

        println!("Wasmi witness test PASSED");
        println!("Witness length: {}", wasmi_witness.len());
        for (i, v) in wasmi_witness.iter().enumerate() {
            println!("witness[{}] = {}", i, v);
        }
    }

    // ArkCircomWitness (desktop/Linux path)
    #[cfg(all(not(target_os = "ios"), not(target_os = "macos")))]
    {
        let ark_artifacts = WitnessArtifacts {
            wasm_bytes: wasm_bytes.clone(),
            r1cs_bytes: Some(r1cs_bytes.clone()),
        };

        let mut ark_witness_calc = ArkCircomWitness::new(ark_artifacts)?;
        let ark_witness = ark_witness_calc.calculate_witness(&inputs)?;

        // Compare ArkCircom witness with expected values
        assert_eq!(
            ark_witness.len(),
            expected.len(),
            "ark witness length mismatch: got={}, expected={}",
            ark_witness.len(),
            expected.len()
        );

        for (i, (ark_val, exp_val)) in ark_witness.iter().zip(expected.iter()).enumerate() {
            assert_eq!(
                ark_val, exp_val,
                "ark witness[{}] mismatch: got={}, expected={}",
                i, ark_val, exp_val
            );
        }

        println!("ArkCircom witness test PASSED");
        println!("Witness length: {}", ark_witness.len());
        for (i, v) in ark_witness.iter().enumerate() {
            println!("witness[{}] = {}", i, v);
        }
    }

    Ok(())
}
