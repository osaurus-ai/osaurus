//
//  InstallationDiagnosticsTests.swift
//  OsaurusCLITests
//
//  Regression coverage for stale and duplicate app installations that used to
//  collapse into ServeCommand's generic timeout message.
//

import Foundation
import Testing

@testable import OsaurusCLICore

@Suite
struct InstallationDiagnosticsTests {
    @Test
    func explicitBuildMetadataPrecedesCompanionBundle() throws {
        let app = try makeApp(version: "0.22.3", build: "223")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }

        let output = VersionCommand.output(
            environment: ["OSAURUS_VERSION": "9.1.0", "OSAURUS_BUILD_NUMBER": "42"],
            executablePath: app.appendingPathComponent("Contents/Helpers/osaurus").path
        )

        #expect(output == "Osaurus 9.1.0 (42)")
    }

    @Test
    func packagedHelperReadsCompanionBundleVersion() throws {
        let app = try makeApp(version: "0.22.3", build: "223")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }

        let output = VersionCommand.output(
            environment: [:],
            executablePath: app.appendingPathComponent("Contents/Helpers/osaurus").path
        )

        #expect(output == "Osaurus 0.22.3 (223)")
    }

    @Test
    func genuineDevelopmentBuildStillReportsDev() {
        let output = VersionCommand.output(
            environment: [:],
            executablePath: "/tmp/osaurus"
        )
        #expect(output == "Osaurus dev")
    }

    @Test
    func standaloneCLIDoesNotBorrowDiscoveredAppVersion() throws {
        let app = try makeApp(version: "0.22.3", build: "223")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }

        let resolved = CLIVersionResolver.resolve(
            environment: [:],
            executablePath: "/tmp/osaurus"
        )

        #expect(resolved.version == nil)
        #expect(resolved.companionAppPath == nil)
    }

    @Test
    func bundlePathDeduplicationIgnoresCaseAndSymlinkAliases() throws {
        let app = try makeApp(version: "0.22.3", build: "223")
        let alias = app.deletingLastPathComponent().appendingPathComponent("Alias.app")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: app)

        let paths = AppControl.deduplicatedBundlePaths([
            app.path,
            app.path.replacingOccurrences(of: "Osaurus.app", with: "osaurus.app"),
            alias.path,
        ])

        #expect(paths.count == 1)
        #expect(paths[0] == app.path)
    }

    @Test(arguments: [
        (apps: [], cli: "0.22.3", healthy: false, owner: nil, expected: StartupDiagnosticKind.appAbsent),
        (
            apps: [], cli: "0.22.3", healthy: false, owner: "python pid 7",
            expected: StartupDiagnosticKind.portBusy
        ),
        (
            apps: [], cli: "0.22.3", healthy: false, owner: "osaurus pid 8",
            expected: StartupDiagnosticKind.serverUnhealthy
        ),
        (
            apps: [], cli: "0.22.3", healthy: true, owner: "python pid 7",
            expected: StartupDiagnosticKind.portBusy
        ),
        (
            apps: [app(version: "0.18.4")], cli: "0.22.3", healthy: false, owner: nil,
            expected: StartupDiagnosticKind.appStale
        ),
        (
            apps: [app(version: "0.23.0")], cli: "0.22.3", healthy: false, owner: nil,
            expected: StartupDiagnosticKind.appNewer
        ),
        (
            apps: [app(version: "0.22.3"), app(path: "/Users/test/Osaurus.app", version: "0.18.4")],
            cli: "0.22.3", healthy: false, owner: nil,
            expected: StartupDiagnosticKind.duplicateBundles
        ),
        (
            apps: [app(version: "0.22.3"), app(path: "/Users/test/Osaurus.app", version: "0.18.4")],
            cli: "0.22.3", healthy: false, owner: "python pid 7",
            expected: StartupDiagnosticKind.duplicateBundles
        ),
        (
            apps: [app(version: "0.22.3")], cli: "0.22.3", healthy: false,
            owner: "python pid 7", expected: StartupDiagnosticKind.portBusy
        ),
        (
            apps: [app(version: "0.22.3")], cli: "0.22.3", healthy: false,
            owner: "osaurus pid 8", expected: StartupDiagnosticKind.serverUnhealthy
        ),
        (
            apps: [app(version: "0.22.3")], cli: "0.22.3", healthy: false, owner: nil,
            expected: StartupDiagnosticKind.serverNotRunning
        ),
        (
            apps: [app(version: "0.18.4")], cli: "0.22.3", healthy: true, owner: "osaurus pid 8",
            expected: StartupDiagnosticKind.appStale
        ),
    ])
    func classifiesStartupFailures(
        apps: [AppBundleDiagnostic],
        cli: String,
        healthy: Bool,
        owner: String?,
        expected: StartupDiagnosticKind
    ) {
        #expect(
            InstallationDiagnostics.classify(
                apps: apps,
                cliVersion: cli,
                healthy: healthy,
                portOwner: owner
            ) == expected
        )
    }

    @Test func sameVersionDifferentBuildDetectsSkew() {
        let stale = AppBundleDiagnostic(
            path: "/Applications/Osaurus.app",
            version: "0.22.3",
            build: "9",
            isRunning: false,
            isCompanion: true
        )
        #expect(
            InstallationDiagnostics.classify(
                apps: [stale],
                cliVersion: "0.22.3",
                cliBuild: "10",
                healthy: false,
                portOwner: nil
            ) == .appStale
        )
    }

    @Test func numericVersionComparisonDoesNotUseLexicographicOrdering() {
        #expect(
            InstallationDiagnostics.classify(
                apps: [Self.app(version: "0.10")],
                cliVersion: "0.9",
                healthy: false,
                portOwner: nil
            ) == .appNewer
        )
    }

    @Test func equivalentVersionComponentCountsDoNotReportSkew() {
        #expect(
            InstallationDiagnostics.classify(
                apps: [Self.app(version: "1.0")],
                cliVersion: "1.0.0",
                healthy: false,
                portOwner: nil
            ) == .serverNotRunning
        )
    }

    @Test func attemptedStartupWithoutListenerReportsTimeout() {
        #expect(
            InstallationDiagnostics.classify(
                apps: [Self.app(version: "0.22.3")],
                cliVersion: "0.22.3",
                healthy: false,
                portOwner: nil,
                startupAttempted: true
            ) == .startupTimeout
        )
    }

    @Test func ownerNameMustExactlyIdentifyOsaurus() {
        #expect(
            InstallationDiagnostics.classify(
                apps: [Self.app(version: "0.22.3")],
                cliVersion: "0.22.3",
                healthy: false,
                portOwner: "myosaurushelper pid 8"
            ) == .portBusy
        )
    }

    @Test func modelCountCountsBundlesInsteadOfOrganizationFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("mlx-community/first", isDirectory: true)
        let second = root.appendingPathComponent("mlx-community/second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: first.appendingPathComponent("config.json"))
        try Data().write(to: second.appendingPathComponent("model.safetensors"))

        #expect(InstallationDiagnostics.countModelBundles(in: root) == (2, true))
        #expect(InstallationDiagnostics.countModelBundles(in: root, maximumEntries: 1).complete == false)
    }

    @Test func modelDirectoryEnvironmentOverrideIsExplicitlyAttributed() {
        let resolution = Configuration.resolveModelsDirectoryWithSource(
            environment: ["OSU_MODELS_DIR": "/Volumes/Models"],
            appDefaults: nil,
            sharedDefaults: nil,
            home: URL(fileURLWithPath: "/Users/test")
        )
        #expect(resolution.url.path == "/Volumes/Models")
        #expect(resolution.source == "environment")
    }

    @Test
    func redactedReportScrubsHomePathsButKeepsUsefulStructure() {
        let home = "/Users/alice"
        let report = InstallationDiagnosticReport(
            generatedAt: Date(timeIntervalSince1970: 0),
            cliPath: "\(home)/bin/osaurus",
            cliVersion: "0.22.3",
            cliBuild: "223",
            requestedPort: 1337,
            configuredPort: 4242,
            serverHealthy: false,
            portOwner: "osaurus pid 42",
            modelRoot: "\(home)/.osaurus/models",
            modelRootSource: "cli_default",
            modelRootReadable: true,
            modelCount: 2,
            modelCountComplete: true,
            apps: [Self.app(path: "\(home)/Applications/Osaurus.app", version: "0.22.3")],
            diagnosis: .serverNotRunning,
            recommendation: "Inspect \(home)/Applications/Osaurus.app"
        ).redacted(homeDirectory: home)
        let serialized = String(data: try! JSONEncoder().encode(report), encoding: .utf8)!

        #expect(!serialized.contains(home))
        #expect(report.cliPath == "~/bin/osaurus")
        #expect(report.modelRoot == "~/.osaurus/models")
        #expect(report.portOwner == "osaurus pid 42")
    }

    @Test
    func redactedReportScrubsResolvedDataVolumeHome() {
        let report = InstallationDiagnosticReport(
            generatedAt: Date(timeIntervalSince1970: 0),
            cliPath: "/System/Volumes/Data/Users/alice/bin/osaurus",
            cliVersion: nil,
            cliBuild: nil,
            requestedPort: 1337,
            configuredPort: nil,
            serverHealthy: false,
            portOwner: nil,
            modelRoot: "/System/Volumes/Data/Users/alice/.osaurus/models",
            modelRootSource: "cli_default",
            modelRootReadable: true,
            modelCount: 0,
            modelCountComplete: true,
            apps: [],
            diagnosis: .appAbsent,
            recommendation: "Inspect /System/Volumes/Data/Users/alice/Applications"
        ).redacted(homeDirectory: "/Users/alice")

        let rendered = DoctorCommand.render(report)
        #expect(!rendered.contains("alice"))
        #expect(report.cliPath == "~/bin/osaurus")
    }

    @Test
    func doctorOptionsValidatePortsAndUnknownArguments() throws {
        #expect(try DoctorCommand.parseOptions([
            "--port", "4242", "--json", "--redact", "--verify-signatures",
        ]) == .init(port: 4242, json: true, redact: true, verifySignatures: true))
        #expect(try DoctorCommand.parseOptions([])
            == .init(port: nil, json: false, redact: false, verifySignatures: false))
        #expect(throws: DoctorCommand.ArgumentError.self) {
            _ = try DoctorCommand.parseOptions(["--port", "0"])
        }
        #expect(throws: DoctorCommand.ArgumentError.self) {
            _ = try DoctorCommand.parseOptions(["--port", "70000"])
        }
        #expect(throws: DoctorCommand.ArgumentError.self) {
            _ = try DoctorCommand.parseOptions(["--unknown"])
        }
    }

    @Test
    func diagnosticReportAlwaysEncodesToNonemptyJSON() throws {
        let report = InstallationDiagnosticReport(
            generatedAt: Date(timeIntervalSince1970: 0),
            cliPath: "/usr/local/bin/osaurus",
            cliVersion: nil,
            cliBuild: nil,
            requestedPort: 1337,
            configuredPort: nil,
            serverHealthy: false,
            portOwner: nil,
            modelRoot: "~/.osaurus/models",
            modelRootSource: "cli_default",
            modelRootReadable: true,
            modelCount: 0,
            modelCountComplete: true,
            apps: [],
            diagnosis: .appAbsent,
            recommendation: "Install Osaurus.app."
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        #expect(!data.isEmpty)
    }

    @Test
    func reportRenderingDoesNotIncludeEnvironmentValues() {
        let canary = "SECRET_TOKEN_CANARY"
        let report = InstallationDiagnosticReport(
            generatedAt: Date(),
            cliPath: "/Applications/Osaurus.app/Contents/Helpers/osaurus",
            cliVersion: "0.22.3",
            cliBuild: "223",
            requestedPort: 1337,
            configuredPort: 1337,
            serverHealthy: false,
            portOwner: nil,
            modelRoot: "~/.osaurus/models",
            modelRootSource: "cli_default",
            modelRootReadable: true,
            modelCount: 1,
            modelCountComplete: true,
            apps: [Self.app(version: "0.22.3")],
            diagnosis: .serverNotRunning,
            recommendation: "Launch the intended app."
        )

        let rendered = DoctorCommand.render(report)
        #expect(!rendered.contains(canary))
        #expect(rendered.contains("server_not_running"))
        #expect(rendered.contains("0.22.3"))
        #expect(rendered.contains("build 223"))
    }

    private static func app(
        path: String = "/Applications/Osaurus.app",
        version: String
    ) -> AppBundleDiagnostic {
        AppBundleDiagnostic(
            path: path,
            version: version,
            build: nil,
            isRunning: false,
            isCompanion: true
        )
    }

    private func makeApp(version: String, build: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-version-test-\(UUID().uuidString)")
        let app = root.appendingPathComponent("Osaurus.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(
            at: contents.appendingPathComponent("Helpers"),
            withIntermediateDirectories: true
        )
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.dinoki.osaurus",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
        return app
    }
}
