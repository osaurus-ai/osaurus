//
//  PluginInstallManager.swift
//  osaurus
//
//  Handles plugin installation workflow including download, verification, extraction, and receipt generation.
//

import Foundation
import CryptoKit

public enum PluginInstallError: Error, CustomStringConvertible, LocalizedError {
    case specNotFound(String)
    case resolutionFailed(String)
    case downloadFailed(String)
    case checksumMismatch
    case signatureRequired
    case signatureInvalid
    case authorKeyMismatch
    case unzipFailed(String)
    case layoutInvalid(String)

    public var description: String {
        switch self {
        case .specNotFound(let id): return "Spec not found: \(id)"
        case .resolutionFailed(let msg): return "Resolution failed: \(msg)"
        case .downloadFailed(let msg): return "Download failed: \(msg)"
        case .checksumMismatch: return "Checksum mismatch"
        case .signatureRequired: return "Plugin requires a minisign signature for installation"
        case .signatureInvalid: return "Signature verification failed"
        case .authorKeyMismatch:
            return
                "The signing key for this plugin has changed. Uninstall the plugin and reinstall it to accept the new key."
        case .unzipFailed(let msg): return "Unzip failed: \(msg)"
        case .layoutInvalid(let msg): return "Invalid artifact layout: \(msg)"
        }
    }

    public var errorDescription: String? { description }
}

public final class PluginInstallManager: @unchecked Sendable {
    public static let shared = PluginInstallManager()
    /// Plugin archives should stay small enough that signature verification can map the file
    /// safely while still blocking accidental or malicious multi-gigabyte installs.
    static let maximumArtifactArchiveBytes: Int64 = 256 * 1024 * 1024
    static let hashReadChunkBytes = 1024 * 1024
    static let unzipExecutablePath = "/usr/bin/unzip"
    private init() {}

    public struct InstallResult: Sendable {
        public let receipt: PluginReceipt
        public let installDirectory: URL
        public let dylibURL: URL
        /// SKILL.md files found in the artifact and copied to the install directory
        public let skillFiles: [URL]
    }

