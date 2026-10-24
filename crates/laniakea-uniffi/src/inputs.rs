//! Strict decimal parsing for circuit input values crossing the FFI boundary.
//!
//! Swift has no big-integer type, so values arrive as decimal strings. The core
//! accepts any `BigInt` and reduces it modulo the BN254 scalar field `r`, which
//! would make `r + 25` and `25` the same input. At this boundary that is
//! refused: one value has exactly one accepted spelling.

use ark_bn254::Fr;
use ark_ff::PrimeField;
use num_bigint::{BigInt, BigUint};
use std::str::FromStr;

/// The BN254 scalar field modulus `r` (not the base field modulus `q`).
fn modulus() -> BigUint {
    BigUint::from(Fr::MODULUS)
}

/// Parse a canonical non-negative decimal strictly below `r`.
///
/// Accepts `"0"` and digit strings without leading zeros. Rejects the empty
/// string, signs, whitespace, any non-ASCII-digit character, and values `>= r`.
pub(crate) fn parse_field_decimal(s: &str) -> Option<BigInt> {
    // r has 77 decimal digits; anything longer is out of range, and checking
    // the length first bounds the work done on hostile input.
    if s.is_empty() || s.len() > 77 || !s.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    if s.len() > 1 && s.starts_with('0') {
        return None;
    }
    let v = BigUint::from_str(s).ok()?;
    (v < modulus()).then(|| BigInt::from(v))
}

/// At most 32 characters of `s`, for error messages. Truncates on character
/// boundaries (the input may be arbitrary Unicode) and marks the cut.
pub(crate) fn truncate_for_diagnostic(s: &str) -> String {
    const MAX: usize = 32;
    let mut it = s.chars();
    let head: String = it.by_ref().take(MAX).collect();
    if it.next().is_some() {
        format!("{head}…")
    } else {
        head
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const R: &str = "21888242871839275222246405745257275088548364400416034343698204186575808495617";
    const R_MINUS_1: &str =
        "21888242871839275222246405745257275088548364400416034343698204186575808495616";
    // The base field modulus q: a different, larger number.
    const Q: &str = "21888242871839275222246405745257275088696311157297823662689037894645226208583";

    #[test]
    fn modulus_is_the_bn254_scalar_modulus() {
        assert_eq!(modulus().to_string(), R);
        assert_ne!(R, Q);
    }

    #[test]
    fn accepts_canonical_values() {
        for s in ["0", "1", "18", "25", "255", "1000000007", R_MINUS_1] {
            assert_eq!(
                parse_field_decimal(s).map(|v| v.to_string()).as_deref(),
                Some(s),
                "{s}"
            );
        }
    }

    #[test]
    fn rejects_values_at_or_above_the_scalar_modulus() {
        // r itself, r + 1, r + 25 (would reduce to 25), q (valid below q only
        // for the base field), and very long digit strings.
        let r_plus_25 =
            "21888242871839275222246405745257275088548364400416034343698204186575808495642";
        for s in [
            R,
            r_plus_25,
            Q,
            &"9".repeat(77),
            &"9".repeat(78),
            &"1".repeat(5000),
        ] {
            assert_eq!(parse_field_decimal(s), None, "{s}");
        }
    }

    #[test]
    fn rejects_non_canonical_spellings() {
        for s in [
            "", "-1", "-0", "+1", "+0", "00", "01", "007", " 1", "1 ", "1 2", "\t1", "1\n",
            "1_000", "0x10", "1e3", "1.0", "1.", ".5", "abc", "１２", "٣", "²", "1,000", "NaN",
        ] {
            assert_eq!(parse_field_decimal(s), None, "{s:?}");
        }
    }

    #[test]
    fn truncation_is_bounded_and_unicode_safe() {
        assert_eq!(truncate_for_diagnostic("abc"), "abc");
        assert_eq!(truncate_for_diagnostic(&"x".repeat(32)), "x".repeat(32));
        assert_eq!(
            truncate_for_diagnostic(&"x".repeat(33)),
            format!("{}…", "x".repeat(32))
        );
        // Multi-byte characters must not be split.
        let wide = "é".repeat(100);
        let t = truncate_for_diagnostic(&wide);
        assert_eq!(t.chars().count(), 33);
        assert!(t.starts_with("éé") && t.ends_with('…'));
    }
}
