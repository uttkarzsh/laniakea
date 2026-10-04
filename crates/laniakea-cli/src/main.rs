use ark_serialize::CanonicalSerialize;
use laniakea_core::{Groth16Backend, ZkBackend};
use std::fs;
use std::io::Cursor;

fn main() -> anyhow::Result<()> {
    println!("Testing verification with snarkjs-generated proof...");

    // Load snarkjs-generated proof and public signals
    let proof_json = fs::read_to_string("circuits/age_check/proof.json")?;
    let public_json = fs::read_to_string("circuits/age_check/public.json")?;

    // Load zkey to extract verifying key
    let zkey_bytes = fs::read("circuits/age_check/age_check_final.zkey")?;
    let (proving_key, _matrices) = ark_circom::read_zkey(&mut Cursor::new(&zkey_bytes))?;
    let vk = proving_key.vk;

    // Serialize verifying key in binary format
    let mut vk_bytes = Vec::new();
    vk.serialize_uncompressed(&mut vk_bytes)?;

    // Test verification
    let backend = Groth16Backend;
    let verified = backend.verify(&proof_json, &public_json, &vk_bytes)?;
    println!("Verification result: {}", verified);
    assert!(verified, "Proof verification failed!");

    println!("\n✓ Verification test passed!");

    println!("\nNote: Full proving test skipped due to known ark-circom 0.1.0 + Wasmer 2.3 compatibility issue:");
    println!("  - ark-circom 0.1.0 has a bug with Wasmer 2.3 causing ptr::copy alignment panic");
    println!("  - This is a known issue in the ark-circom crate (test 'smt_verifier' also panics)");
    println!("  - Circuit artifacts are valid (verified via snarkjs)");
    println!("  - Verification logic is correct (tested above)");

    Ok(())
}
