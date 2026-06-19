//
//  AgentBundleService.swift
//  osaurus
//
//  Phase 4 — per-agent encrypted export/import bundle (spec §11.1). The
//  bundle is a tar archive (`.osaurus-agent`) containing:
//
//   - `manifest.json`     — bundle metadata + key-wrapping ciphertext.
//   - `agent.json`        — the agent's `Agent.json` body (no .osec wrap).
//   - `db.sqlite`         — the agent's encrypted SQLCipher database,
//                           rekeyed to a bundle-local key on export.
//   - `schema.sql`        — human-readable schema dump.
//   - `views/<name>.sql`  — saved-view definitions.
//   - `migrations/*.sql`  — migration files.
//   - `runs/`             — JSON run traces (best effort; skipped if absent).
//
//  Key wrapping: a fresh random 256-bit "bundle key" is generated per
//  export, used to rekey `db.sqlite` (and as the AES-GCM key for any
//  future file-by-file wrapping). The bundle key itself is wrapped with
//  a passphrase-derived KEK (PBKDF2-SHA256, 600k iterations, 16-byte
//  salt, AES-GCM seal). The wrapper goes in `manifest.json` so the
//  receiving Mac can derive the same KEK from the passphrase.
//
//  Import is review-before-activation: the bundle is unpacked into a
//  scratch directory; the caller surfaces the manifest to the user; only
//  after explicit user approval does the service move files into
//  `~/.osaurus/agents/<id>/` and rekey `db.sqlite` to the local storage
//  key.
//

import CommonCrypto
import CryptoKit
import Foundation
import OsaurusSQLCipher

public enum AgentBundleError: Error, LocalizedError {
    case agentNotFound
    case readFailed(String)
    case writeFailed(String)
    case archiveFailed(String)
    case passphraseTooShort
    case decryptFailed(String)
    case manifestInvalid(String)
    case rekeyFailed(String)

    public var errorDescription: String? {
        switch self {
        case .agentNotFound: return "Agent not found."
        case .readFailed(let m): return "Bundle read failed: \(m)"
        case .writeFailed(let m): return "Bundle write failed: \(m)"
        case .archiveFailed(let m): return "Archive build failed: \(m)"
        case .passphraseTooShort:
            return "Bundle passphrase must be at least 8 characters."
        case .decryptFailed(let m): return "Bundle key unwrap failed: \(m)"
        case .manifestInvalid(let m): return "Bundle manifest is invalid: \(m)"
        case .rekeyFailed(let m): return "Bundle rekey failed: \(m)"
        }
    }
}

/// Format-tag we stamp into the manifest. Bump when the on-disk shape
/// changes so old/new versions can refuse incompatible bundles.
public enum AgentBundleFormat {
    public static let currentVersion: Int = 1
}

/// What gets pretty-printed into the manifest. Public so the importer
/// can render a review screen ("This bundle exports `<name>` with N
/// tables and M rows — proceed?") without rummaging in private types.
public struct AgentBundleManifest: Codable, Sendable {
    public var formatVersion: Int
    public var exportedAt: Date
    public var agentId: UUID
    public var agentName: String
    public var agentDescription: String
    public var schemaTables: Int
    public var savedViews: Int
    /// PBKDF2 salt, base64-encoded.
    public var kdfSalt: String
    /// PBKDF2 iteration count.
    public var kdfIterations: Int
    /// AES-GCM nonce that sealed the bundle key, base64-encoded.
    public var keyNonce: String
    /// AES-GCM ciphertext of the bundle key, base64-encoded.
    public var keyCiphertext: String
    /// AES-GCM auth tag, base64-encoded.
    public var keyTag: String
}

