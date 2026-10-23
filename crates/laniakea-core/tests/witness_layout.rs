//! Evidence for how the Circom WASM witness relates to the R1CS and the
//! zkey-derived `ProvingArtifact`. This pins down facts later phases rely on
//! (witness-length validation, public-input extraction); it is not a prover test.
//!
//! Findings, for circuit with R1CS header `n_wires`, `n_pub_out`, `n_pub_in`:
//!
//! * WASM `getWitnessSize()` == `n_wires` (constant `1` included).
//! * Witness order is `[1, pub outputs, pub inputs, private inputs, intermediates]`,
//!   so the Groth16 public inputs are `witness[1..1 + n_pub_out + n_pub_in]`.
//! * ark-circom's `read_zkey` reports `num_witness_variables = n_vars - n_public`,
//!   one more than the number of non-instance wires (`n_vars - n_public - 1`).
//!   Hence `num_instance_variables + num_witness_variables == n_wires + 1`.
//!   The reliable check is on the proving key: `a_query.len() == n_wires` and
//!   `num_instance_variables + l_query.len() == n_wires`.
#![cfg(target_os = "macos")]

use ark_bn254::{Bn254, Fr};
use ark_circom::circom::R1CSFile;
use laniakea_core::artifacts::parse_zkey_to_artifact;
use std::fs;
use std::io::Cursor;
use wasmi_witness::WasmiWitnessCalculator;

const ROOT: &str = "../../circuits";

fn wasm_witness_size(circuit: &str) -> usize {
    let wasm = fs::read(format!("{ROOT}/{circuit}/{circuit}_js/{circuit}.wasm")).unwrap();
    WasmiWitnessCalculator::new(&wasm).unwrap().witness_size()
}

fn r1cs_header(circuit: &str) -> (usize, usize, usize) {
    let bytes = fs::read(format!("{ROOT}/{circuit}/{circuit}.r1cs")).unwrap();
    let file = R1CSFile::<Bn254>::new(Cursor::new(bytes)).unwrap();
    (
        file.header.n_wires as usize,
        file.header.n_pub_out as usize,
        file.header.n_pub_in as usize,
    )
}

#[test]
fn wasm_witness_size_equals_r1cs_wire_count() {
    for circuit in ["age_check", "witness_probe"] {
        let (n_wires, _, _) = r1cs_header(circuit);
        assert_eq!(wasm_witness_size(circuit), n_wires, "{circuit}");
    }
}

#[test]
fn zkey_dimensions_relate_to_wire_count_as_documented() {
    let zkey = fs::read(format!("{ROOT}/age_check/age_check_final.zkey")).unwrap();
    let artifact = parse_zkey_to_artifact(&zkey).unwrap();
    let (n_wires, n_pub_out, n_pub_in) = r1cs_header("age_check");
    let pk = &artifact.proving_key;
    let m = &artifact.matrices;

    assert_eq!(n_wires, 15);
    assert_eq!(m.num_instance_variables, 1 + n_pub_out + n_pub_in);

    // ark-circom's off-by-one in num_witness_variables (see module docs).
    assert_eq!(m.num_witness_variables, n_wires - (n_pub_out + n_pub_in));
    assert_eq!(
        m.num_instance_variables + m.num_witness_variables,
        n_wires + 1
    );

    // Properties of the proving key that match the real wire count.
    assert_eq!(pk.a_query.len(), n_wires);
    assert_eq!(pk.b_g1_query.len(), n_wires);
    assert_eq!(pk.l_query.len(), n_wires - m.num_instance_variables);
    assert_eq!(
        m.num_instance_variables + pk.l_query.len(),
        wasm_witness_size("age_check")
    );
}

#[test]
fn public_inputs_are_outputs_then_public_inputs() {
    let inputs = |pairs: &[(&str, &[u64])]| -> Vec<(String, Vec<num_bigint::BigInt>)> {
        pairs
            .iter()
            .map(|(n, v)| (n.to_string(), v.iter().map(|x| (*x).into()).collect()))
            .collect()
    };

    // age_check: out (public output) then threshold (public input).
    let wasm = fs::read(format!("{ROOT}/age_check/age_check_js/age_check.wasm")).unwrap();
    let mut calc = WasmiWitnessCalculator::new(&wasm).unwrap();
    let w = calc
        .calculate_witness(&inputs(&[("age", &[25]), ("threshold", &[18])]))
        .unwrap();
    let (_, out, pubin) = r1cs_header("age_check");
    assert_eq!((out, pubin), (1, 1));
    assert_eq!(&w[..3], &[Fr::from(1u64), Fr::from(1u64), Fr::from(18u64)]);
    assert_eq!(w[3], Fr::from(25u64)); // first private input follows

    // witness_probe: prod, diff, sum (outputs) then b (public input), then a (private).
    let wasm = fs::read(format!(
        "{ROOT}/witness_probe/witness_probe_js/witness_probe.wasm"
    ))
    .unwrap();
    let mut calc = WasmiWitnessCalculator::new(&wasm).unwrap();
    let w = calc
        .calculate_witness(&inputs(&[
            ("a", &[6]),
            ("b", &[4]),
            ("v", &[1, 2, 3]),
            ("flag", &[1]),
        ]))
        .unwrap();
    let (_, out, pubin) = r1cs_header("witness_probe");
    assert_eq!((out, pubin), (3, 1));
    assert_eq!(
        &w[1..5],
        &[
            Fr::from(24u64),
            Fr::from(2u64),
            Fr::from(6u64),
            Fr::from(4u64)
        ]
    );
    assert_eq!(w[5], Fr::from(6u64)); // a, the first private input
}