    @discardableResult
    public func install(pluginId: String, preferredVersion: SemanticVersion? = nil) async throws -> InstallResult {
        let refreshed = CentralRepositoryManager.shared.refresh()
        guard let spec = CentralRepositoryManager.shared.spec(for: pluginId) else {
            if !refreshed {
                throw PluginInstallError.specNotFound("\(pluginId) (registry unavailable)")
            }
            throw PluginInstallError.specNotFound(pluginId)
        }

        // TOFU: when the author's signing key changes, the new artifact is verified against
        // the updated key from the registry. We capture the prior version here so we can
        // remove it *after* the new install + symlink swap succeed. Eagerly deleting it now
        // would leave the user with no installed version (and a dangling `current` symlink)
        // if any later step throws (network, checksum, signature, unzip).
        let keyRotatedFromVersion: SemanticVersion? = {
            guard let latest = InstalledPluginsStore.shared.latestInstalledVersion(pluginId: spec.plugin_id),
                let existing = InstalledPluginsStore.shared.receipt(pluginId: spec.plugin_id, version: latest),
                let existingKey = existing.public_keys?["minisign"],
                let newKey = spec.public_keys?["minisign"],
                existingKey != newKey
            else { return nil }
            NSLog(
                "[Osaurus] Signing key changed for %@ — will remove old version %@ after new install succeeds",
                spec.plugin_id,
                latest.description
            )
            return latest
        }()

        let targetPlatform: Platform = .macos
        // Arm64 only per project policy
        let targetArch: CPUArch = .arm64

        let resolution: PluginResolution
        do {
            resolution = try spec.resolveBestVersion(
                targetPlatform: targetPlatform,
                targetArch: targetArch,
                minimumOsaurusVersion: nil,
                preferredVersion: preferredVersion
            )
        } catch {
            throw PluginInstallError.resolutionFailed("\(error)")
        }

        let artifact = resolution.artifact
        guard artifact.arch == CPUArch.arm64.rawValue else {
            throw PluginInstallError.resolutionFailed(
                "No arm64 artifact for \(pluginId) @ \(resolution.version.version)"
            )
        }
        guard let url = URL(string: artifact.url) else {
            throw PluginInstallError.downloadFailed("Invalid URL: \(artifact.url)")
        }

        let tmpZip = try await download(toTempFileFrom: url, declaredSize: artifact.size)
        defer { try? FileManager.default.removeItem(at: tmpZip) }

        let checksum = try Self.sha256Hex(ofFile: tmpZip)
        if checksum.lowercased() != artifact.sha256.lowercased() {
            throw PluginInstallError.checksumMismatch
        }

        guard let ms = artifact.minisign, let pubKey = spec.public_keys?["minisign"] else {
            throw PluginInstallError.signatureRequired
        }
        do {
            let bytes = try Self.mappedFileData(at: tmpZip)
            _ = try MinisignVerifier.verify(publicKey: pubKey, signature: ms.signature, data: bytes)
        } catch {
            NSLog("[Osaurus] Minisign verification failed for \(pluginId): \(error)")
            throw PluginInstallError.signatureInvalid
        }
        NSLog("[Osaurus] Minisign signature verified for \(pluginId)")

        let tmpDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        try unzip(zipURL: tmpZip, to: tmpDir)

        guard let dylibURL = findFirstDylib(in: tmpDir) else {
            throw PluginInstallError.layoutInvalid("No .dylib found in archive")
        }

        let installDir = PluginInstallManager.toolsVersionDirectory(
            pluginId: spec.plugin_id,
            version: resolution.version.version
        )
        try ensureDirectoryExists(installDir)
        let finalDylibURL = installDir.appendingPathComponent(dylibURL.lastPathComponent, isDirectory: false)
        if FileManager.default.fileExists(atPath: finalDylibURL.path) {
            try FileManager.default.removeItem(at: finalDylibURL)
        }
        try FileManager.default.copyItem(at: dylibURL, to: finalDylibURL)

        // Copy any SKILL.md files found in the artifact
        let skillFileURLs = findSkillFiles(in: tmpDir)
        var installedSkillFiles: [URL] = []
        if !skillFileURLs.isEmpty {
            let skillsDir = installDir.appendingPathComponent("skills", isDirectory: true)
            try ensureDirectoryExists(skillsDir)
            for skillURL in skillFileURLs {
                // Use parent directory name as prefix for disambiguation, or just the filename
                let relativePath = skillURL.deletingLastPathComponent().lastPathComponent
                let destName: String
                if relativePath != tmpDir.lastPathComponent && relativePath != "skills" {
                    destName = "\(relativePath)_SKILL.md"
                } else {
                    destName = "SKILL.md"
                }
                let destURL = skillsDir.appendingPathComponent(destName, isDirectory: false)
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.copyItem(at: skillURL, to: destURL)
                installedSkillFiles.append(destURL)
                NSLog("[Osaurus] Installed SKILL.md for plugin \(pluginId): \(destName)")
            }
        }

        // Copy documentation files (README.md, CHANGELOG.md) from the artifact
        for docName in ["README.md", "CHANGELOG.md"] {
            if let docURL = findDocFile(named: docName, in: tmpDir) {
                let destURL = installDir.appendingPathComponent(docName, isDirectory: false)
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.copyItem(at: docURL, to: destURL)
                NSLog("[Osaurus] Installed \(docName) for plugin \(pluginId)")
            }
        }

        let dylibSha = try Self.sha256Hex(ofFile: finalDylibURL)

        let receipt = PluginReceipt(
            plugin_id: spec.plugin_id,
            version: resolution.version.version,
            installed_at: Date(),
            dylib_filename: finalDylibURL.lastPathComponent,
            dylib_sha256: dylibSha,
            platform: targetPlatform.rawValue,
            arch: targetArch.rawValue,
            public_keys: spec.public_keys,
            artifact: .init(
                url: artifact.url,
                sha256: artifact.sha256,
                minisign: artifact.minisign,
                size: artifact.size
            )
        )
        let receiptURL = installDir.appendingPathComponent("receipt.json", isDirectory: false)
        let receiptData = try JSONEncoder().encode(receipt)
        try receiptData.write(to: receiptURL)

        // Auto-grant user consent for plugins installed through the verified flow
        let consentURL = installDir.appendingPathComponent(".user_consent", isDirectory: false)
        try Data().write(to: consentURL)

        try Self.updateCurrentSymlink(pluginId: spec.plugin_id, version: resolution.version.version)

        // Deferred TOFU cleanup: now that the new version is fully on disk and `current`
        // points at it, it's safe to remove the prior key-rotated version.
        if let old = keyRotatedFromVersion, old != resolution.version.version {
            let oldDir = PluginInstallManager.toolsVersionDirectory(pluginId: spec.plugin_id, version: old)
            try? FileManager.default.removeItem(at: oldDir)
            NSLog(
                "[Osaurus] Key rotated for %@ — removed prior version %@",
                spec.plugin_id,
                old.description
            )
        }

        return InstallResult(
            receipt: receipt,
            installDirectory: installDir,
            dylibURL: finalDylibURL,
            skillFiles: installedSkillFiles
        )
    }

