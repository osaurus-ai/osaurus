//
//  ToolsInstall.swift
//  osaurus
//
//  Command to install a plugin from a URL, local path, or registry.
//

import CryptoKit
import Foundation
import OsaurusRepository

public struct ToolsInstall {
    public static func execute(args: [String]) async {
        guard let src = args.first, !src.isEmpty else {
            fputs(
                "Usage: osaurus tools install <plugin_id|url-or-path> [--version <semver>] [--consent]\n",
                stderr
            )
            exit(EXIT_FAILURE)
        }

        // Check if argument is a local path or URL
        if isManualInstallSource(src) {
            // Manual sideloads bypass the registry's checksum/signature
            // verification, so the release loader's `.user_consent` gate is
            // NOT waived implicitly: pass `--consent` to grant it at install
            // time, otherwise approve the plugin in Osaurus settings.
            let grantConsent = args.contains("--consent")
            await installManual(src: src, grantConsent: grantConsent)
        } else {
            await installFromRegistry(pluginId: src, args: args)
        }
    }

    static func isManualInstallSource(_ src: String) -> Bool {
        src == "."
            || src == ".."
            || src.hasPrefix("/")
            || src.hasPrefix("./")
            || src.hasPrefix("../")
            || src.hasPrefix("http://")
            || src.hasPrefix("https://")
    }

