# The `.artifact` file format

A `.artifact` file is the proving material of one Circom circuit (the Groth16 proving key
and the R1CS constraint matrices, exported from the circuit's `.zkey`), in the form the
portable prover loads. This document describes **format version 1**, the first versioned
format. Its purpose is to detect a wrong, newer or damaged file early and to give future
SDK releases a compatibility boundary. It is not a security feature (see the end).

## Layout (format 1)

All multi-byte integers are little-endian.

| Offset | Size | Field | Encoding |
|---|---|---|---|
| 0 | 8 | Magic | `89 4C 4E 4B 41 52 54 0A` (`\x89LNKART\n`) |
| 8 | 2 | Format version | u16, currently `1` |
| 10 | 8 | Payload length | u64, the number of bytes after the header |
| 18 | N | Payload | the Arkworks (0.4) canonical **uncompressed** serialization of `ProvingArtifact` |

The header is fixed at 18 bytes. The magic's first byte is not ASCII (a text file cannot
match) and its last byte is a newline (it catches line-ending conversion).

The payload is exactly what `CanonicalSerialize::serialize_uncompressed` produced for the
same `ProvingArtifact` before the header existed: the proving key (`ark_groth16::ProvingKey<Bn254>`),
then the constraint matrices (`SerializableConstraintMatrices`: six `usize` fields, then
matrices A, B and C). **Format 1 defines that encoding**, including the field order of those
structs and Arkworks' behaviour (lengths and `usize` as u64, uncompressed affine points, field
elements as canonical little-endian integers). The golden test
`header_bytes_are_exactly_the_documented_layout` pins this: the payload must equal the
Arkworks serialization byte for byte.

Reference implementation: `crates/laniakea-core/src/artifacts.rs`
(`ARTIFACT_MAGIC`, `ARTIFACT_FORMAT_VERSION`, `ARTIFACT_HEADER_LEN`, `split_artifact_header`,
`ProvingArtifact::to_bytes` / `from_bytes`).

## Parsing and validation order

`ProvingArtifact::from_bytes` (used by `Prover::new`, and so by the Swift SDK) does, in order:

1. **Header** (`split_artifact_header`): constant time, no allocation, and the declared
   payload length is only ever *compared* with the bytes present, never used to size a buffer.
   1. Empty input: error ("input is empty").
   2. Magic: the first 8 bytes (or all of them, if fewer) must match the magic. A mismatch
      means the file is not an artifact, including a raw artifact from before format 1:
      error, with an actionable re-export message (below). A shorter input that is a
      strict prefix of the magic is a truncated file.
   3. Fewer than 18 bytes: truncated header.
   4. Version: anything other than `1` is **unsupported version**, returned before the rest
      of the header or the payload is interpreted (a later version may lay out the header
      differently).
   5. Length: a declared length larger than the bytes present is a truncated file; a smaller
      one means trailing bytes. Both are rejected.
2. **Payload**: Arkworks deserialization of exactly the payload, which also checks every curve
   point (on the curve, in the correct subgroup) and every field element. Failure, or bytes left
   unused inside the declared payload, is a malformed payload.
3. **Structure**: `ProvingArtifact::validate` (lengths agree, indices in range, evaluation
   domain matches `h_query`, ...), unchanged from before the header.

Only after all three does `Prover` load the circuit's WASM, so a bad artifact never costs a
WASM compile, and header-level problems never cost curve-point validation.

## Errors

| Condition | Rust core (`LaniakeaError`) | UniFFI (`ProverError`) | Swift (`LaniakeaError`) |
|---|---|---|---|
| Empty input, bad or missing magic (legacy raw file), truncated header or payload, trailing bytes, malformed payload | `ArtifactLoad(String)` | `ArtifactLoad { detail }` | `.invalidArtifact(detail:)` (detail prefixed `loading:`) |
| Format version other than 1 | `UnsupportedArtifactVersion { found, supported }` | `UnsupportedArtifactVersion { found, supported }` | `.unsupportedArtifactVersion(found:supported:)` |
| Parses, but structurally inconsistent | `InvalidArtifact(String)` | `InvalidArtifact { detail }` | `.invalidArtifact(detail:)` |

Match on the case, never on the message text. An app that gets
`.unsupportedArtifactVersion` should update the SDK (the artifact is newer than the SDK) or
re-export the artifact with a matching `export_artifact`.

## Legacy artifacts and migration

Before format 1, an `.artifact` file was the bare Arkworks serialization (what is now the
payload) with no header. **Those files are not read**: this is a deliberate clean break made
before the first public release, and no legacy reader exists. A legacy file is refused at the
magic check with a message that says it lacks the Laniakea artifact header and must be
re-exported.

To migrate, re-export from the circuit's `.zkey` with the current tool (Rust required, on a
development machine):

```sh
cargo run -p laniakea-cli --bin export_artifact -- <circuit>_final.zkey <circuit>.artifact
```

The repository's example artifact is regenerated with `scripts/prepare-ios-app-resources.sh`.
Its payload is byte-identical to the old file; only the 18-byte header is new.

## Versioning policy

- The format version is independent of the SDK's semantic version. Each SDK release states
  which format versions it reads (currently: 1 only); the writer produces the newest.
- Any change to the payload encoding is a new format version: the proving system or curve,
  the Arkworks version's encoding, the order or type of fields, anything that would make the
  same bytes mean something else. Format 1 is never reinterpreted.
- A new version gets its own section here and its own tests; whether older versions remain
  readable is decided for that release and stated in its notes. An SDK that meets a version it
  does not read reports `UnsupportedArtifactVersion` and does nothing else with the file.
- No field is added to format 1. A header change that needs more space is a new version.

## What the format does not give you

- **No circuit identity.** The header says nothing about which circuit the artifact belongs
  to. A WASM from another circuit is detected only if its wire count differs from the
  artifact's. Keep the artifact and WASM of one build together.
- **No cryptographic integrity or authenticity.** There is no digest, checksum or signature,
  by decision: the format is not an integrity or authentication feature. The point checks and
  structural validation catch many kinds of damage, but a changed matrix coefficient, or a
  deliberately crafted but self-consistent artifact, is not detected; and a valid artifact is
  no evidence that its trusted setup is sound. Do not treat a loading artifact as a vouched-for one.
- No statement about the proving key being correct for any circuit; see
  `ProvingArtifact::validate`.
