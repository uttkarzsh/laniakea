//! Regression tests for the Wasmi witness calculator.
//!
//! `circuits/reference/reference_witnesses.json` holds the result of running
//! every case in `circuits/reference/cases.json` through Circom's own generated
//! JavaScript calculator (`node circuits/reference/gen_reference.js`). Each case
//! is either a witness (compared element for element) or an error (we must
//! also fail; message text is only compared where it carries meaning).

use ark_bn254::Fr;
use ark_ff::PrimeField;
use num_bigint::{BigInt, BigUint};
use serde_json::Value;
use std::fs;
use wasmi_witness::{WasmiWitnessCalculator, WasmiWitnessError};

const ROOT: &str = "../../circuits";

fn wasm_path(circuit: &str) -> String {
    format!("{ROOT}/{circuit}/{circuit}_js/{circuit}.wasm")
}

fn calculator(circuit: &str) -> WasmiWitnessCalculator {
    let wasm = fs::read(wasm_path(circuit)).expect("failed to read wasm");
    WasmiWitnessCalculator::new(&wasm).expect("failed to create calculator")
}

fn big(s: &str) -> BigInt {
    s.parse().expect("decimal integer")
}

fn fr(s: &str) -> Fr {
    let n: BigUint = s.parse().expect("decimal integer");
    Fr::from_le_bytes_mod_order(&n.to_bytes_le())
}

/// Flatten `{"v": ["1","2","3"], "a": "5"}` into the calculator's input shape.
fn to_inputs(json: &Value) -> Vec<(String, Vec<BigInt>)> {
    json.as_object()
        .expect("inputs object")
        .iter()
        .map(|(name, v)| {
            let values = match v {
                Value::Array(items) => items.iter().map(|x| big(x.as_str().unwrap())).collect(),
                Value::String(s) => vec![big(s)],
                other => panic!("unsupported input value {other}"),
            };
            (name.clone(), values)
        })
        .collect()
}

fn reference_cases() -> Vec<Value> {
    let text = fs::read_to_string(format!("{ROOT}/reference/reference_witnesses.json"))
        .expect("failed to read reference_witnesses.json");
    serde_json::from_str::<Vec<Value>>(&text).expect("valid reference json")
}

#[test]
fn matches_circom_js_calculator_on_every_reference_case() {
    let cases = reference_cases();
    assert!(cases.len() >= 30, "reference file looks truncated");

    let (mut ok, mut err) = (0, 0);
    for case in &cases {
        let circuit = case["circuit"].as_str().unwrap();
        let name = case["name"].as_str().unwrap();
        let calc = calculator(circuit);
        let result = calc.calculate_witness(&to_inputs(&case["inputs"]));

        if let Some(expected) = case.get("witness") {
            let expected: Vec<Fr> = expected
                .as_array()
                .unwrap()
                .iter()
                .map(|v| fr(v.as_str().unwrap()))
                .collect();
            let got = result.unwrap_or_else(|e| panic!("{circuit}/{name}: unexpected error: {e}"));
            assert_eq!(
                got, expected,
                "{circuit}/{name}: witness differs from Circom JS"
            );
            ok += 1;
        } else {
            let js_error = case["error"].as_str().unwrap();
            let e = result.err().unwrap_or_else(|| {
                panic!("{circuit}/{name}: expected failure ({js_error}) but got a witness")
            });
            // Circuit aborts must be reported as such, with the same code.
            if js_error.contains("Assert Failed") {
                match e {
                    WasmiWitnessError::Circom { code: 4, .. } => {}
                    other => panic!("{circuit}/{name}: expected assert failure, got {other}"),
                }
            }
            err += 1;
        }
    }
    // Guard against the loop silently skipping everything.
    assert!(ok >= 10 && err >= 15, "ok={ok}, err={err}");
}

#[test]
fn large_values_use_all_limbs() {
    // 2^200 + 12345 only survives if all eight 32-bit limbs are decoded.
    let calc = calculator("witness_probe");
    let a: BigInt = (BigInt::from(1u8) << 200usize) + 12345;
    let b: BigInt = (BigInt::from(1u8) << 130usize) + 7;
    let w = calc
        .calculate_witness(&[
            ("a".into(), vec![a.clone()]),
            ("b".into(), vec![b.clone()]),
            ("v".into(), vec![1.into(), 2.into(), 3.into()]),
            ("flag".into(), vec![1.into()]),
        ])
        .unwrap();
    // Witness layout: [1, prod, diff, sum, b, a, v0, v1, v2, flag]
    let to_fr = |n: &BigInt| fr(&n.to_string());
    assert_eq!(w[5], to_fr(&a));
    assert_eq!(w[4], to_fr(&b));
    assert_eq!(w[1], to_fr(&a) * to_fr(&b));
    assert_eq!(w[3], Fr::from(6u64));
}