    // MARK: - Paths
    public static func toolsRootDirectory() -> URL {
        return ToolsPaths.toolsRootDirectory()
    }

    public static func toolsPluginDirectory(pluginId: String) -> URL {
        toolsRootDirectory().appendingPathComponent(pluginId, isDirectory: true)
    }

    public static func toolsVersionDirectory(pluginId: String, version: SemanticVersion) -> URL {
        toolsPluginDirectory(pluginId: pluginId).appendingPathComponent(version.description, isDirectory: true)
    }

    public static func currentSymlinkURL(pluginId: String) -> URL {
        toolsPluginDirectory(pluginId: pluginId).appendingPathComponent("current", isDirectory: false)
    }

    /// Scans the tools root and repairs any dangling `current` symlink left behind by a
    /// crashed/aborted install or a TOFU key rotation that pre-dates the atomic-swap fix.
    ///
    /// For each plugin directory:
    /// - If `current` resolves to an existing target, leave it alone.
    /// - If `current` is dangling and other valid versions exist on disk, repoint it to
    ///   the highest installed version.
    /// - If `current` is dangling and no valid versions exist, remove the orphan link.
    ///
    /// Idempotent and cheap (one `readlink` + one `stat` per plugin). Safe to call on every
    /// app launch.
    public static func repairDanglingCurrentSymlinks() {
        let fm = FileManager.default
        let root = ToolsPaths.toolsRootDirectory()
        guard
            let entries = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return }

