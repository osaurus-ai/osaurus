//
//  CentralRepositoryManagerTests.swift
//  OsaurusRepository
//

import Foundation
import XCTest

@testable import OsaurusRepository

final class CentralRepositoryManagerTests: XCTestCase {
    private var tempRoot: URL!
    private var previousRoot: URL?
    private var previousRepository: CentralRepository!
    private var previousDownloadOverride: (@Sendable (URL, URL) throws -> Void)?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-central-repo-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        previousRoot = ToolsPaths.overrideRoot
        previousRepository = CentralRepositoryManager.shared.central
        previousDownloadOverride = CentralRepositoryManager.downloadFileOverride
        ToolsPaths.overrideRoot = tempRoot
        CentralRepositoryManager.downloadFileOverride = nil
    }

    override func tearDownWithError() throws {
        ToolsPaths.overrideRoot = previousRoot
        CentralRepositoryManager.shared.central = previousRepository
        CentralRepositoryManager.downloadFileOverride = previousDownloadOverride
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try super.tearDownWithError()
    }

    func testRefreshWithDiagnosticsClassifiesOfflineNetworkFailure() {
        CentralRepositoryManager.shared.central = CentralRepository(
            url: "https://github.com/osaurus-ai/osaurus-tools.git",
            branch: "main"
        )
        CentralRepositoryManager.downloadFileOverride = { _, _ in
            throw URLError(.notConnectedToInternet)
        }

        let result = CentralRepositoryManager.shared.refreshWithDiagnostics()

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.failure?.kind, .networkUnavailable)
        XCTAssertEqual(result.failure?.retryable, true)
        XCTAssertEqual(result.cacheAvailable, false)
        XCTAssertEqual(
            result.attemptedArchiveURLs,
            ["https://github.com/osaurus-ai/osaurus-tools/archive/refs/heads/main.zip"]
        )
        XCTAssertEqual(result.failure?.failedArchiveURL, result.attemptedArchiveURLs.first)
        XCTAssertTrue(result.userMessage?.contains("unreachable") == true)
        XCTAssertTrue(result.userMessage?.contains("No cached plugin list") == true)
    }

    func testRefreshWithDiagnosticsMentionsCachedRepositoryWhenRefreshFails() throws {
        try writeCachedSpec(pluginId: "osaurus.cached")
        CentralRepositoryManager.shared.central = CentralRepository(
            url: "https://github.com/osaurus-ai/osaurus-tools.git",
            branch: "main"
        )
        CentralRepositoryManager.downloadFileOverride = { _, _ in
            throw URLError(.timedOut)
        }

        let result = CentralRepositoryManager.shared.refreshWithDiagnostics()

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.failure?.kind, .timedOut)
        XCTAssertTrue(result.cacheAvailable)
        XCTAssertNotNil(result.cacheUpdatedAt)
        XCTAssertTrue(result.userMessage?.contains("Showing cached plugin list") == true)
        XCTAssertEqual(CentralRepositoryManager.shared.listAllSpecs().map(\.plugin_id), ["osaurus.cached"])
    }

    func testRefreshDiagnosticsRedactCredentialBearingRepositoryURL() {
        CentralRepositoryManager.shared.central = CentralRepository(
            url: "https://token:secret@github.com/osaurus-ai/osaurus-tools.git?api_key=secret",
            branch: "main"
        )
        CentralRepositoryManager.downloadFileOverride = { _, _ in
            throw URLError(.timedOut)
        }

        let result = CentralRepositoryManager.shared.refreshWithDiagnostics()
        let diagnostic = [
            result.repositoryURL,
            result.attemptedArchiveURLs.joined(separator: " "),
            result.failure?.repositoryURL ?? "",
            result.failure?.failedArchiveURL ?? "",
            result.failure?.message ?? "",
            result.failure?.userMessage ?? "",
        ].joined(separator: " ")

        XCTAssertFalse(diagnostic.contains("secret"))
        XCTAssertFalse(diagnostic.contains("api_key"))
        XCTAssertEqual(result.repositoryURL, "https://github.com/osaurus-ai/osaurus-tools.git")
    }

    func testRefreshDiagnosticsFailClosedWhenRepositoryURLCannotParse() {
        CentralRepositoryManager.shared.central = CentralRepository(
            url: "https://token:secret@%",
            branch: nil
        )

        let result = CentralRepositoryManager.shared.refreshWithDiagnostics()
        let diagnostic = [
            result.repositoryURL,
            result.failure?.repositoryURL ?? "",
            result.failure?.message ?? "",
            result.failure?.userMessage ?? "",
        ].joined(separator: " ")

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.failure?.kind, .unsupportedRepository)
        XCTAssertEqual(result.repositoryURL, "<repository-url>")
        XCTAssertFalse(diagnostic.contains("secret"))
        XCTAssertFalse(diagnostic.contains("token"))
    }

    func testRefreshDiagnosticsRedactsLocalPathsFromArchiveFailures() throws {
        CentralRepositoryManager.shared.central = CentralRepository(
            url: "https://github.com/osaurus-ai/osaurus-tools.git",
            branch: nil
        )
        CentralRepositoryManager.downloadFileOverride = { _, destination in
            try Data("not a zip archive".utf8).write(to: destination)
        }

        let result = CentralRepositoryManager.shared.refreshWithDiagnostics()

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.failure?.kind, .unzipFailed)
        XCTAssertEqual(
            result.attemptedArchiveURLs,
            ["https://github.com/osaurus-ai/osaurus-tools/archive/refs/heads/main.zip"]
        )
        XCTAssertFalse(result.failure?.message.contains(tempRoot.path) == true)
        XCTAssertFalse(result.failure?.userMessage.contains(tempRoot.path) == true)
        XCTAssertFalse(result.failure?.message.contains(NSHomeDirectory()) == true)
    }

    func testRefreshDiagnosticsRecordsMainMaster404FallbackChain() {
        CentralRepositoryManager.shared.central = CentralRepository(
            url: "https://github.com/osaurus-ai/osaurus-tools.git",
            branch: nil
        )
        CentralRepositoryManager.downloadFileOverride = { _, _ in
            throw RefreshError.httpStatus(404)
        }

        let result = CentralRepositoryManager.shared.refreshWithDiagnostics()

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.failure?.kind, .notFound)
        XCTAssertEqual(result.failure?.httpStatusCode, 404)
        XCTAssertEqual(result.failure?.retryable, false)
        XCTAssertEqual(
            result.attemptedArchiveURLs,
            [
                "https://github.com/osaurus-ai/osaurus-tools/archive/refs/heads/main.zip",
                "https://github.com/osaurus-ai/osaurus-tools/archive/refs/heads/master.zip",
            ]
        )
        XCTAssertEqual(result.failure?.failedArchiveURL, result.attemptedArchiveURLs.last)
    }

    func testRefreshKeepsBooleanCompatibility() {
        CentralRepositoryManager.shared.central = CentralRepository(
            url: "https://github.com/osaurus-ai/osaurus-tools.git",
            branch: "main"
        )
        CentralRepositoryManager.downloadFileOverride = { _, _ in
            throw URLError(.cannotFindHost)
        }

        XCTAssertFalse(CentralRepositoryManager.shared.refresh())
    }

    private func writeCachedSpec(pluginId: String) throws {
        let pluginsDirectory = ToolsPaths.pluginSpecsRoot()
            .appendingPathComponent("central", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)

        let spec = PluginSpec(plugin_id: pluginId, name: "Cached Plugin")
        let data = try JSONEncoder().encode(spec)
        try data.write(
            to: pluginsDirectory.appendingPathComponent("\(pluginId).json", isDirectory: false),
            options: .atomic
        )
    }
}