/// Top-level service. Singleton so callers don't accidentally instantiate
/// multiple file-system roots; the work itself is reentrant.
public actor AgentBundleService {
    public static let shared = AgentBundleService()

    /// Default PBKDF2 cost. Burn ~250ms on Apple Silicon to make brute
    /// force expensive without making import feel sluggish.
    public static let kdfIterations = 600_000

    private init() {}

    // MARK: - Export

    public struct ExportResult: Sendable {
        public var bundleURL: URL
        public var manifest: AgentBundleManifest
    }

    /// Build a `.osaurus-agent` bundle for `agentId`, sealed with
    /// `passphrase`. `destinationDirectory` must exist and be writable;
    /// the file is named `<agent-slug>.osaurus-agent`. Returns the URL
    /// of the produced file plus the manifest copied into it.
    public func exportBundle(
        agentId: UUID,
        passphrase: String,
        destinationDirectory: URL
    ) async throws -> ExportResult {
        guard passphrase.count >= 8 else { throw AgentBundleError.passphraseTooShort }

        // 1. Materialize the agent into a scratch directory we own. We
        //    can't ship the live `~/.osaurus/agents/<id>/db.sqlite`
        //    directly because we have to rekey it to the bundle key
        //    without touching the live file. Copy first, then rekey
        //    the copy.
        let agent: Agent = try await MainActor.run {
            guard let a = AgentStore.load(id: agentId) else {
                throw AgentBundleError.agentNotFound
            }
            return a
        }

        let scratch = try makeScratchDirectory(prefix: "osaurus-agent-export-")
        defer { try? FileManager.default.removeItem(at: scratch) }

        // 2. Write the agent JSON. We round-trip through the same
        //    encoder AgentStore uses so the bundle matches the
        //    on-disk wire format byte-for-byte.
        try writeAgentJSON(agent, to: scratch.appendingPathComponent("agent.json"))

        // 3. Copy + rekey the per-agent database.
        let bundleKey = SymmetricKey(size: .bits256)
        try await copyAndRekeyAgentDB(
            agentId: agentId,
            to: scratch.appendingPathComponent("db.sqlite"),
            newKey: bundleKey
        )

        // 4. Copy schema.sql / views/ / migrations/ / runs/ if present.
        let agentDir = OsaurusPaths.agentDirectory(for: agentId)
        try copyIfExists(
            from: agentDir.appendingPathComponent("schema.sql"),
            to: scratch.appendingPathComponent("schema.sql")
        )
        try copyDirIfExists(
            from: OsaurusPaths.agentViewsDirectory(for: agentId),
            to: scratch.appendingPathComponent("views")
        )
        try copyDirIfExists(
            from: OsaurusPaths.agentMigrationsDirectory(for: agentId),
            to: scratch.appendingPathComponent("migrations")
        )
        try copyDirIfExists(
            from: OsaurusPaths.agentRunsDirectory(for: agentId),
            to: scratch.appendingPathComponent("runs")
        )

        // 5. Build the manifest. Schema / view counts come from the
        //    rekeyed copy of `db.sqlite` so we open with the bundle
        //    key — keeps the manifest honest.
        let (tables, views) =
            (try? readBundleStats(
                dbPath: scratch.appendingPathComponent("db.sqlite").path,
                key: bundleKey
            )) ?? (0, 0)

        let (kdfSalt, kekData) = try deriveKEK(passphrase: passphrase)
        let kek = SymmetricKey(data: kekData)
        let sealed = try AES.GCM.seal(
            bundleKey.withUnsafeBytes { Data($0) },
            using: kek
        )
        guard let nonce = sealed.nonce.withUnsafeBytes({ Data($0) }) as Data?,
            !nonce.isEmpty
        else {
            throw AgentBundleError.archiveFailed("nonce missing")
        }

        let manifest = AgentBundleManifest(
            formatVersion: AgentBundleFormat.currentVersion,
            exportedAt: Date(),
            agentId: agent.id,
            agentName: agent.displayName,
            agentDescription: agent.description,
            schemaTables: tables,
            savedViews: views,
            kdfSalt: kdfSalt.base64EncodedString(),
            kdfIterations: Self.kdfIterations,
            keyNonce: nonce.base64EncodedString(),
            keyCiphertext: sealed.ciphertext.base64EncodedString(),
            keyTag: sealed.tag.base64EncodedString()
        )
        try writeManifest(manifest, to: scratch.appendingPathComponent("manifest.json"))

        // 6. Tar the scratch directory into the destination.
        let slug = sanitizeFilename(agent.displayName.isEmpty ? agent.id.uuidString : agent.displayName)
        let bundleURL =
            destinationDirectory
            .appendingPathComponent("\(slug).osaurus-agent")
        try await tarDirectory(scratch, into: bundleURL)

        return ExportResult(bundleURL: bundleURL, manifest: manifest)
    }

    // MARK: - Import (review-before-activate)

    public struct ImportPreview: Sendable {
        /// Read-only directory we unpacked into. Caller can show its
        /// contents in a review UI. Survives until `activate` or
        /// `discard` is called.
        public var stagingDirectory: URL
        public var manifest: AgentBundleManifest
        /// Bundle key, unwrapped with the user's passphrase. Held
        /// in-memory only — never written to disk. We need it again
        /// in `activate` to rekey `db.sqlite` to the local storage key.
        let bundleKey: SymmetricKey
    }

    /// Unpack and verify a bundle without touching `~/.osaurus/`. The
    /// caller is expected to surface `preview.manifest` to the user
    /// for review, then call `activate(preview:)` to actually move
    /// the files into place. `discard(preview:)` cleans up.
    public func openBundleForReview(
        url: URL,
        passphrase: String
    ) async throws -> ImportPreview {
        guard passphrase.count >= 8 else { throw AgentBundleError.passphraseTooShort }

        let staging = try makeScratchDirectory(prefix: "osaurus-agent-import-")
        do {
            try await untar(url, into: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }

        let manifestURL = staging.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            try? FileManager.default.removeItem(at: staging)
            throw AgentBundleError.manifestInvalid("no manifest.json in bundle")
        }
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest: AgentBundleManifest
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            manifest = try decoder.decode(AgentBundleManifest.self, from: manifestData)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw AgentBundleError.manifestInvalid(error.localizedDescription)
        }
        guard manifest.formatVersion == AgentBundleFormat.currentVersion else {
            try? FileManager.default.removeItem(at: staging)
            throw AgentBundleError.manifestInvalid(
                "format version \(manifest.formatVersion) not supported by this build"
            )
        }

        // Unwrap the bundle key. Wrong passphrase = AES-GCM auth failure.
        guard let salt = Data(base64Encoded: manifest.kdfSalt),
            let nonceBytes = Data(base64Encoded: manifest.keyNonce),
            let ciphertext = Data(base64Encoded: manifest.keyCiphertext),
            let tag = Data(base64Encoded: manifest.keyTag)
        else {
            try? FileManager.default.removeItem(at: staging)
            throw AgentBundleError.manifestInvalid("manifest base64 fields malformed")
        }

        let kekData = try Self.pbkdf2(
            passphrase: passphrase,
            salt: salt,
            iterations: manifest.kdfIterations,
            keyLength: 32
        )
        let kek = SymmetricKey(data: kekData)
        let nonce: AES.GCM.Nonce
        do {
            nonce = try AES.GCM.Nonce(data: nonceBytes)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw AgentBundleError.decryptFailed(error.localizedDescription)
        }
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw AgentBundleError.decryptFailed(error.localizedDescription)
        }
        let bundleKeyData: Data
        do {
            bundleKeyData = try AES.GCM.open(sealedBox, using: kek)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw AgentBundleError.decryptFailed(
                "wrong passphrase or corrupted bundle"
            )
        }

        return ImportPreview(
            stagingDirectory: staging,
            manifest: manifest,
            bundleKey: SymmetricKey(data: bundleKeyData)
        )
    }

    /// Activate a previously reviewed import: move the staged files
    /// into `~/.osaurus/agents/<id>/`, rekey `db.sqlite` from the
    /// bundle key to the host storage key, and write the agent JSON
    /// through `AgentStore`.
    @discardableResult
    public func activate(preview: ImportPreview) async throws -> Agent {
        let manifest = preview.manifest
        let staging = preview.stagingDirectory
        let fm = FileManager.default

        // 1. Decode the staged agent JSON. Catch malformed early.
        let agentURL = staging.appendingPathComponent("agent.json")
        guard fm.fileExists(atPath: agentURL.path) else {
            throw AgentBundleError.manifestInvalid("no agent.json in bundle")
        }
        let agentData = try Data(contentsOf: agentURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let agent = try decoder.decode(Agent.self, from: agentData)
        guard agent.id == manifest.agentId else {
            throw AgentBundleError.manifestInvalid("manifest agentId mismatch")
        }

        // 2. Materialize `db.sqlite` from the bundle key into the host's
        //    at-rest posture: plaintext by default, or SQLCipher (host key)
        //    when the user opted in. The bundle itself is always an encrypted,
        //    passphrase-protected artifact regardless of local posture.
        let dbPath = staging.appendingPathComponent("db.sqlite").path
        if fm.fileExists(atPath: dbPath) {
            let destKey: SymmetricKey? =
                StorageEncryptionPolicy.shared.isEncryptionEnabled
                ? try StorageKeyManager.shared.currentKey()
                : nil
            let converted = staging.appendingPathComponent("db.converted.sqlite").path
            try? fm.removeItem(atPath: converted)
            StorageFile.removeSidecars(for: converted)
            do {
                try StorageFormatConverter.export(
                    from: dbPath,
                    srcKey: preview.bundleKey,
                    to: converted,
                    dstKey: destKey
                )
            } catch {
                throw AgentBundleError.rekeyFailed(error.localizedDescription)
            }
            try moveOverwriting(from: converted, to: dbPath)
        }

        // 3. Move files into the live agent directory. The agent JSON
        //    goes through `AgentStore.save` so any normalization the
        //    store does (back-compat decoding, etc.) is preserved.
        let agentDir = OsaurusPaths.agentDirectory(for: agent.id)
        OsaurusPaths.ensureExistsSilent(agentDir)
        // Close the live DB handle first (if one exists) so we don't
        // hold an open fd while replacing the file.
        await MainActor.run { AgentDatabaseStore.shared.close(agent.id) }
        try moveOverwriting(from: dbPath, to: agentDir.appendingPathComponent("db.sqlite").path)
        try moveOverwritingIfExists(
            from: staging.appendingPathComponent("schema.sql").path,
            to: agentDir.appendingPathComponent("schema.sql").path
        )
        try moveDirOverwritingIfExists(
            from: staging.appendingPathComponent("views").path,
            to: OsaurusPaths.agentViewsDirectory(for: agent.id).path
        )
        try moveDirOverwritingIfExists(
            from: staging.appendingPathComponent("migrations").path,
            to: OsaurusPaths.agentMigrationsDirectory(for: agent.id).path
        )
        try moveDirOverwritingIfExists(
            from: staging.appendingPathComponent("runs").path,
            to: OsaurusPaths.agentRunsDirectory(for: agent.id).path
        )

        await MainActor.run { AgentStore.save(agent) }
        try? FileManager.default.removeItem(at: staging)
        return agent
    }

    /// Discard a preview without activating. Always safe to call.
    public func discard(preview: ImportPreview) {
        try? FileManager.default.removeItem(at: preview.stagingDirectory)
    }

    // MARK: - Internals

    private func makeScratchDirectory(prefix: String) throws -> URL {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(prefix + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        } catch {
            throw AgentBundleError.writeFailed(error.localizedDescription)
        }
        return temp
    }

    private func writeAgentJSON(_ agent: Agent, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(agent).write(to: url)
        } catch {
            throw AgentBundleError.writeFailed(error.localizedDescription)
        }
    }

    private func writeManifest(_ manifest: AgentBundleManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(manifest).write(to: url)
        } catch {
            throw AgentBundleError.writeFailed(error.localizedDescription)
        }
    }

    private func copyIfExists(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else { return }
        do {
            try fm.copyItem(at: src, to: dst)
        } catch {
            throw AgentBundleError.writeFailed(
                "copy \(src.lastPathComponent): \(error.localizedDescription)"
            )
        }
    }

    private func copyDirIfExists(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: src.path, isDirectory: &isDir), isDir.boolValue else { return }
        do {
            try fm.copyItem(at: src, to: dst)
        } catch {
            throw AgentBundleError.writeFailed(
                "copy dir \(src.lastPathComponent): \(error.localizedDescription)"
            )
        }
    }

    private func copyAndRekeyAgentDB(
        agentId: UUID,
        to destination: URL,
        newKey: SymmetricKey
    ) async throws {
        let fm = FileManager.default
        let src = OsaurusPaths.agentDatabaseFile(for: agentId).path
        guard fm.fileExists(atPath: src) else {
            // No DB yet — write an empty SQLCipher file with `newKey` so
            // the bundle is uniform.
            let conn = try EncryptedSQLiteOpener.open(path: destination.path, key: newKey)
            sqlite3_close(conn)
            return
        }
        // Close any in-process handle so we read a consistent file (no
        // unfinished WAL), then export the live DB — which may be plaintext
        // (default at-rest) or SQLCipher (opt-in) — into the bundle encrypted
        // with the portable bundle key.
        await MainActor.run { AgentDatabaseStore.shared.close(agentId) }
        let srcKey = try OsaurusStorageOpener.resolveKey(for: src)
        try? fm.removeItem(at: destination)
        StorageFile.removeSidecars(for: destination.path)
        do {
            try StorageFormatConverter.export(
                from: src,
                srcKey: srcKey,
                to: destination.path,
                dstKey: newKey
            )
        } catch {
            throw AgentBundleError.writeFailed("export db: \(error.localizedDescription)")
        }
    }

    /// Open the rekeyed bundle DB and tally tables + views for the
    /// manifest. Best-effort; failures return (0, 0) and the export
    /// proceeds without manifest stats rather than aborting.
    private func readBundleStats(
        dbPath: String,
        key: SymmetricKey
    ) throws -> (Int, Int) {
        let conn = try EncryptedSQLiteOpener.open(path: dbPath, key: key)
        defer { sqlite3_close(conn) }

        var tables = 0
        var stmt: OpaquePointer?
        // Count user tables — anything not in our reserved list.
        let sql =
            "SELECT count(*) FROM sqlite_master WHERE type='table' "
            + "AND name NOT LIKE 'sqlite_%' "
            + "AND name NOT IN ('_tables_meta', '_changelog', '_views')"
        if sqlite3_prepare_v2(conn, sql, -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW {
                tables = Int(sqlite3_column_int(stmt, 0))
            }
        }
        var views = 0
        var stmt2: OpaquePointer?
        if sqlite3_prepare_v2(conn, "SELECT count(*) FROM _views", -1, &stmt2, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt2) }
            if sqlite3_step(stmt2) == SQLITE_ROW {
                views = Int(sqlite3_column_int(stmt2, 0))
            }
        }
        return (tables, views)
    }

    // MARK: - PBKDF2 + key wrap

    private func deriveKEK(passphrase: String) throws -> (salt: Data, key: Data) {
        var saltBytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, 16, &saltBytes) == errSecSuccess else {
            throw AgentBundleError.archiveFailed("CSPRNG salt")
        }
        let salt = Data(saltBytes)
        let key = try Self.pbkdf2(
            passphrase: passphrase,
            salt: salt,
            iterations: Self.kdfIterations,
            keyLength: 32
        )
        return (salt, key)
    }

    /// PBKDF2-HMAC-SHA256 via CommonCrypto.
    fileprivate static func pbkdf2(
        passphrase: String,
        salt: Data,
        iterations: Int,
        keyLength: Int
    ) throws -> Data {
        var derived = Data(count: keyLength)
        let passphraseBytes = Array(passphrase.utf8)
        let result = derived.withUnsafeMutableBytes { derivedBuffer -> Int32 in
            salt.withUnsafeBytes { saltBuffer -> Int32 in
                guard let derivedBase = derivedBuffer.baseAddress,
                    let saltBase = saltBuffer.baseAddress
                else {
                    return Int32(kCCParamError)
                }
                return CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passphraseBytes,
                    passphraseBytes.count,
                    saltBase.assumingMemoryBound(to: UInt8.self),
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    derivedBase.assumingMemoryBound(to: UInt8.self),
                    keyLength
                )
            }
        }
        guard result == kCCSuccess else {
            throw AgentBundleError.decryptFailed("PBKDF2 returned \(result)")
        }
        return derived
    }

    // MARK: - Rekey helper

    /// Open the bundle DB with one key and rekey it to another. Used
    /// on both the export side (host key → bundle key) and the import
    /// side (bundle key → host key). Mirrors the body of
    /// `StorageExportService.rekeyDatabase` but expressed in our
    /// `EncryptedSQLiteOpener.rekey` API.
    // MARK: - File moves

    private func moveOverwriting(from srcPath: String, to dstPath: String) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dstPath) {
            try? fm.removeItem(atPath: dstPath)
        }
        do {
            try fm.moveItem(atPath: srcPath, toPath: dstPath)
        } catch {
            throw AgentBundleError.writeFailed("move \(srcPath): \(error.localizedDescription)")
        }
    }

    private func moveOverwritingIfExists(from srcPath: String, to dstPath: String) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: srcPath) else { return }
        try moveOverwriting(from: srcPath, to: dstPath)
    }

    private func moveDirOverwritingIfExists(from srcPath: String, to dstPath: String) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: srcPath, isDirectory: &isDir), isDir.boolValue else { return }
        if fm.fileExists(atPath: dstPath) {
            try? fm.removeItem(atPath: dstPath)
        }
        do {
            try fm.moveItem(atPath: srcPath, toPath: dstPath)
        } catch {
            throw AgentBundleError.writeFailed("move dir \(srcPath): \(error.localizedDescription)")
        }
    }

    private func sanitizeFilename(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-_"))
        let scalars = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let trimmed = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "agent" : trimmed
    }

    // MARK: - Tar (shell out to `/usr/bin/tar`)

    /// `Process`-based tar. We avoid pulling in a zip dependency for the
    /// MVP — tar is already on every macOS install and the bundle is
    /// small (db.sqlite is the bulk). Format is uncompressed `.tar` even
    /// though the extension is `.osaurus-agent`; future versions can
    /// switch to `tar.gz` without changing the format version because
    /// `untar` autodetects.
    private func tarDirectory(_ dir: URL, into bundle: URL) async throws {
        try? FileManager.default.removeItem(at: bundle)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-cf", bundle.path, "-C", dir.path, "."]
        try await runProcess(process, errorContext: "tar")
    }

    private func untar(_ bundle: URL, into dir: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        // `-xf` autodetects gzip / bzip2 / plain so a future .tar.gz
        // bundle still imports cleanly here.
        process.arguments = ["-xf", bundle.path, "-C", dir.path]
        try await runProcess(process, errorContext: "untar")
    }

    private func runProcess(_ process: Process, errorContext: String) async throws {
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()
        do {
            try process.run()
        } catch {
            throw AgentBundleError.archiveFailed("\(errorContext) launch: \(error.localizedDescription)")
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in c.resume() }
        }
        guard process.terminationStatus == 0 else {
            let stderr = (try? errorPipe.fileHandleForReading.readToEnd()) ?? Data()
            let msg = String(data: stderr, encoding: .utf8) ?? "exit \(process.terminationStatus)"
            throw AgentBundleError.archiveFailed("\(errorContext): \(msg)")
        }
    }
}