#[test]
fn negative_inputs_wrap_modulo_p() {
    let calc = calculator("witness_probe");
    let w = calc
        .calculate_witness(&[
            ("a".into(), vec![BigInt::from(-5)]),
            ("b".into(), vec![BigInt::from(3)]),
            ("v".into(), vec![1.into(), 2.into(), 3.into()]),
            ("flag".into(), vec![1.into()]),
        ])
        .unwrap();
    assert_eq!(w[5], -Fr::from(5u64));
    assert_eq!(w[2], -Fr::from(8u64)); // diff = a - b
}

#[test]
fn age_check_negative_age_is_p_minus_one_not_zero() {
    // Regression for the audit finding: -1 used to be written as 0.
    let calc = calculator("age_check");
    let w = calc
        .calculate_witness(&[
            ("age".into(), vec![BigInt::from(-1)]),
            ("threshold".into(), vec![BigInt::from(18)]),
        ])
        .unwrap();
    assert_eq!(w[3], -Fr::from(1u64));
}

#[test]
fn witness_probe_values_above_u32_range_round_trip() {
    // Regression for the audit finding: 2^40 used to read back as 0. age_check
    // rejects such values (8-bit comparison), so this uses witness_probe.
    let calc = calculator("witness_probe");
    let big_value = BigInt::from(1u64 << 40);
    let w = calc
        .calculate_witness(&[
            ("a".into(), vec![big_value.clone()]),
            ("b".into(), vec![1.into()]),
            ("v".into(), vec![0.into(), 0.into(), 0.into()]),
            ("flag".into(), vec![0.into()]),
        ])
        .unwrap();
    assert_eq!(w[5], Fr::from(1u64 << 40));
}

#[test]
fn failed_assertion_is_an_error_not_a_witness() {
    // age = 300 does not fit the 8-bit comparison; the old code returned Ok
    // with output 0 and garbage intermediate wires.
    let calc = calculator("age_check");
    let err = calc
        .calculate_witness(&[
            ("age".into(), vec![BigInt::from(300)]),
            ("threshold".into(), vec![BigInt::from(18)]),
        ])
        .unwrap_err();
    match err {
        WasmiWitnessError::Circom {
            code,
            reason,
            detail,
        } => {
            assert_eq!(code, 4);
            assert_eq!(reason, "assert failed");
            assert!(detail.contains("Num2Bits"), "trace was: {detail}");
        }
        other => panic!("expected Circom error, got {other}"),
    }
}

#[test]
fn explicit_assert_statement_is_an_error() {
    let calc = calculator("witness_probe");
    let err = calc
        .calculate_witness(&[
            ("a".into(), vec![3.into()]),
            ("b".into(), vec![7.into()]), // assert(b != 7)
            ("v".into(), vec![1.into(), 2.into(), 3.into()]),
            ("flag".into(), vec![1.into()]),
        ])
        .unwrap_err();
    assert!(
        matches!(err, WasmiWitnessError::Circom { code: 4, .. }),
        "{err}"
    );
}

#[test]
fn zero_output_is_a_valid_witness() {
    // age < threshold is a legitimate execution: out = 0, no error.
    let calc = calculator("age_check");
    let w = calc
        .calculate_witness(&[
            ("age".into(), vec![10.into()]),
            ("threshold".into(), vec![18.into()]),
        ])
        .unwrap();
    assert_eq!(w[1], Fr::from(0u64));
}

