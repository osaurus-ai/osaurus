//
//  PluginReadFreshnessTests.swift
//  osaurusTests
//
//  `PluginRepositoryService.plugins` is populated only as a side effect of a
//  human opening a window: every caller of `refresh()` is a view, and the
//  auto-refresh timer is tied to that view's lifecycle. The agent-facing
//  configuration tools read that array directly, so in a session where nobody
//  visited the Plugins tab they reported installed plugins as missing and the
//  model could not invoke them (#2039).
//
//  The fix is that each of those reads first calls
//  `ensureInstalledPluginsLoaded()`. That is a *reachability* property — a
//  behavioural test would pass either way as long as some earlier test had
//  already populated the shared singleton — so it is pinned against the source.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Agent-facing plugin reads are self-sufficient")
struct PluginReadFreshnessTests {

    private static func packageRoot() -> URL {
        // .../Tests/Tool/<this file> → package root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func source(_ relativePath: String) throws -> String {
        let url = packageRoot().appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Every tool body that reads `PluginRepositoryService.shared.plugins` must
    /// first ensure that array reflects disk.
    @Test func configurationToolsEnsurePluginStateBeforeReadingIt() throws {
        let src = try Self.source("Tools/ConfigurationTools.swift")

        let reads = src.components(separatedBy: "PluginRepositoryService.shared.plugins").count - 1
        #expect(reads > 0, "test is watching the wrong symbol")

        let ensures =
            src.components(separatedBy: "PluginRepositoryService.shared.ensureInstalledPluginsLoaded()")
            .count - 1
        #expect(
            ensures >= 3,
            """
            osaurus_status, osaurus_list and osaurus_describe each read the plugin \
            array; every one must call ensureInstalledPluginsLoaded() first, or a \
            session that never opened the Plugins tab reports installed plugins as \
            missing. Found \(ensures) call(s) for \(reads) read(s).
            """)
    }

    /// The ensure path must stay local-disk-only. If it ever starts calling
    /// `refresh()` it would pull the central repository — network I/O on every
    /// tool read, which is why the cheap variant exists.
    @Test func ensurePathDoesNotTriggerRepositoryRefresh() throws {
        let src = try Self.source("Services/Plugin/PluginRepositoryService.swift")

        guard let start = src.range(of: "func ensureInstalledPluginsLoaded() async {"),
            let end = src.range(of: "\n    }", range: start.upperBound ..< src.endIndex)
        else {
            Issue.record("ensureInstalledPluginsLoaded() not found")
            return
        }
        let body = String(src[start.upperBound ..< end.lowerBound])

        #expect(!body.contains("refresh()"), "ensure path must not do repository/network I/O")
        #expect(body.contains("loadInstalledPluginsFromDisk"))
        #expect(body.contains("updateInstalledState"))
    }

    /// The premise of the bug: `refresh()` has no non-view caller. If someone
    /// later refreshes from a service or app-launch path this test should fail
    /// so the ensure calls can be reconsidered rather than left as dead weight.
    @Test func repositoryRefreshIsStillOnlyDrivenByViews() throws {
        let root = Self.packageRoot()
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil)
        var callers: [String] = []

        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let path = url.path
            guard !path.contains("/.build/"), !path.contains("/Tests/") else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            guard text.contains("PluginRepositoryService.shared.refresh()")
                || text.contains("repoService.refresh()")
            else { continue }
            callers.append(url.lastPathComponent)
        }

        let nonViewCallers = callers.filter { !$0.hasSuffix("View.swift") }
        #expect(
            nonViewCallers.isEmpty,
            "refresh() gained a non-view caller \(nonViewCallers) — re-check whether the agent-facing ensure calls are still required")
    }
}
