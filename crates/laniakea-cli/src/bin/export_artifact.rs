//! Desktop build step: convert a Circom `.zkey` into the serialized
//! `ProvingArtifact` the portable (iOS) prover loads.
//!
//! Usage: export_artifact <circuit.zkey> <out.artifact>

use anyhow::{bail, Context};
use std::fs;

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        bail!("usage: {} <circuit.zkey> <out.artifact>", args[0]);
    }
    let zkey = fs::read(&args[1]).with_context(|| format!("reading {}", args[1]))?;
    let artifact = laniakea_core::parse_zkey_to_artifact(&zkey)
        .map_err(|e| anyhow::anyhow!("parsing zkey: {e}"))?;
    let bytes = artifact.to_bytes();
    fs::write(&args[2], &bytes).with_context(|| format!("writing {}", args[2]))?;
    println!("wrote {} ({} bytes)", args[2], bytes.len());
    Ok(())
}