#[test]
fn input_validation_errors_are_specific() {
    let calc = calculator("witness_probe");
    let good = |extra: Vec<(String, Vec<BigInt>)>| {
        let mut v = vec![
            ("a".to_string(), vec![BigInt::from(3)]),
            ("b".to_string(), vec![BigInt::from(5)]),
            ("v".to_string(), vec![1.into(), 2.into(), 3.into()]),
            ("flag".to_string(), vec![BigInt::from(1)]),
        ];
        v.extend(extra);
        v
    };

    let e = calc
        .calculate_witness(&good(vec![("nope".into(), vec![1.into()])]))
        .unwrap_err();
    assert!(
        matches!(e, WasmiWitnessError::UnknownSignal(ref n) if n == "nope"),
        "{e}"
    );

    // Output signals are not inputs either.
    let e = calc
        .calculate_witness(&good(vec![("prod".into(), vec![15.into()])]))
        .unwrap_err();
    assert!(matches!(e, WasmiWitnessError::UnknownSignal(_)), "{e}");

    let e = calc
        .calculate_witness(&good(vec![("a".into(), vec![9.into()])]))
        .unwrap_err();
    assert!(
        matches!(e, WasmiWitnessError::DuplicateSignal(ref n) if n == "a"),
        "{e}"
    );

    let mut short = good(vec![]);
    short[2].1.pop();
    let e = calc.calculate_witness(&short).unwrap_err();
    assert!(
        matches!(e, WasmiWitnessError::InputSize { ref signal, expected: 3, got: 2 } if signal == "v"),
        "{e}"
    );

    let mut long = good(vec![]);
    long[2].1.push(4.into());
    let e = calc.calculate_witness(&long).unwrap_err();
    assert!(
        matches!(
            e,
            WasmiWitnessError::InputSize {
                expected: 3,
                got: 4,
                ..
            }
        ),
        "{e}"
    );

    let mut missing = good(vec![]);
    missing.pop(); // flag
    let e = calc.calculate_witness(&missing).unwrap_err();
    assert!(
        matches!(
            e,
            WasmiWitnessError::MissingInputs {
                set: 5,
                expected: 6
            }
        ),
        "{e}"
    );

    let e = calc.calculate_witness(&[]).unwrap_err();
    assert!(
        matches!(
            e,
            WasmiWitnessError::MissingInputs {
                set: 0,
                expected: 6
            }
        ),
        "{e}"
    );
}

#[test]
fn calculator_is_reusable_after_a_failure() {
    let calc = calculator("age_check");
    let ok = |c: &WasmiWitnessCalculator| {
        c.calculate_witness(&[
            ("age".into(), vec![25.into()]),
            ("threshold".into(), vec![18.into()]),
        ])
    };
    let first = ok(&calc).unwrap();
    // A trap in the middle of execution...
    assert!(calc
        .calculate_witness(&[
            ("age".into(), vec![300.into()]),
            ("threshold".into(), vec![18.into()]),
        ])
        .is_err());
    // ...and a validation failure must not poison later runs.
    assert!(calc.calculate_witness(&[]).is_err());
    assert_eq!(ok(&calc).unwrap(), first);
}

#[test]
fn calculator_recovers_after_partial_input_failures() {
    // Failures that stop part-way through assigning inputs (some values already
    // written to the module) must not affect the next call.
    let calc = calculator("witness_probe");
    let inputs = |a: i64, v: &[i64], flag: Option<i64>| {
        let mut i: Vec<(String, Vec<BigInt>)> = vec![
            ("a".into(), vec![a.into()]),
            ("b".into(), vec![5.into()]),
            ("v".into(), v.iter().map(|x| BigInt::from(*x)).collect()),
        ];
        if let Some(f) = flag {
            i.push(("flag".into(), vec![f.into()]));
        }
        i
    };
    let good = inputs(3, &[1, 2, 3], Some(1));
    let baseline = calc.calculate_witness(&good).unwrap();

    // a and b are assigned, then `v` has the wrong length.
    assert!(matches!(
        calc.calculate_witness(&inputs(9, &[1, 2], Some(1))),
        Err(WasmiWitnessError::InputSize { .. })
    ));
    assert_eq!(calc.calculate_witness(&good).unwrap(), baseline);

    // Everything but `flag` is assigned.
    assert!(matches!(
        calc.calculate_witness(&inputs(9, &[1, 2, 3], None)),
        Err(WasmiWitnessError::MissingInputs {
            set: 5,
            expected: 6
        })
    ));
    assert_eq!(calc.calculate_witness(&good).unwrap(), baseline);

    // Every input assigned, circuit then aborts mid-run (flag must be 0 or 1).
    assert!(matches!(
        calc.calculate_witness(&inputs(9, &[1, 2, 3], Some(2))),
        Err(WasmiWitnessError::Circom { code: 4, .. })
    ));
    assert_eq!(calc.calculate_witness(&good).unwrap(), baseline);
}

#[test]
fn rejects_malformed_wasm() {
    assert!(matches!(
        WasmiWitnessCalculator::new(b"not wasm"),
        Err(WasmiWitnessError::Module(_))
    ));
}

#[test]
fn sizes_are_exposed() {
    let calc = calculator("witness_probe");
    assert_eq!(calc.input_size(), 6); // a, b, v[3], flag
    assert_eq!(calc.witness_size(), 10);
    let calc = calculator("age_check");
    assert_eq!(calc.input_size(), 2);
    assert_eq!(calc.witness_size(), 15);
}