    private static func installFromRegistry(pluginId: String, args: [String]) async {
        var preferredVersion: SemanticVersion?
        if let idx = args.firstIndex(of: "--version"), idx + 1 < args.count {
            let vstr = args[idx + 1]
            preferredVersion = SemanticVersion.parse(vstr)
            if preferredVersion == nil {
                fputs("Invalid semver: \(vstr)\n", stderr)
                exit(EXIT_FAILURE)
            }
        }
        do {
            let result = try await PluginInstallManager.shared.install(
                pluginId: pluginId,
                preferredVersion: preferredVersion
            )
            print(
                "Installed \(result.receipt.plugin_id) @ \(result.receipt.version) to \(result.installDirectory.path)"
            )
            // Notify app to reload tools
            AppControl.postDistributedNotification(name: "com.dinoki.osaurus.control.toolsReload", userInfo: [:])
            exit(EXIT_SUCCESS)
        } catch {
            fputs("Install failed: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func installManual(src: String, grantConsent: Bool) async {
        let fm = FileManager.default
        // Create a temporary staging directory
        let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        } catch {
            fputs("Failed to create temp directory: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }

        defer {
            try? fm.removeItem(at: tmpDir)
        }

        // Track the source name for parsing plugin_id and version
        var sourceName: String = ""
        var preferManifestIdentity = false

        // 1. Unpack/Copy to staging. Archives go through the same bounded
        // in-process extractor as registry installs (path-safety, resource
        // limits) instead of shelling out to /usr/bin/unzip, and remote
        // archives are streamed to disk instead of buffered in memory.
        let stageRoot = tmpDir.appendingPathComponent("extracted", isDirectory: true)
        if src.hasPrefix("http://") || src.hasPrefix("https://") {
            guard let url = URL(string: src) else {
                fputs("Invalid URL: \(src)\n", stderr)
                exit(EXIT_FAILURE)
            }
            // Extract filename from URL path
            sourceName = url.lastPathComponent
            let zipFile = tmpDir.appendingPathComponent("download.zip")
            do {
                let (downloadedURL, resp) = try await URLSession.shared.download(from: url)
                guard let http = resp as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
                    try? fm.removeItem(at: downloadedURL)
                    fputs("Download failed (status \((resp as? HTTPURLResponse)?.statusCode ?? -1))\n", stderr)
                    exit(EXIT_FAILURE)
                }
                try fm.moveItem(at: downloadedURL, to: zipFile)
                try PluginInstallManager.extractPluginArchive(at: zipFile, to: stageRoot)
            } catch {
                fputs("Download/Unzip error: \(error)\n", stderr)
                exit(EXIT_FAILURE)
            }
        } else {
            let pathURL = URL(fileURLWithPath: src)
            sourceName = pathURL.deletingPathExtension().lastPathComponent
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: pathURL.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    preferManifestIdentity = true
                    // Copy contents to the staging root
                    do {
                        try fm.createDirectory(at: stageRoot, withIntermediateDirectories: true)
                        let contents = try fm.contentsOfDirectory(at: pathURL, includingPropertiesForKeys: nil)
                        for item in contents {
                            try fm.copyItem(at: item, to: stageRoot.appendingPathComponent(item.lastPathComponent))
                        }
                    } catch {
                        fputs("Failed to copy directory: \(error)\n", stderr)
                        exit(EXIT_FAILURE)
                    }
                } else if pathURL.pathExtension.lowercased() == "zip" {
                    do {
                        try PluginInstallManager.extractPluginArchive(at: pathURL, to: stageRoot)
                    } catch {
                        fputs("Unzip error: \(error)\n", stderr)
                        exit(EXIT_FAILURE)
                    }
                } else {
                    fputs("Unsupported file type: \(src)\n", stderr)
                    exit(EXIT_FAILURE)
                }
            } else {
                fputs("Path not found: \(src)\n", stderr)
                exit(EXIT_FAILURE)
            }
        }

        // Find the plugin root (the archive might contain a wrapper directory)
        var pluginRoot: URL = stageRoot
        do {
            let contents = try fm.contentsOfDirectory(
                at: stageRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            // If there's a single subdirectory, use it as the plugin root
            if contents.count == 1, contents[0].hasDirectoryPath {
                pluginRoot = contents[0]
            }
        } catch {
            // ignore - use stageRoot as root
        }

        // 2. Resolve plugin_id and version. Packaged zips keep using
        // `<plugin_id>-<version>.zip`; direct project installs such as
        // `osaurus tools install .` fall back to the scaffold's lightweight
        // `osaurus-plugin.json` (`plugin_id` + `version`).
        let pluginId: String
        let semver: SemanticVersion
        do {
            let identity = try resolveManualInstallIdentity(
                sourceName: sourceName,
                pluginRoot: pluginRoot,
                preferManifestIdentity: preferManifestIdentity
            )
            pluginId = identity.pluginId
            semver = identity.version
            let warnings = try validateBundledManifestIfPresent(in: pluginRoot, identity: identity)
            for warning in warnings {
                fputs("  ! \(warning)\n", stderr)
            }
        } catch {
            fputs("\(error)\n", stderr)
            exit(EXIT_FAILURE)
        }

        // 3. Publish the staged payload to Tools/<id>/<version>
        do {
            let installDir = try publishManualInstall(
                pluginRoot: pluginRoot,
                pluginId: pluginId,
                version: semver,
                grantConsent: grantConsent
            )

            print("Installed \(pluginId) @ \(semver) to \(installDir.path)")
            if !grantConsent {
                print(
                    "Consent NOT granted. Approve in Osaurus settings before the plugin will load, or reinstall with --consent."
                )
            }

            // Notify app
            AppControl.postDistributedNotification(name: "com.dinoki.osaurus.control.toolsReload", userInfo: [:])
            exit(EXIT_SUCCESS)

        } catch {
            fputs("Installation failed: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    /// Completes the staged payload (receipt + optional consent marker) and
    /// then publishes it into `Tools/<id>/<version>` in one atomic swap. Any
    /// previously installed copy of this version is only replaced by a
    /// complete, valid layout — never deleted up front, so a failure while
    /// preparing the new payload leaves the existing install untouched.
    /// Fails (before touching the destination) when the payload contains no
    /// dylib, so a manual install can no longer produce a receipt-less or
    /// binary-less tree.
    static func publishManualInstall(
        pluginRoot: URL,
        pluginId: String,
        version: SemanticVersion,
        grantConsent: Bool
    ) throws -> URL {
        let fm = FileManager.default
        let installDir = PluginInstallManager.toolsVersionDirectory(pluginId: pluginId, version: version)

        try createManualInstallReceipt(pluginId: pluginId, version: version, installDir: pluginRoot)
        if grantConsent {
            try Data().write(to: pluginRoot.appendingPathComponent(".user_consent", isDirectory: false))
        }

        let parent = installDir.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)

        // Move the payload next to its final location first (the temp dir may
        // be on another volume), then swap it in atomically.
        let staging = parent.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.moveItem(at: pluginRoot, to: staging)
        do {
            if fm.fileExists(atPath: installDir.path) {
                _ = try fm.replaceItemAt(installDir, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: installDir)
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }

        try PluginInstallManager.updateCurrentSymlink(pluginId: pluginId, version: version)
        return installDir
    }

    /// Parses plugin_id and version from a filename like "my-plugin-1.0.0" or "my-plugin-1.0.0.zip"
    /// Returns nil if the format is invalid.
    private static func parsePluginIdAndVersion(from name: String) -> (pluginId: String, version: SemanticVersion)? {
        // Remove .zip extension if present
        var baseName = name
        if baseName.lowercased().hasSuffix(".zip") {
            baseName = String(baseName.dropLast(4))
        }

        // Find the last occurrence of a version pattern (e.g., -1.0.0, -1.2.3-beta)
        // We scan from the end to find where the version starts
        let parts = baseName.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }

        // Try to find a valid semver by joining parts from the end
        // Version could be "1.0.0" or "1.0.0-beta" etc.
        for i in (1 ..< parts.count).reversed() {
            let potentialVersion = parts[i...].joined(separator: "-")
            if let semver = SemanticVersion.parse(potentialVersion) {
                let pluginId = parts[0 ..< i].joined(separator: "-")
                if !pluginId.isEmpty {
                    return (pluginId, semver)
                }
            }
        }

        return nil
    }

    struct ManualInstallIdentity: Equatable {
        enum Source: Equatable {
            case filename
            case manifest(String)
        }

        let pluginId: String
        let version: SemanticVersion
        let source: Source
    }

    static func resolveManualInstallIdentity(
        sourceName: String,
        pluginRoot: URL,
        preferManifestIdentity: Bool = false
    ) throws -> ManualInstallIdentity {
        if preferManifestIdentity, let manifest = try readResolvedManualInstallManifest(in: pluginRoot) {
            return manifest
        }

        if let parsed = parsePluginIdAndVersion(from: sourceName) {
            return ManualInstallIdentity(pluginId: parsed.pluginId, version: parsed.version, source: .filename)
        }

        guard let manifest = try readResolvedManualInstallManifest(in: pluginRoot) else {
            throw ManualInstallError.identityUnavailable(sourceName: sourceName)
        }
        return manifest
    }

    private static func readResolvedManualInstallManifest(in pluginRoot: URL) throws -> ManualInstallIdentity? {
        guard let manifest = try readManualInstallManifest(in: pluginRoot) else {
            return nil
        }
        guard !manifest.pluginId.isEmpty else {
            throw ManualInstallError.invalidManifestField(manifest.filename, "plugin_id")
        }
        guard let versionString = manifest.version, !versionString.isEmpty else {
            throw ManualInstallError.invalidManifestField(manifest.filename, "version")
        }
        guard let version = SemanticVersion.parse(versionString) else {
            throw ManualInstallError.invalidManifestVersion(manifest.filename, versionString)
        }
        return ManualInstallIdentity(pluginId: manifest.pluginId, version: version, source: .manifest(manifest.filename))
    }

    static func validateBundledManifestIfPresent(
        in pluginRoot: URL,
        identity: ManualInstallIdentity
    ) throws -> [String] {
        let fm = FileManager.default
        for candidate in manifestCandidates {
            let manifestURL = pluginRoot.appendingPathComponent(candidate)
            guard fm.fileExists(atPath: manifestURL.path) else { continue }
            let data: Data
            do {
                data = try Data(contentsOf: manifestURL)
            } catch {
                throw ManualInstallError.manifestReadFailed(candidate, error.localizedDescription)
            }

            if candidate == "osaurus-plugin.json", manifestObject(from: data)?["capabilities"] == nil {
                if identity.source == .manifest(candidate) {
                    continue
                }
                throw ManualInstallError.manifestValidationFailed(candidate, ["`capabilities` is required."])
            }

            if let manifest = try readManifestIdentity(data: data, filename: candidate) {
                try validateManifestIdentity(manifest, matches: identity)
            }

            let report = ManifestValidate.validate(data: data)
            if !report.errors.isEmpty {
                throw ManualInstallError.manifestValidationFailed(candidate, report.errors)
            }
            if let summary = report.summary {
                try validateManifestSummary(summary, filename: candidate, matches: identity)
            }
            return report.warnings
        }
        return []
    }

    private static func validateManifestSummary(
        _ summary: ManifestValidate.Report.Summary,
        filename: String,
        matches identity: ManualInstallIdentity
    ) throws {
        guard summary.pluginId == identity.pluginId else {
            throw ManualInstallError.manifestIdentityMismatch(filename, summary.pluginId, identity.pluginId)
        }
        guard let versionString = summary.version, !versionString.isEmpty else { return }
        guard let version = SemanticVersion.parse(versionString) else {
            throw ManualInstallError.invalidManifestVersion(filename, versionString)
        }
        guard version == identity.version else {
            throw ManualInstallError.manifestVersionMismatch(filename, versionString, identity.version.description)
        }
    }

    private static func validateManifestIdentity(
        _ manifest: ManualInstallManifest,
        matches identity: ManualInstallIdentity
    ) throws {
        guard manifest.pluginId == identity.pluginId else {
            throw ManualInstallError.manifestIdentityMismatch(manifest.filename, manifest.pluginId, identity.pluginId)
        }
        guard let versionString = manifest.version, !versionString.isEmpty else { return }
        guard let version = SemanticVersion.parse(versionString) else {
            throw ManualInstallError.invalidManifestVersion(manifest.filename, versionString)
        }
        guard version == identity.version else {
            throw ManualInstallError.manifestVersionMismatch(
                manifest.filename,
                versionString,
                identity.version.description
            )
        }
    }

    private static func readManifestIdentity(data: Data, filename: String) throws -> ManualInstallManifest? {
        guard let obj = manifestObject(from: data) else {
            throw ManualInstallError.manifestValidationFailed(filename, ["Top-level JSON must be an object."])
        }
        guard obj["plugin_id"] != nil || obj["version"] != nil else { return nil }
        return ManualInstallManifest(
            filename: filename,
            pluginId: (obj["plugin_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            version: (obj["version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static let manifestCandidates = ["osaurus-plugin.json", "plugin.json", "manifest.json"]

    private struct ManualInstallManifest {
        let filename: String
        let pluginId: String
        let version: String?
    }

    private static func readManualInstallManifest(in pluginRoot: URL) throws -> ManualInstallManifest? {
        let fm = FileManager.default
        for candidate in manifestCandidates {
            let manifestURL = pluginRoot.appendingPathComponent(candidate)
            guard fm.fileExists(atPath: manifestURL.path) else { continue }
            let data: Data
            do {
                data = try Data(contentsOf: manifestURL)
            } catch {
                throw ManualInstallError.manifestReadFailed(candidate, error.localizedDescription)
            }
            guard let obj = manifestObject(from: data) else {
                throw ManualInstallError.manifestValidationFailed(candidate, ["Top-level JSON must be an object."])
            }
            return ManualInstallManifest(
                filename: candidate,
                pluginId: (obj["plugin_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                version: (obj["version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return nil
    }

    private static func manifestObject(from data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
    }

    enum ManualInstallError: Error, CustomStringConvertible {
        case identityUnavailable(sourceName: String)
        case noDylibFound
        case invalidManifestField(String, String)
        case invalidManifestVersion(String, String)
        case manifestReadFailed(String, String)
        case manifestValidationFailed(String, [String])
        case manifestIdentityMismatch(String, String, String)
        case manifestVersionMismatch(String, String, String)

        var description: String {
            switch self {
            case .identityUnavailable:
                return
                    "Invalid naming format. Expected <plugin_id>-<version>.zip, or install a project directory containing osaurus-plugin.json with plugin_id and version."
            case .noDylibFound:
                return
                    "No .dylib found in the plugin payload. Build the plugin first (e.g. `osaurus tools build`) — an install without a binary would produce a broken receipt-less tree."
            case .invalidManifestField(let filename, let field):
                return "`\(filename)` must include a non-empty `\(field)` for directory installs."
            case .invalidManifestVersion(let filename, let value):
                return "`\(filename)` has invalid semantic version `\(value)`."
            case .manifestReadFailed(let filename, let message):
                return "Failed to read \(filename): \(message)"
            case .manifestValidationFailed(let filename, let errors):
                return "Manifest validation failed (\(filename)):\n" + errors.map { "  - \($0)" }.joined(separator: "\n")
            case .manifestIdentityMismatch(let filename, let actual, let expected):
                return "`\(filename)` declares plugin_id `\(actual)`, but install target is `\(expected)`."
            case .manifestVersionMismatch(let filename, let actual, let expected):
                return "`\(filename)` declares version `\(actual)`, but install target is `\(expected)`."
            }
        }
    }

    /// Creates a receipt.json for manual installations. Throws when the
    /// payload contains no dylib: the loader requires receipt + binary, so
    /// silently skipping the receipt used to publish an install that could
    /// never load (and that `tools verify` then ignored).
    static func createManualInstallReceipt(pluginId: String, version: SemanticVersion, installDir: URL) throws {
        guard let dylibURL = findFirstDylib(in: installDir) else {
            throw ManualInstallError.noDylibFound
        }

        // Calculate SHA256 of the dylib
        let dylibData = try Data(contentsOf: dylibURL)
        let digest = SHA256.hash(data: dylibData)
        let dylibSha = Data(digest).map { String(format: "%02x", $0) }.joined()

        let receipt = PluginReceipt(
            plugin_id: pluginId,
            version: version,
            installed_at: Date(),
            dylib_filename: dylibURL.lastPathComponent,
            dylib_sha256: dylibSha,
            platform: "macos",
            arch: "arm64",
            public_keys: nil,
            artifact: .init(
                url: dylibURL.absoluteString,
                sha256: dylibSha,
                minisign: nil,
                size: dylibData.count
            )
        )

        let receiptURL = installDir.appendingPathComponent("receipt.json")
        let receiptData = try JSONEncoder().encode(receipt)
        try receiptData.write(to: receiptURL)
    }

    private static func findFirstDylib(in directory: URL) -> URL? {
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
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "dylib" {
            return fileURL
        }
        return nil
    }
}
