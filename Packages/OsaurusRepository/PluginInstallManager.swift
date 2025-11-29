//
//  PluginInstallManager.swift
//  osaurus
//
//  Handles plugin installation workflow including download, verification, extraction, and receipt generation.
//

import Foundation
import CryptoKit

public enum PluginInstallError: Error, CustomStringConvertible {
    case specNotFound(String)
    case resolutionFailed(String)
    case downloadFailed(String)
    case checksumMismatch
    case signatureInvalid
    case unzipFailed(String)
    case layoutInvalid(String)

    public var description: String {
        switch self {
        case .specNotFound(let id): return "Spec not found: \(id)"
        case .resolutionFailed(let msg): return "Resolution failed: \(msg)"
        case .downloadFailed(let msg): return "Download failed: \(msg)"
        case .checksumMismatch: return "Checksum mismatch"
        case .signatureInvalid: return "Signature verification failed"
        case .unzipFailed(let msg): return "Unzip failed: \(msg)"
        case .layoutInvalid(let msg): return "Invalid artifact layout: \(msg)"
        }
    }
}

public final class PluginInstallManager: @unchecked Sendable {
    public static let shared = PluginInstallManager()
    private init() {}

    public struct InstallResult: Sendable {
        public let receipt: PluginReceipt
        public let installDirectory: URL
        public let dylibURL: URL
    }

    @discardableResult
    public func install(pluginId: String, preferredVersion: SemanticVersion? = nil) async throws -> InstallResult {
        CentralRepositoryManager.shared.refresh()
        guard let spec = CentralRepositoryManager.shared.spec(for: pluginId) else {
            throw PluginInstallError.specNotFound(pluginId)
        }

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

        let (tmpZip, bytes) = try await download(toTempFileFrom: url)
        defer { try? FileManager.default.removeItem(at: tmpZip) }

        let digest = SHA256.hash(data: bytes)
        let checksum = Data(digest).map { String(format: "%02x", $0) }.joined()
        if checksum.lowercased() != artifact.sha256.lowercased() {
            throw PluginInstallError.checksumMismatch
        }

        // Verify minisign signature if provided (ensures plugin is from trusted author)
        if let ms = artifact.minisign, let pubKey = spec.public_keys?["minisign"] {
            do {
                let ok = try MinisignVerifier.verify(publicKey: pubKey, signature: ms.signature, data: bytes)
                if !ok {
                    throw PluginInstallError.signatureInvalid
                }
                NSLog("[Osaurus] Minisign signature verified for \(pluginId)")
            } catch let error as MinisignVerifyError {
                NSLog("[Osaurus] Minisign verification failed for \(pluginId): \(error)")
                throw PluginInstallError.signatureInvalid
            }
        }

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

        // Remove quarantine attribute so macOS allows loading the dylib
        Self.removeQuarantineAttribute(from: finalDylibURL)

        let dylibData = try Data(contentsOf: finalDylibURL)
        let dylibDigest = SHA256.hash(data: dylibData)
        let dylibSha = Data(dylibDigest).map { String(format: "%02x", $0) }.joined()

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

        try Self.updateCurrentSymlink(pluginId: spec.plugin_id, version: resolution.version.version)

        return InstallResult(receipt: receipt, installDirectory: installDir, dylibURL: finalDylibURL)
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

    public static func updateCurrentSymlink(pluginId: String, version: SemanticVersion) throws {
        let fm = FileManager.default
        let link = currentSymlinkURL(pluginId: pluginId)
        let dir = toolsPluginDirectory(pluginId: pluginId)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if fm.fileExists(atPath: link.path) {
            try fm.removeItem(at: link)
        }
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: version.description)
    }

    private func ensureDirectoryExists(_ url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    // MARK: - Download / unzip
    private func download(toTempFileFrom url: URL) async throws -> (fileURL: URL, data: Data) {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw PluginInstallError.downloadFailed("HTTP error")
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        try data.write(to: tmp)
        return (tmp, data)
    }

    private func unzip(zipURL: URL, to destination: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["unzip", "-o", zipURL.path, "-d", destination.path]
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

    private func makeTempDirectory() throws -> URL {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
        let dir = base.appendingPathComponent("osaurus-plugin-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
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
            if fileURL.pathExtension == "dylib" {
                return fileURL
            }
        }
        return nil
    }

    // MARK: - Quarantine removal

    /// Removes the com.apple.quarantine extended attribute from a file.
    /// This is necessary because downloaded files are quarantined by macOS,
    /// and dlopen() may fail to load quarantined dylibs even with disable-library-validation.
    private static func removeQuarantineAttribute(from url: URL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        task.arguments = ["-d", "com.apple.quarantine", url.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                NSLog("[Osaurus] Removed quarantine attribute from \(url.lastPathComponent)")
            }
            // Exit status non-zero is fine - means attribute wasn't present
        } catch {
            // Silently ignore - quarantine removal is best-effort
        }
    }
}
