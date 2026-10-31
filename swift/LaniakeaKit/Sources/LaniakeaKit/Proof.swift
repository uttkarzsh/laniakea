import Foundation

/// A generated Groth16 proof and the public signals it was generated for, in the
/// layouts snarkjs reads (`proof.json` and `public.json`).
///
/// **Generated is not verified, and valid is not "true".** `prove` does not check the
/// proof. To check one, use `Verifier` with the circuit's verification key, or give
/// `proof.json`, `public.json` and the key to another verifier
/// (`snarkjs groth16 verify verification_key.json public.json proof.json`, or one on a
/// server). And a valid proof only says the circuit was satisfied with
/// these public signals: a circuit like `age_check` can produce a valid proof whose
/// output signal is 0. Whoever relies on the proof must read the public signals.
public struct Proof: Sendable, Equatable {
    /// The proof as snarkjs `proof.json`.
    public let proofJSON: String
    /// The public signals as canonical decimal strings, outputs first and then public
    /// inputs, in the order the verification key expects.
    public let publicSignals: [String]

    init(proofJSON: String, publicSignals: [String]) {
        self.proofJSON = proofJSON
        self.publicSignals = publicSignals
    }

    /// The public signals as snarkjs `public.json`: a JSON array of decimal strings.
    public var publicSignalsJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        // Encoding an array of strings cannot fail.
        return (try? String(data: encoder.encode(publicSignals), encoding: .utf8)) ?? "[]"
    }

    /// Writes `proof.json` and `public.json` into `directory` (created if needed), so
    /// that a verifier can check this proof. Returns the two file URLs.
    ///
    /// **Overwriting.** A file already at either destination is replaced. A destination
    /// that is a directory is refused and nothing is changed.
    ///
    /// **Failure.** Both files are first written under temporary names in `directory`.
    /// If that fails, no destination is touched. They are then moved into place; if
    /// the second move fails, the first destination is put back as it was (its previous
    /// contents, or removed if it did not exist), so a failed call does not normally
    /// leave a new `proof.json` next to an old or missing `public.json`.
    ///
    /// **This is not an atomic export of the pair.** Each file is replaced with a
    /// single `FileManager` operation, but nothing makes the two operations one, and
    /// nothing is flushed to disk explicitly. A crash or power loss between the two
    /// moves can leave a new file beside an old one, and hidden `.tmp`/`.bak` files
    /// behind. If the rollback itself fails, the error says so: its reason names the
    /// original failure, the rollback failure, and the path of a hidden `.bak` file that
    /// is kept and holds the previous first file. Recover it from there.
    ///
    /// A mismatched pair (a proof beside public signals from another proof) can fail
    /// verification, but not necessarily: if both proofs have identical public signals,
    /// the mixed pair is still a valid proof of that statement. Do not rely on
    /// verification to detect a half-written export. Do not export two proofs into
    /// the same directory concurrently.
    ///
    /// The files hold the proof and the public signals only: nothing private. They are
    /// written wherever you point this, with the default file protection of that
    /// location; choosing where they may go is the app's job.
    ///
    /// - Throws: `LaniakeaError.exportFailed`.
    @discardableResult
    public func write(
        to directory: URL,
        proofFileName: String = "proof.json",
        publicSignalsFileName: String = "public.json"
    ) throws -> (proof: URL, publicSignals: URL) {
        try write(
            to: directory,
            proofFileName: proofFileName,
            publicSignalsFileName: publicSignalsFileName,
            install: Self.install
        )
    }

    /// Moves a staged file onto its destination, replacing what is there.
    static func install(_ staged: URL, at destination: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: staged)
        } else {
            try manager.moveItem(at: staged, to: destination)
        }
    }

    /// `install` is the step that puts a staged file in place; tests replace it to make
    /// the second move fail.
    func write(
        to directory: URL,
        proofFileName: String,
        publicSignalsFileName: String,
        install: (_ staged: URL, _ destination: URL) throws -> Void
    ) throws -> (proof: URL, publicSignals: URL) {
        for name in [proofFileName, publicSignalsFileName] where name.isEmpty || name.contains("/") || name == "." || name == ".." {
            throw LaniakeaError.exportFailed(file: name, reason: "not a plain file name")
        }
        guard proofFileName != publicSignalsFileName else {
            throw LaniakeaError.exportFailed(file: proofFileName, reason: "the proof and the public signals need different file names")
        }
        let manager = FileManager.default
        let destinations = [
            directory.appendingPathComponent(proofFileName),
            directory.appendingPathComponent(publicSignalsFileName),
        ]
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw LaniakeaError.exportFailed(file: directory.path, reason: error.localizedDescription)
        }
        for url in destinations {
            var isDirectory: ObjCBool = false
            if manager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                throw LaniakeaError.exportFailed(file: url.path, reason: "a directory is in the way")
            }
        }

        // Everything written below is removed again unless it was moved into place.
        let token = UUID().uuidString
        let staged = destinations.map { directory.appendingPathComponent(".\($0.lastPathComponent).\(token).tmp") }
        let backup = directory.appendingPathComponent(".\(destinations[0].lastPathComponent).\(token).bak")
        // The backup is kept (not removed) only if a rollback failed.
        var keepBackup = false
        defer {
            for url in staged + (keepBackup ? [] : [backup]) { try? manager.removeItem(at: url) }
        }

        for (url, text) in zip(staged, [proofJSON, publicSignalsJSON]) {
            do {
                try Data(text.utf8).write(to: url)
            } catch {
                throw LaniakeaError.exportFailed(file: url.path, reason: error.localizedDescription)
            }
        }

        // Keep the first destination's previous contents until the second move succeeds.
        let hadFirst = manager.fileExists(atPath: destinations[0].path)
        if hadFirst {
            do {
                try manager.copyItem(at: destinations[0], to: backup)
            } catch {
                throw LaniakeaError.exportFailed(file: destinations[0].path, reason: error.localizedDescription)
            }
        }
        do {
            try install(staged[0], destinations[0])
        } catch {
            throw LaniakeaError.exportFailed(file: destinations[0].path, reason: error.localizedDescription)
        }
        do {
            try install(staged[1], destinations[1])
        } catch {
            // Put the first file back as it was.
            var rollbackFailure: Error?
            if hadFirst {
                do { try install(backup, destinations[0]) } catch { rollbackFailure = error }
            } else {
                do { try manager.removeItem(at: destinations[0]) } catch { rollbackFailure = error }
            }
            guard let rollbackFailure else {
                throw LaniakeaError.exportFailed(file: destinations[1].path, reason: error.localizedDescription)
            }
            var reason = "\(error.localizedDescription). Restoring \(destinations[0].path) also failed (\(rollbackFailure.localizedDescription)), so it may hold the new file next to an old \(destinations[1].lastPathComponent)."
            if hadFirst {
                keepBackup = true
                reason += " The previous file is kept at \(backup.path)."
            }
            throw LaniakeaError.exportFailed(file: destinations[1].path, reason: reason)
        }
        return (destinations[0], destinations[1])
    }
}
