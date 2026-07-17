//
//  PluginInstallIntegrityTests.swift
//  OsaurusRepository
//
//  Regression coverage for registry-install integrity:
//    - web/ assets survive the install (PACKAGING.md contract)
//    - exactly-one-dylib layout enforcement
//    - host / macOS minimum-version filtering during resolution
//    - fail-closed TOFU pinned-signing-key mismatch
//

import Foundation
import XCTest

@testable import OsaurusRepository

final class PluginInstallIntegrityTests: XCTestCase {
    private var tempRoot: URL!
    private var previousOverride: URL?
    private var previousDownloadOverride: (@Sendable (URL, URL) throws -> Void)?
    private var previousHostVersionOverride: SemanticVersion?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let fm = FileManager.default
        tempRoot = fm.temporaryDirectory.appendingPathComponent(
            "osaurus-install-integrity-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        previousOverride = ToolsPaths.overrideRoot
        ToolsPaths.overrideRoot = tempRoot
        previousDownloadOverride = CentralRepositoryManager.downloadFileOverride
        previousHostVersionOverride = PluginInstallManager.hostVersionOverrideForTesting
    }

    override func tearDownWithError() throws {
        ToolsPaths.overrideRoot = previousOverride
        CentralRepositoryManager.downloadFileOverride = previousDownloadOverride
        PluginInstallManager.hostVersionOverrideForTesting = previousHostVersionOverride
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func sv(_ s: String) -> SemanticVersion { SemanticVersion.parse(s)! }

    private func makeArtifact(minMacOS: String? = nil, url: String = "https://example.invalid/plugin.zip") -> PluginArtifact {
        PluginArtifact(
            os: "macos",
            arch: "arm64",
            min_macos: minMacOS,
            url: url,
            sha256: String(repeating: "0", count: 64),
            minisign: nil,
            size: 4
        )
    }

    private func makeVersionEntry(
        _ version: String,
        minOsaurus: String? = nil,
        artifacts: [PluginArtifact]? = nil
    ) -> PluginVersionEntry {
        PluginVersionEntry(
            version: sv(version),
            release_date: nil,
            notes: nil,
            artifacts: artifacts ?? [makeArtifact(url: "https://example.invalid/plugin-\(version).zip")],
            requires: minOsaurus.map { PluginRequirements(osaurus_min_version: sv($0)) }
        )
    }

    private func makeSpec(
        pluginId: String = "com.test.integrity",
        publicKey: String? = "RWTtestkey",
        versions: [PluginVersionEntry]
    ) -> PluginSpec {
        PluginSpec(
            plugin_id: pluginId,
            public_keys: publicKey.map { ["minisign": $0] },
            versions: versions
        )
    }

    private func writeReceipt(
        pluginId: String,
        version: String,
        minisignKey: String?
    ) throws {
        let semver = sv(version)
        let dir = PluginInstallManager.toolsVersionDirectory(pluginId: pluginId, version: semver)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let receipt = PluginReceipt(
            plugin_id: pluginId,
            version: semver,
            installed_at: Date(),
            dylib_filename: "Plugin.dylib",
            dylib_sha256: String(repeating: "0", count: 64),
            platform: "macos",
            arch: "arm64",
            public_keys: minisignKey.map { ["minisign": $0] },
            artifact: .init(
                url: "https://example.invalid/\(pluginId)-\(version).zip",
                sha256: String(repeating: "0", count: 64),
                minisign: nil,
                size: 0
            )
        )
        try JSONEncoder().encode(receipt)
            .write(to: dir.appendingPathComponent("receipt.json", isDirectory: false))
    }

    /// Seeds the on-disk registry cache with `spec` and blocks all registry
    /// network refreshes so `install()` resolves entirely offline.
    private func seedRegistryCache(with spec: PluginSpec) throws {
        let pluginsDir = ToolsPaths.pluginSpecsRoot()
            .appendingPathComponent("central", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        try JSONEncoder().encode(spec)
            .write(to: pluginsDir.appendingPathComponent("\(spec.plugin_id).json", isDirectory: false))
        CentralRepositoryManager.downloadFileOverride = { _, _ in
            throw URLError(.notConnectedToInternet)
        }
    }

    // MARK: - Version resolution: osaurus_min_version

    func test_resolveBestVersion_skipsVersionsRequiringNewerHost() throws {
        let spec = makeSpec(versions: [
            makeVersionEntry("2.0.0", minOsaurus: "9.0.0"),
            makeVersionEntry("1.0.0"),
        ])

        let resolution = try spec.resolveBestVersion(
            targetPlatform: .macos,
            targetArch: .arm64,
            minimumOsaurusVersion: sv("1.2.3")
        )

        XCTAssertEqual(resolution.version.version, sv("1.0.0"))
    }

    func test_resolveBestVersion_failsWhenEveryVersionRequiresNewerHost() {
        let spec = makeSpec(versions: [
            makeVersionEntry("2.0.0", minOsaurus: "9.0.0")
        ])

        XCTAssertThrowsError(
            try spec.resolveBestVersion(
                targetPlatform: .macos,
                targetArch: .arm64,
                minimumOsaurusVersion: sv("1.2.3")
            )
        )
    }

    func test_resolveBestVersion_unknownHostVersionFailsOpen() throws {
        let spec = makeSpec(versions: [
            makeVersionEntry("2.0.0", minOsaurus: "9.0.0")
        ])

        let resolution = try spec.resolveBestVersion(
            targetPlatform: .macos,
            targetArch: .arm64,
            minimumOsaurusVersion: nil
        )

        XCTAssertEqual(resolution.version.version, sv("2.0.0"))
    }

    // MARK: - Version resolution: artifact min_macos

    func test_resolveBestVersion_skipsArtifactsRequiringNewerMacOS() throws {
        let spec = makeSpec(versions: [
            makeVersionEntry("2.0.0", artifacts: [makeArtifact(minMacOS: "99.0")]),
            makeVersionEntry("1.0.0", artifacts: [makeArtifact(minMacOS: "14.0")]),
        ])

        let resolution = try spec.resolveBestVersion(
            targetPlatform: .macos,
            targetArch: .arm64,
            minimumOsaurusVersion: nil,
            currentMacOSVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        )

        XCTAssertEqual(resolution.version.version, sv("1.0.0"))
    }

    func test_resolveBestVersion_failsWhenNoArtifactSupportsThisMacOS() {
        let spec = makeSpec(versions: [
            makeVersionEntry("1.0.0", artifacts: [makeArtifact(minMacOS: "99.0")])
        ])

        XCTAssertThrowsError(
            try spec.resolveBestVersion(
                targetPlatform: .macos,
                targetArch: .arm64,
                minimumOsaurusVersion: nil,
                currentMacOSVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
            )
        ) { error in
            guard case PluginResolutionError.noMatchingArtifact = error else {
                return XCTFail("expected noMatchingArtifact, got \(error)")
            }
        }
    }

    func test_artifactSupportsMacOSVersion_failsOpenForMissingOrUnparseableDeclarations() {
        let current = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        XCTAssertTrue(PluginSpec.artifactSupportsMacOSVersion(makeArtifact(minMacOS: nil), current: current))
        XCTAssertTrue(PluginSpec.artifactSupportsMacOSVersion(makeArtifact(minMacOS: "banana"), current: current))
        XCTAssertTrue(PluginSpec.artifactSupportsMacOSVersion(makeArtifact(minMacOS: "15.0"), current: nil))
        XCTAssertTrue(PluginSpec.artifactSupportsMacOSVersion(makeArtifact(minMacOS: "15"), current: current))
        XCTAssertFalse(PluginSpec.artifactSupportsMacOSVersion(makeArtifact(minMacOS: "15.1"), current: current))
    }

    func test_parseLenientHostVersion_acceptsShortBundleVersions() {
        XCTAssertEqual(PluginInstallManager.parseLenientHostVersion("1.2.3"), sv("1.2.3"))
        XCTAssertEqual(PluginInstallManager.parseLenientHostVersion("1.0"), sv("1.0.0"))
        XCTAssertEqual(PluginInstallManager.parseLenientHostVersion("2"), sv("2.0.0"))
        XCTAssertNil(PluginInstallManager.parseLenientHostVersion("dev"))
    }

    func test_install_rejectsVersionsIncompatibleWithHost() async throws {
        let pluginId = "com.test.minversion"
        let spec = makeSpec(
            pluginId: pluginId,
            versions: [makeVersionEntry("2.0.0", minOsaurus: "99.0.0")]
        )
        try seedRegistryCache(with: spec)
        PluginInstallManager.hostVersionOverrideForTesting = sv("1.0.0")

        do {
            _ = try await PluginInstallManager.shared.install(pluginId: pluginId)
            XCTFail("expected install to fail resolution")
        } catch let error as PluginInstallError {
            guard case .resolutionFailed = error else {
                return XCTFail("expected resolutionFailed, got \(error)")
            }
        }
    }

    // MARK: - TOFU pinned key

    func test_pinnedSigningKeyMismatch_detectsRotation() throws {
        let pluginId = "com.test.pinned"
        try writeReceipt(pluginId: pluginId, version: "1.0.0", minisignKey: "RWTold")

        let installed = PluginInstallManager.latestInstalledReceipt(pluginId: pluginId)
        XCTAssertNotNil(installed)

        let rotated = makeSpec(pluginId: pluginId, publicKey: "RWTnew", versions: [makeVersionEntry("2.0.0")])
        XCTAssertTrue(PluginInstallManager.pinnedSigningKeyMismatch(spec: rotated, installedReceipt: installed))

        let same = makeSpec(pluginId: pluginId, publicKey: "RWTold", versions: [makeVersionEntry("2.0.0")])
        XCTAssertFalse(PluginInstallManager.pinnedSigningKeyMismatch(spec: same, installedReceipt: installed))

        XCTAssertFalse(
            PluginInstallManager.pinnedSigningKeyMismatch(spec: rotated, installedReceipt: nil),
            "fresh installs have no pinned key and must not be blocked"
        )
    }

    func test_pinnedSigningKeyMismatch_ignoresKeylessSideloadReceipts() throws {
        let pluginId = "com.test.keyless"
        try writeReceipt(pluginId: pluginId, version: "1.0.0", minisignKey: nil)
        let installed = PluginInstallManager.latestInstalledReceipt(pluginId: pluginId)

        let spec = makeSpec(pluginId: pluginId, publicKey: "RWTnew", versions: [makeVersionEntry("2.0.0")])
        XCTAssertFalse(PluginInstallManager.pinnedSigningKeyMismatch(spec: spec, installedReceipt: installed))
    }

    func test_install_failsClosedOnPinnedKeyRotation_andKeepsInstalledVersion() async throws {
        let pluginId = "com.test.rotation"
        try writeReceipt(pluginId: pluginId, version: "1.0.0", minisignKey: "RWTold")
        try PluginInstallManager.updateCurrentSymlink(pluginId: pluginId, version: sv("1.0.0"))

        let spec = makeSpec(pluginId: pluginId, publicKey: "RWTnew", versions: [makeVersionEntry("2.0.0")])
        try seedRegistryCache(with: spec)

        do {
            _ = try await PluginInstallManager.shared.install(pluginId: pluginId)
            XCTFail("expected install to fail closed on pinned-key rotation")
        } catch let error as PluginInstallError {
            guard case .authorKeyMismatch = error else {
                return XCTFail("expected authorKeyMismatch, got \(error)")
            }
        }

        let oldDir = PluginInstallManager.toolsVersionDirectory(pluginId: pluginId, version: sv("1.0.0"))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: oldDir.appendingPathComponent("receipt.json").path),
            "the previously installed version must remain untouched when the install is refused"
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: PluginInstallManager.currentSymlinkURL(pluginId: pluginId).path
            ),
            "1.0.0"
        )
    }

    // MARK: - Layout: exactly one dylib

    func test_locateSingleDylib_findsTheOnlyDylib() throws {
        let dir = tempRoot.appendingPathComponent("payload-one", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("bin".utf8).write(to: dir.appendingPathComponent("Plugin.dylib"))

        let found = try PluginInstallManager.locateSingleDylib(in: dir)
        XCTAssertEqual(found.lastPathComponent, "Plugin.dylib")
    }

    func test_locateSingleDylib_rejectsZeroDylibs() throws {
        let dir = tempRoot.appendingPathComponent("payload-zero", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        XCTAssertThrowsError(try PluginInstallManager.locateSingleDylib(in: dir)) { error in
            XCTAssertTrue(String(describing: error).contains("No .dylib"))
        }
    }

    func test_locateSingleDylib_rejectsMultipleDylibs() throws {
        let dir = tempRoot.appendingPathComponent("payload-two", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: dir.appendingPathComponent("A.dylib"))
        try Data("b".utf8).write(to: dir.appendingPathComponent("B.dylib"))

        XCTAssertThrowsError(try PluginInstallManager.locateSingleDylib(in: dir)) { error in
            XCTAssertTrue(String(describing: error).contains("exactly one"))
        }
    }

    // MARK: - Layout: web assets

    /// Regression: registry installs previously copied the dylib, skills, and
    /// docs but silently dropped `web/`, breaking every plugin with a static UI.
    func test_installVerifiedArtifact_copiesWebDirectory() throws {
        let pluginId = "com.test.web"
        let payload = tempRoot.appendingPathComponent("extracted-web", isDirectory: true)
        let webDir = payload.appendingPathComponent("web/assets", isDirectory: true)
        try FileManager.default.createDirectory(at: webDir, withIntermediateDirectories: true)
        try Data("bin".utf8).write(to: payload.appendingPathComponent("Plugin.dylib"))
        try Data("<html>ui</html>".utf8).write(
            to: payload.appendingPathComponent("web/index.html")
        )
        try Data("body{}".utf8).write(to: webDir.appendingPathComponent("app.css"))

        let spec = makeSpec(pluginId: pluginId, versions: [makeVersionEntry("1.0.0")])
        let result = try PluginInstallManager.shared.installVerifiedArtifact(
            extractedAt: payload,
            spec: spec,
            versionEntry: spec.versions[0],
            artifact: spec.versions[0].artifacts[0],
            targetPlatform: .macos,
            targetArch: .arm64
        )

        let installedWeb = result.installDirectory.appendingPathComponent("web", isDirectory: true)
        XCTAssertEqual(
            try String(contentsOf: installedWeb.appendingPathComponent("index.html"), encoding: .utf8),
            "<html>ui</html>"
        )
        XCTAssertEqual(
            try String(
                contentsOf: installedWeb.appendingPathComponent("assets/app.css"),
                encoding: .utf8
            ),
            "body{}"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: result.installDirectory.appendingPathComponent("receipt.json").path
            )
        )
    }

    func test_installVerifiedArtifact_prefersWebDirectoryNextToDylib() throws {
        let payload = tempRoot.appendingPathComponent("extracted-nested", isDirectory: true)
        let inner = payload.appendingPathComponent("bundle", isDirectory: true)
        try FileManager.default.createDirectory(
            at: inner.appendingPathComponent("web", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("bin".utf8).write(to: inner.appendingPathComponent("Plugin.dylib"))
        try Data("nested".utf8).write(to: inner.appendingPathComponent("web/index.html"))

        let spec = makeSpec(pluginId: "com.test.nestedweb", versions: [makeVersionEntry("1.0.0")])
        let result = try PluginInstallManager.shared.installVerifiedArtifact(
            extractedAt: payload,
            spec: spec,
            versionEntry: spec.versions[0],
            artifact: spec.versions[0].artifacts[0],
            targetPlatform: .macos,
            targetArch: .arm64
        )

        XCTAssertEqual(
            try String(
                contentsOf: result.installDirectory.appendingPathComponent("web/index.html"),
                encoding: .utf8
            ),
            "nested"
        )
    }

    func test_installVerifiedArtifact_withoutWebDirectoryInstallsNothingExtra() throws {
        let payload = tempRoot.appendingPathComponent("extracted-noweb", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try Data("bin".utf8).write(to: payload.appendingPathComponent("Plugin.dylib"))

        let spec = makeSpec(pluginId: "com.test.noweb", versions: [makeVersionEntry("1.0.0")])
        let result = try PluginInstallManager.shared.installVerifiedArtifact(
            extractedAt: payload,
            spec: spec,
            versionEntry: spec.versions[0],
            artifact: spec.versions[0].artifacts[0],
            targetPlatform: .macos,
            targetArch: .arm64
        )

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: result.installDirectory.appendingPathComponent("web").path
            )
        )
    }

    func test_installVerifiedArtifact_rejectsMultiDylibPayload() throws {
        let payload = tempRoot.appendingPathComponent("extracted-multi", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: payload.appendingPathComponent("A.dylib"))
        try Data("b".utf8).write(to: payload.appendingPathComponent("B.dylib"))

        let spec = makeSpec(pluginId: "com.test.multi", versions: [makeVersionEntry("1.0.0")])
        XCTAssertThrowsError(
            try PluginInstallManager.shared.installVerifiedArtifact(
                extractedAt: payload,
                spec: spec,
                versionEntry: spec.versions[0],
                artifact: spec.versions[0].artifacts[0],
                targetPlatform: .macos,
                targetArch: .arm64
            )
        )
    }
}
