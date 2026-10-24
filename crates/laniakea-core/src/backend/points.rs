//! Decoding of curve points from JSON coordinates, with validation.
//!
//! JSON gives us bare coordinates, so nothing guarantees they describe a point
//! of the right group. Arkworks' `new_unchecked` builds one anyway, and feeding
//! such a point to a pairing gives meaningless results (or worse). Every point
//! decoded from JSON therefore goes through here, which checks, in order:
//!
//! 1. each coordinate is a canonical decimal below the field modulus;
//! 2. the point satisfies the curve equation;
//! 3. the point lies in the prime-order subgroup.
//!
//! On BN254 G1 the cofactor is 1, so (3) cannot fail once (2) passes; it is
//! still performed so the check does not depend on that fact. G2 has a large
//! cofactor, so there (3) is a real check that on-curve points can fail.

use crate::error::{LaniakeaError, PointFault};
use ark_bn254::{Fq, Fq2, G1Affine, G2Affine};
use ark_ff::PrimeField;

/// Parse a canonical decimal: ASCII digits only, no sign or leading zeros, and
/// strictly below the field modulus. Arkworks' `from_str` alone would silently
/// reduce `p + 1` to `1`, giving one value many encodings.
pub(crate) fn canonical_field<F: PrimeField>(s: &str) -> Option<F> {
    if s.is_empty() || s.len() > 80 || !s.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let f = F::from_str(s).ok()?;
    (f.into_bigint().to_string() == s).then_some(f)
}

fn fq(s: &str, what: &str) -> Result<Fq, LaniakeaError> {
    canonical_field::<Fq>(s).ok_or_else(|| {
        LaniakeaError::Serialization(format!(
            "{what}: `{}` is not a canonical field element",
            s.chars().take(80).collect::<String>()
        ))
    })
}

pub(crate) fn g1_from_decimals(x: &str, y: &str, what: &str) -> Result<G1Affine, LaniakeaError> {
    let p = G1Affine::new_unchecked(fq(x, what)?, fq(y, what)?);
    if !p.is_on_curve() {
        return Err(fault(what, PointFault::NotOnCurve));
    }
    if !p.is_in_correct_subgroup_assuming_on_curve() {
        return Err(fault(what, PointFault::NotInSubgroup));
    }
    Ok(p)
}

/// `x` and `y` are `[c0, c1]` pairs, snarkjs order.
pub(crate) fn g2_from_decimals(
    x: [&str; 2],
    y: [&str; 2],
    what: &str,
) -> Result<G2Affine, LaniakeaError> {
    let x = Fq2::new(fq(x[0], what)?, fq(x[1], what)?);
    let y = Fq2::new(fq(y[0], what)?, fq(y[1], what)?);
    let p = G2Affine::new_unchecked(x, y);
    if !p.is_on_curve() {
        return Err(fault(what, PointFault::NotOnCurve));
    }
    if !p.is_in_correct_subgroup_assuming_on_curve() {
        return Err(fault(what, PointFault::NotInSubgroup));
    }
    Ok(p)
}

fn fault(what: &str, fault: PointFault) -> LaniakeaError {
    LaniakeaError::InvalidPoint {
        what: what.to_string(),
        fault,
    }
}

/// snarkjs writes affine points with a trailing projective `z` of `1`
/// (`["1","0"]` in G2). Any other `z` would mean the x/y we read are not affine
/// coordinates, so it is rejected rather than ignored.
pub(crate) fn check_z_is_one(
    z: &serde_json::Value,
    g2: bool,
    what: &str,
) -> Result<(), LaniakeaError> {
    let ok = if g2 {
        z.as_array().is_some_and(|a| {
            a.len() == 2 && a[0].as_str() == Some("1") && a[1].as_str() == Some("0")
        })
    } else {
        z.as_str() == Some("1")
    };
    if ok {
        Ok(())
    } else {
        Err(LaniakeaError::Serialization(format!(
            "{what}: projective z coordinate must be {}",
            if g2 { r#"["1","0"]"# } else { r#""1""# }
        )))
    }
}
