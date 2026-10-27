import Foundation

/// The two files a Circom circuit is proved from, read into memory: the proving
/// artifact (the proving key and constraint matrices, prepared from the `.zkey` with
/// Laniakea's `export_artifact` tool) and the circuit's compiled WASM.
///
/// Both are separate from the SDK binary: the app ships them as resources, or
/// supplies them in some other way, and decides which circuit it proves.
///
/// A `Circuit` does not check that the two files belong together or that the
/// artifact is valid: the artifact carries no circuit identity, so nothing can say
/// which circuit it is for. `Prover(circuit:)` validates the artifact and the WASM and
/// catches many mismatches (for example a different number of wires) but not all of
/// them. Keep the pair together, and keep both files from the same build.
public struct Circuit: Sendable {
    public let artifact: Data
    public let wasm: Data

    /// From bytes already in memory.
    public init(artifact: Data, wasm: Data) {
        self.artifact = artifact
        self.wasm = wasm
    }

    /// Reads both files. Blocking file I/O: for large artifacts call it off the main
    /// thread. Throws `LaniakeaError.fileUnreadable`.
    public init(artifactURL: URL, wasmURL: URL) throws {
        self.init(artifact: try Self.read(artifactURL), wasm: try Self.read(wasmURL))
    }

    /// Reads `<name>.artifact` and `<name>.wasm` from a bundle (the app's main bundle by
    /// default). Throws `LaniakeaError.fileUnreadable`.
    public init(name: String, bundle: Bundle = .main) throws {
        func url(_ pathExtension: String) throws -> URL {
            guard let url = bundle.url(forResource: name, withExtension: pathExtension) else {
                throw LaniakeaError.fileUnreadable(
                    file: "\(name).\(pathExtension)",
                    reason: "not found in the bundle at \(bundle.bundlePath)"
                )
            }
            return url
        }
        try self.init(artifactURL: url("artifact"), wasmURL: url("wasm"))
    }

    private static func read(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw LaniakeaError.fileUnreadable(file: url.path, reason: error.localizedDescription)
        }
    }
}
