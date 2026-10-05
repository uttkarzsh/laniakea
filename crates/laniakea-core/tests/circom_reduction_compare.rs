//! Comparison test between vendor ark-circom CircomReduction and Laniakea portable CircomReduction.

use ark_bn254::Fr;
use ark_circom::circom::CircomReduction as VendorCircomReduction;
use ark_groth16::r1cs_to_qap::R1CSToQAP;
use ark_poly::GeneralEvaluationDomain;
use std::fs;

use laniakea_core::artifacts::parse_zkey_to_artifact;
use laniakea_core::backend::circom_reduction::CircomReduction;

type Domain = GeneralEvaluationDomain<Fr>;

#[test]
fn test_circom_reduction_matches_vendor() {
    // Load the age_check zkey and extract matrices
    let zkey_bytes =
        fs::read("../../circuits/age_check/age_check_final.zkey").expect("failed to read zkey");
    let artifact = parse_zkey_to_artifact(&zkey_bytes).expect("failed to parse zkey");

    let num_inputs = artifact.num_public_inputs();
    let num_constraints = artifact.num_constraints();
    let matrices = ark_relations::r1cs::ConstraintMatrices::from(artifact.matrices);

    // Known witness for age=25, threshold=18
    // witness[0] = 1, witness[1] = 1, witness[2] = 18, witness[3] = 25, ...
    let full_witness = vec![
        Fr::from(1u64),
        Fr::from(1u64),
        Fr::from(18u64),
        Fr::from(25u64),
        Fr::from(26u64),
        Fr::from(0u64),
        Fr::from(0u64),
        Fr::from(0u64),
        Fr::from(1u64),
        Fr::from(1u64),
        Fr::from(1u64),
        Fr::from(1u64),
        Fr::from(1u64),
        Fr::from(0u64),
        Fr::from(248u64),
    ];

    // Run vendor CircomReduction
    let vendor_result = VendorCircomReduction::witness_map_from_matrices::<Fr, Domain>(
        &matrices,
        num_inputs,
        num_constraints,
        &full_witness,
    )
    .expect("vendor reduction failed");

    // Run Laniakea portable CircomReduction
    let laniakea_result = CircomReduction::witness_map_from_matrices::<Fr, Domain>(
        &matrices,
        num_inputs,
        num_constraints,
        &full_witness,
    )
    .expect("laniakea reduction failed");

    // Compare results
    assert_eq!(
        vendor_result.len(),
        laniakea_result.len(),
        "result length mismatch: vendor={}, laniakea={}",
        vendor_result.len(),
        laniakea_result.len()
    );

    for (i, (v, l)) in vendor_result.iter().zip(laniakea_result.iter()).enumerate() {
        assert_eq!(
            v, l,
            "coefficient[{}] mismatch: vendor={}, laniakea={}",
            i, v, l
        );
    }

    println!("CircomReduction comparison test PASSED");
    println!("Result length: {}", vendor_result.len());
    for (i, v) in vendor_result.iter().enumerate() {
        println!("h[{}] = {}", i, v);
    }
}
