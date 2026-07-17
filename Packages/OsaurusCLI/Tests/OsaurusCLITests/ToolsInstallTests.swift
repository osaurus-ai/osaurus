import CryptoKit
import Foundation
import OsaurusRepository
import XCTest

@testable import OsaurusCLICore

final class ToolsInstallTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-tools-install-dot-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    func testManualInstallSourceAcceptsCurrentAndParentDirectories() {
        XCTAssertTrue(ToolsInstall.isManualInstallSource("."))
        XCTAssertTrue(ToolsInstall.isManualInstallSource(".."))
        XCTAssertTrue(ToolsInstall.isManualInstallSource("../my-plugin"))
        XCTAssertTrue(ToolsInstall.isManualInstallSource("./my-plugin"))
        XCTAssertTrue(ToolsInstall.isManualInstallSource("/tmp/my-plugin"))
        XCTAssertTrue(ToolsInstall.isManualInstallSource("https://example.invalid/plugin.zip"))
        XCTAssertFalse(ToolsInstall.isManualInstallSource("osaurus.browser"))
    }

    func testManualInstallIdentityPrefersPackagedFilename() throws {
        let manifest = """
            {
              "plugin_id": "dev.example.manifest",
              "version": "9.9.9"
            }
            """
        try manifest.write(
            to: tempDir.appendingPathComponent("osaurus-plugin.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let identity = try ToolsInstall.resolveManualInstallIdentity(
            sourceName: "dev.example.packaged-1.2.3.zip",
            pluginRoot: tempDir
        )

        XCTAssertEqual(identity.pluginId, "dev.example.packaged")
        XCTAssertEqual(identity.version, SemanticVersion.parse("1.2.3"))
    }

    func testDirectoryInstallIdentityPrefersManifestOverSemverFolderName() throws {
        let manifest = """
            {
              "plugin_id": "dev.example.manifest",
              "version": "0.2.0"
            }
            """
        try manifest.write(
            to: tempDir.appendingPathComponent("osaurus-plugin.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let identity = try ToolsInstall.resolveManualInstallIdentity(
            sourceName: "dev.example.folder-1.2.3",
            pluginRoot: tempDir,
            preferManifestIdentity: true
        )

        XCTAssertEqual(identity.pluginId, "dev.example.manifest")
        XCTAssertEqual(identity.version, SemanticVersion.parse("0.2.0"))
    }

    func testManualInstallIdentityFallsBackToLightweightOsaurusPluginJson() throws {
        let manifest = """
            {
              "plugin_id": "dev.example.current",
              "version": "0.1.0"
            }
            """
        try manifest.write(
            to: tempDir.appendingPathComponent("osaurus-plugin.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let identity = try ToolsInstall.resolveManualInstallIdentity(sourceName: ".", pluginRoot: tempDir)

        XCTAssertEqual(identity.pluginId, "dev.example.current")
        XCTAssertEqual(identity.version, SemanticVersion.parse("0.1.0"))
    }

    func testLightweightOsaurusPluginJsonSkipsFullManifestValidation() throws {
        let manifest = """
            {
              "plugin_id": "dev.example.current",
              "version": "0.1.0"
            }
            """
        try manifest.write(
            to: tempDir.appendingPathComponent("osaurus-plugin.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let identity = try ToolsInstall.resolveManualInstallIdentity(sourceName: ".", pluginRoot: tempDir)
        let warnings = try ToolsInstall.validateBundledManifestIfPresent(in: tempDir, identity: identity)

        XCTAssertTrue(warnings.isEmpty)
    }

    func testPackagedFilenameDoesNotBypassLightweightManifestValidation() throws {
        let manifest = """
            {
              "plugin_id": "dev.example.packaged",
              "version": "1.2.3"
            }
            """
        try manifest.write(
            to: tempDir.appendingPathComponent("osaurus-plugin.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let identity = try ToolsInstall.resolveManualInstallIdentity(
            sourceName: "dev.example.packaged-1.2.3.zip",
            pluginRoot: tempDir
        )

        XCTAssertThrowsError(try ToolsInstall.validateBundledManifestIfPresent(in: tempDir, identity: identity)) {
            error in
            XCTAssertTrue(String(describing: error).contains("capabilities"))
        }
    }

    func testFullPluginManifestStillFailsValidationWhenMalformed() throws {
        let lightweightConfig = """
            {
              "plugin_id": "dev.example.bad",
              "version": "0.1.0"
            }
            """
        try lightweightConfig.write(
            to: tempDir.appendingPathComponent("osaurus-plugin.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let manifest = """
            {
              "plugin_id": "dev.example.bad"
            }
            """
        try manifest.write(
            to: tempDir.appendingPathComponent("plugin.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let identity = try ToolsInstall.resolveManualInstallIdentity(sourceName: ".", pluginRoot: tempDir)

        XCTAssertThrowsError(try ToolsInstall.validateBundledManifestIfPresent(in: tempDir, identity: identity)) {
            error in
            XCTAssertTrue(String(describing: error).contains("capabilities"))
        }
    }

    func testFullManifestMustMatchLightweightIdentity() throws {
        let lightweightConfig = """
            {
              "plugin_id": "dev.example.current",
              "version": "0.1.0"
            }
            """
        try lightweightConfig.write(
            to: tempDir.appendingPathComponent("osaurus-plugin.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let fullManifest = """
            {
              "plugin_id": "dev.example.other",
              "version": "0.1.0",
              "capabilities": {}
            }
            """
        try fullManifest.write(
            to: tempDir.appendingPathComponent("plugin.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let identity = try ToolsInstall.resolveManualInstallIdentity(sourceName: ".", pluginRoot: tempDir)

        XCTAssertThrowsError(try ToolsInstall.validateBundledManifestIfPresent(in: tempDir, identity: identity)) {
            error in
            XCTAssertTrue(String(describing: error).contains("dev.example.other"))
            XCTAssertTrue(String(describing: error).contains("dev.example.current"))
        }
    }

    func testManualInstallReceiptIncludesArtifactMetadata() throws {
        let dylibBytes = Data("manual-plugin-binary".utf8)
        let dylibURL = tempDir.appendingPathComponent("ManualPlugin.dylib", isDirectory: false)
        try dylibBytes.write(to: dylibURL)
        let version = try XCTUnwrap(SemanticVersion.parse("1.2.3"))

        try ToolsInstall.createManualInstallReceipt(
            pluginId: "com.example.manual",
            version: version,
            installDir: tempDir
        )

        let receiptURL = tempDir.appendingPathComponent("receipt.json", isDirectory: false)
        let receiptData = try Data(contentsOf: receiptURL)
        let receipt = try JSONDecoder().decode(PluginReceipt.self, from: receiptData)
        let expectedSha = Data(SHA256.hash(data: dylibBytes)).map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(receipt.plugin_id, "com.example.manual")
        XCTAssertEqual(receipt.version, version)
        XCTAssertEqual(receipt.dylib_filename, "ManualPlugin.dylib")
        XCTAssertEqual(receipt.dylib_sha256, expectedSha)
        let artifactURL = try XCTUnwrap(URL(string: receipt.artifact.url))
        XCTAssertEqual(artifactURL.scheme, "file")
        XCTAssertEqual(
            artifactURL.resolvingSymlinksInPath().path,
            dylibURL.resolvingSymlinksInPath().path
        )
        XCTAssertEqual(receipt.artifact.sha256, expectedSha)
        XCTAssertNil(receipt.artifact.minisign)
        XCTAssertEqual(receipt.artifact.size, dylibBytes.count)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: receiptData) as? [String: Any])
        XCTAssertNotNil(json["artifact"], "Manual install receipts must keep the artifact object required by PluginReceipt.")
    }

    func testManualInstallReceiptEncodesArtifactURLForPathsWithSpaces() throws {
        let installDir = tempDir.appendingPathComponent("Manual Plugin With Spaces", isDirectory: true)
        try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
        let dylibBytes = Data("manual-plugin-binary".utf8)
        let dylibURL = installDir.appendingPathComponent("Manual Plugin.dylib", isDirectory: false)
        try dylibBytes.write(to: dylibURL)
        let version = try XCTUnwrap(SemanticVersion.parse("1.2.3"))

        try ToolsInstall.createManualInstallReceipt(
            pluginId: "com.example.manual",
            version: version,
            installDir: installDir
        )

        let receiptURL = installDir.appendingPathComponent("receipt.json", isDirectory: false)
        let receiptData = try Data(contentsOf: receiptURL)
        let receipt = try JSONDecoder().decode(PluginReceipt.self, from: receiptData)
        let artifactURL = try XCTUnwrap(URL(string: receipt.artifact.url))

        XCTAssertEqual(artifactURL.scheme, "file")
        XCTAssertTrue(receipt.artifact.url.contains("%20"))
        XCTAssertEqual(
            artifactURL.resolvingSymlinksInPath().path,
            dylibURL.resolvingSymlinksInPath().path
        )
    }

    func testManualInstallReceiptFailsWhenNoDylibExists() throws {
        let version = try XCTUnwrap(SemanticVersion.parse("1.2.3"))

        XCTAssertThrowsError(
            try ToolsInstall.createManualInstallReceipt(
                pluginId: "com.example.empty",
                version: version,
                installDir: tempDir
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("No .dylib"))
        }

        let receiptURL = tempDir.appendingPathComponent("receipt.json", isDirectory: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL.path))
    }
}
