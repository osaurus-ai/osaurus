//
//  PrivacyFilterModelBundle.swift
//  osaurus / PrivacyFilter
//
//  Describes the on-disk layout of the converted model bundle and
//  provides an integrity verifier.
//
//  Layout under `<root>/aux-models/openai-privacy-filter-bf16-v1/`:
//      config.json                       (model arch + id2label)
//      model.safetensors                 (BF16 weights, LFS)
//      model.safetensors.index.json      (optional shard map)
//      tokenizer.json                    (LFS)
//      tokenizer_config.json
//      viterbi_calibration.json          (optional decoder biases)
//      osaurus-manifest.json             (locally generated at download
//                                         time from HF's tree response;
//                                         carries size + sha256 for LFS
//                                         files so re-verify can detect
//                                         tampering or partial writes)
//
//  We synthesize our own manifest because the upstream
//  `mlx-community/openai-privacy-filter-bf16` repo does not ship one —
//  hashes come from Hugging Face's `/api/models/.../tree/main` payload
//  (LFS-backed files expose a real sha256 in `lfs.oid`).
//

import CryptoKit
import Foundation

public enum PrivacyFilterModelBundle {
    /// Bump when upstream re-publishes the converted bundle so we
    /// re-download instead of silently using a stale copy.
    public static let version = "openai-privacy-filter-bf16-v1"

    /// Files that must be present for the engine to load.
    public static let requiredFiles: [String] = [
        "config.json",
        "model.safetensors",
        "tokenizer.json",
        "tokenizer_config.json",
    ]

    /// Tolerated when missing (legacy bundles, optional sidecars).
    public static let optionalFiles: [String] = [
        "model.safetensors.index.json",
        "viterbi_calibration.json",
    ]

    /// Local manifest name. Written by the downloader from the HF
    /// tree API response after every successful download.
    public static let manifestFilename = "osaurus-manifest.json"

    public static func directoryURL() -> URL {
        OsaurusPaths.root()
            .appendingPathComponent("aux-models", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
    }

    /// True when every required file + our local manifest exists.
    /// Does NOT verify hashes — use `verify(at:)` for that.
    public static func exists(at directory: URL = directoryURL()) -> Bool {
        let fm = FileManager.default
        for file in requiredFiles + [manifestFilename] {
            if !fm.fileExists(atPath: directory.appendingPathComponent(file).path) {
                return false
            }
        }
        return true
    }

    // MARK: - Manifest schema

    /// Entry written at download time. `sha256` is only present for
    /// LFS-backed files because HF only exposes a content sha256 for
    /// those. Small JSON sidecars rely on size + parseability checks.
    public struct ManifestEntry: Codable, Equatable, Sendable {
        public let size: Int64
        public let sha256: String?
    }

    public struct Manifest: Codable, Equatable, Sendable {
        public let repoId: String
        public let revision: String
        public let files: [String: ManifestEntry]

        public init(repoId: String, revision: String, files: [String: ManifestEntry]) {
            self.repoId = repoId
            self.revision = revision
            self.files = files
        }
    }

    // MARK: - Verification

    public enum VerifyError: LocalizedError, Equatable {
        case manifestMissing
        case manifestInvalid(String)
        case requiredFileMissing(String)
        case sizeMismatch(file: String, expected: Int64, actual: Int64)
        case sha256Mismatch(file: String, expected: String, actual: String)

        public var errorDescription: String? {
            switch self {
            case .manifestMissing:
                return "Manifest missing — please re-download."
            case .manifestInvalid(let detail):
                return "Manifest invalid: \(detail)"
            case .requiredFileMissing(let f):
                return "Required file missing: \(f)"
            case .sizeMismatch(let f, let exp, let got):
                return "Size mismatch for \(f): expected \(exp), got \(got)"
            case .sha256Mismatch(let f, _, _):
                return "Content mismatch for \(f) — file is corrupted."
            }
        }
    }

    public static func readManifest(at directory: URL = directoryURL()) throws -> Manifest {
        let url = directory.appendingPathComponent(manifestFilename)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VerifyError.manifestMissing
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            throw VerifyError.manifestInvalid(error.localizedDescription)
        }
    }

    public static func writeManifest(_ manifest: Manifest, at directory: URL = directoryURL()) throws {
        let url = directory.appendingPathComponent(manifestFilename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: .atomic)
    }

    /// Verify every required file against the local manifest. Small
    /// JSON sidecars without an LFS sha256 only get a size check.
    /// Optional files are tolerated when absent.
    public static func verify(at directory: URL = directoryURL()) throws {
        let manifest = try readManifest(at: directory)

        for file in requiredFiles {
            let path = directory.appendingPathComponent(file).path
            if !FileManager.default.fileExists(atPath: path) {
                throw VerifyError.requiredFileMissing(file)
            }
        }

        for (file, entry) in manifest.files {
            let url = directory.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: url.path) else {
                if optionalFiles.contains(file) { continue }
                throw VerifyError.requiredFileMissing(file)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let onDiskSize = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            if onDiskSize != entry.size {
                throw VerifyError.sizeMismatch(
                    file: file,
                    expected: entry.size,
                    actual: onDiskSize
                )
            }
            if let expectedHex = entry.sha256 {
                let actualHex = try sha256Hex(of: url)
                if !actualHex.equalsIgnoringCase(expectedHex) {
                    throw VerifyError.sha256Mismatch(
                        file: file,
                        expected: expectedHex,
                        actual: actualHex
                    )
                }
            }
        }
    }

    /// Remove the entire bundle directory so the next download starts
    /// from scratch. Used after a verify failure.
    public static func clean(at directory: URL = directoryURL()) throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - SHA256 streamer

    /// Streams the file through SHA-256 in 64KB chunks so we don't
    /// load a 2.8GB safetensors blob into RAM just to hash it.
    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private extension String {
    func equalsIgnoringCase(_ other: String) -> Bool {
        caseInsensitiveCompare(other) == .orderedSame
    }
}