        for pluginDir in entries where pluginDir.hasDirectoryPath {
            let pluginId = pluginDir.lastPathComponent
            let link = currentSymlinkURL(pluginId: pluginId)

            // Only act on entries that are actually symlinks. `destinationOfSymbolicLink`
            // returns nil for missing entries and for non-symlink entries (it throws), which
            // we catch via `try?`.
            guard let dest = try? fm.destinationOfSymbolicLink(atPath: link.path) else { continue }

            let target = pluginDir.appendingPathComponent(dest, isDirectory: true)
            if fm.fileExists(atPath: target.path) { continue }  // healthy

            if let fallback = InstalledPluginsStore.shared.installedVersions(pluginId: pluginId).first {
                do {
                    try updateCurrentSymlink(pluginId: pluginId, version: fallback)
                    NSLog(
                        "[Osaurus] Repaired dangling 'current' for %@ → %@",
                        pluginId,
                        fallback.description
                    )
                } catch {
                    NSLog(
                        "[Osaurus] Failed to repair dangling 'current' for %@: %@",
                        pluginId,
                        String(describing: error)
                    )
                }
            } else {
                try? fm.removeItem(at: link)
                NSLog(
                    "[Osaurus] Removed dangling 'current' for %@ (no installed versions found)",
                    pluginId
                )
            }
        }
    }

    public static func updateCurrentSymlink(pluginId: String, version: SemanticVersion) throws {
        let fm = FileManager.default
        let link = currentSymlinkURL(pluginId: pluginId)
        let dir = toolsPluginDirectory(pluginId: pluginId)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Remove any existing entry (regular file, live symlink, or dangling
        // symlink). `fileExists` follows symlinks and reports a dangling link
        // as missing, but `createSymbolicLink` would still fail with EEXIST.
        // `try?` is intentional: nothing-to-remove is fine; if the entry truly
        // cannot be replaced, `createSymbolicLink` will surface the error.
        try? fm.removeItem(at: link)
        do {
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: version.description)
        } catch {
            throw PluginInstallError.layoutInvalid(
                "Could not refresh 'current' symlink for \(pluginId) → \(version.description): \(error). Try reinstalling the plugin."
            )
        }
    }

    private func ensureDirectoryExists(_ url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    // MARK: - Download / unzip
    private func download(toTempFileFrom url: URL, declaredSize: Int?) async throws -> URL {
        let boundedDeclaredSize = try Self.validatedDeclaredArtifactSize(declaredSize)
        let (downloadedURL, response) = try await RepositoryGlobalProxySettings.sharedSession().download(from: url)
        var movedDownloadedFile = false
        defer {
            if !movedDownloadedFile {
                try? FileManager.default.removeItem(at: downloadedURL)
            }
        }
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw PluginInstallError.downloadFailed("HTTP error")
        }
        try Self.validateArtifactSize(
            declaredSize: boundedDeclaredSize,
            responseSize: http.expectedContentLength >= 0 ? http.expectedContentLength : nil,
            actualSize: nil
        )
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        do {
            try FileManager.default.moveItem(at: downloadedURL, to: tmp)
            movedDownloadedFile = true
            let actualSize = try Self.fileSize(at: tmp)
            try Self.validateArtifactSize(
                declaredSize: boundedDeclaredSize,
                responseSize: nil,
                actualSize: actualSize
            )
            return tmp
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    /// Use the system unzip binary directly so plugin installation does not depend on
    /// a user-controlled PATH lookup through `/usr/bin/env`.
    private func unzip(zipURL: URL, to destination: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: Self.unzipExecutablePath)
        task.arguments = ["-o", "-q", zipURL.path, "-d", destination.path]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let s = String(data: data, encoding: .utf8) ?? ""
            throw PluginInstallError.unzipFailed(s)
        }
    }

    /// Normalizes registry-provided sizes before download so a malformed catalog cannot
    /// request an archive that exceeds the installer resource budget.
    static func validatedDeclaredArtifactSize(_ declaredSize: Int?) throws -> Int64? {
        guard let declaredSize else { return nil }
        guard declaredSize >= 0 else {
            throw PluginInstallError.downloadFailed("Artifact declared a negative size")
        }
        let normalized = Int64(declaredSize)
        guard normalized <= maximumArtifactArchiveBytes else {
            throw PluginInstallError.downloadFailed(
                "Artifact is larger than the \(maximumArtifactArchiveBytes)-byte install limit"
            )
        }
        return normalized
    }

    /// Checks each size signal independently because registries, HTTP headers, and the
    /// downloaded file are observed at different points in the install trust boundary.
    static func validateArtifactSize(declaredSize: Int64?, responseSize: Int64?, actualSize: Int64?) throws {
        if let responseSize, responseSize > maximumArtifactArchiveBytes {
            throw PluginInstallError.downloadFailed(
                "Artifact response is larger than the \(maximumArtifactArchiveBytes)-byte install limit"
            )
        }
        if let actualSize, actualSize > maximumArtifactArchiveBytes {
            throw PluginInstallError.downloadFailed(
                "Artifact archive is larger than the \(maximumArtifactArchiveBytes)-byte install limit"
            )
        }
        if let declaredSize, let responseSize, declaredSize != responseSize {
            throw PluginInstallError.downloadFailed(
                "Artifact response size mismatch: expected \(declaredSize) bytes, got \(responseSize)"
            )
        }
        if let declaredSize, let actualSize, declaredSize != actualSize {
            throw PluginInstallError.downloadFailed(
                "Artifact archive size mismatch: expected \(declaredSize) bytes, got \(actualSize)"
            )
        }
    }

    /// Hash from disk so the archive download path stays bounded by chunk size instead of
    /// copying the entire zip into process memory before checksum validation.
    static func sha256Hex(ofFile url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: hashReadChunkBytes) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize()).map { String(format: "%02x", $0) }.joined()
    }

    static func fileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize else {
            throw PluginInstallError.downloadFailed("Could not determine artifact archive size")
        }
        return Int64(fileSize)
    }

    static func mappedFileData(at url: URL) throws -> Data {
        try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private func makeTempDirectory() throws -> URL {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
        let dir = base.appendingPathComponent("osaurus-plugin-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Finds a documentation file (case-insensitive) in the extracted archive directory
    private func findDocFile(named filename: String, in directory: URL) -> URL? {
        let fm = FileManager.default
        guard
            let enumerator = fm.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return nil
        }
        let target = filename.lowercased()
        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent.lowercased() == target && Self.isRegularPayloadFile(fileURL) {
                return fileURL
            }
        }
        return nil
    }

    /// Finds all SKILL.md files in the extracted archive directory
    private func findSkillFiles(in directory: URL) -> [URL] {
        let fm = FileManager.default
        guard
            let enumerator = fm.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }
        var results: [URL] = []
        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent.uppercased() == "SKILL.MD" && Self.isRegularPayloadFile(fileURL) {
                results.append(fileURL)
            }
        }
        return results
    }

    private func findFirstDylib(in directory: URL) -> URL? {
        let fm = FileManager.default
        guard
            let enumerator = fm.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return nil
        }
        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension == "dylib" && Self.isRegularPayloadFile(fileURL) {
                return fileURL
            }
        }
        return nil
    }

    /// Signed archives should contribute real files only; symlinked payload files would let
    /// an artifact point the installer at bytes outside the extracted archive tree.
    static func isRegularPayloadFile(_ url: URL) -> Bool {
        guard
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

}
