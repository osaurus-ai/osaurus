//
//  BrowserWebKitSmokeTests.swift
//  OsaurusCore — Native Browser Use
//
//  Live-WebKit smoke coverage ported from the `osaurus.browser` plugin's
//  NavigateTests / ActionSnapshotTests / BatchDoTests: real navigation into
//  local HTML fixtures, snapshot refs, batched actions with fail-fast +
//  recovery snapshot, and ref staleness across navigations.
//
//  Like the plugin's suite, these need a full application context for
//  `WKWebView` — they run under xcodebuild (`make ci-test`) or with
//  OSAURUS_BROWSER_TESTS=1, and are skipped in plain `swift test`, which
//  cannot host WebKit's XPC stack.
//

import AppKit
import Foundation
import Testing
import WebKit

@testable import OsaurusCore

/// Whether this process can host a live WKWebView (plugin-parity gate).
private var webKitTestsEnabled: Bool {
    let env = ProcessInfo.processInfo.environment
    return env["XCTestBundlePath"] != nil || env["OSAURUS_BROWSER_TESTS"] == "1"
}

/// Fixture pages, written to temp files and loaded over file:// — inlined
/// from the plugin's Fixtures/ so the suite has no bundle-resource plumbing.
private enum SmokeFixtures {
    static let loginForm = """
        <!DOCTYPE html>
        <html><head><title>Login Fixture</title></head><body>
            <h1>Sign in</h1>
            <form id="login-form">
                <input type="email" id="email" name="email" placeholder="Email">
                <input type="password" id="password" name="password" placeholder="Password">
                <label><input type="checkbox" id="remember" name="remember"> Remember me</label>
                <button type="button" id="login-btn">Log in</button>
            </form>
        </body></html>
        """

    static let interactive = """
        <!DOCTYPE html>
        <html><head><title>Interactive Fixture</title>
        <style>.hidden-display { display: none; }</style>
        </head><body>
            <h1>Interactive Elements</h1>
            <input type="text" id="text-input" name="username" placeholder="Username">
            <button id="btn-primary">Primary Action</button>
            <button class="hidden-display" id="hidden-btn">Hidden</button>
            <a href="##page1" id="link-page1">Page 1</a>
            <select id="select-country" name="country">
                <option value="">Choose country</option>
                <option value="us">United States</option>
            </select>
        </body></html>
        """

    static let shadowHost = """
        <!DOCTYPE html>
        <html><head><title>Shadow Fixture</title></head><body>
            <h1>Web Component Page</h1>
            <div id="host"></div>
            <button id="light-btn">Light Button</button>
            <script>
                const root = document.getElementById('host').attachShadow({mode: 'open'});
                root.innerHTML = '<button id="shadow-btn">Shadow Button</button>';
            </script>
        </body></html>
        """

    static let blankLink = """
        <!DOCTYPE html>
        <html><head><title>Blank Fixture</title></head><body>
            <a href="second.html" target="_blank" id="blank-link">Open in new window</a>
        </body></html>
        """

    static let secondPage = """
        <!DOCTYPE html>
        <html><head><title>Second Page</title></head><body>
            <h1>Arrived</h1>
            <button id="second-btn">Second</button>
        </body></html>
        """

    static let article = """
        <!DOCTYPE html>
        <html><head><title>Article Fixture</title></head><body>
            <nav>Home | About | Contact</nav>
            <main>
                <h1>The History of Fixtures</h1>
                <p>Fixtures were invented so tests could be deterministic. The key fact is
                that the answer is forty-two.</p>
            </main>
            <footer>Footer junk</footer>
        </body></html>
        """

    /// Write a fixture and return its file:// URL string.
    static func write(_ html: String, to dir: URL, name: String) throws -> String {
        let url = dir.appendingPathComponent("\(name).html")
        try html.data(using: .utf8)!.write(to: url)
        return url.absoluteString
    }
}

@MainActor
@Suite(.serialized, .enabled(if: webKitTestsEnabled))
struct BrowserWebKitSmokeTests {

    /// Run `body` against a throwaway executor whose session, catalog record,
    /// and WebKit store are all torn down afterward. The confirm seam
    /// auto-approves so edit-class actions run unattended under the default
    /// (Balanced) policy — approval behavior itself is covered by
    /// `BrowserGateTests`.
    private func withSmokeExecutor(
        _ body: (BrowserToolExecutor, _ fixtures: URL) async throws -> Void
    ) async rethrows {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-browser-smoke-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let previousCatalogDir = BrowserSessionCatalog.overrideDirectory
        BrowserSessionCatalog.overrideDirectory = dir
        BrowserSessionCatalog.resetCacheForTests()

        let agentId = UUID()
        // The scheme policy blocks file:// in production; the fixtures here
        // legitimately load over file://, so opt into the test seam.
        BrowserSession.allowFileURLsForTesting = true
        let executor = BrowserToolExecutor(
            agentId: agentId,
            toolCallId: "smoke-\(UUID().uuidString)",
            gate: BrowserGate(policy: .defaultPolicy),
            confirm: { _ in true }
        )
        defer {
            // Wipe the profile's WKWebsiteDataStore + catalog record, then
            // restore the override so later suites see their own catalog.
            BrowserSession.allowFileURLsForTesting = false
            Task { await BrowserSessionManager.shared.resetSession(for: agentId) }
            BrowserSessionCatalog.overrideDirectory = previousCatalogDir
            BrowserSessionCatalog.resetCacheForTests()
            try? FileManager.default.removeItem(at: dir)
        }
        try await body(executor, dir)
    }

    @Test func navigateReturnsASnapshotWithRefs() async throws {
        try await withSmokeExecutor { executor, fixtures in
            let url = try SmokeFixtures.write(SmokeFixtures.interactive, to: fixtures, name: "interactive")
            let result = await executor.execute(
                name: "browser_navigate",
                argumentsJSON: ##"{"url": "\##(url)", "detail": "standard"}"##
            )
            #expect(result.contains("navigate to"))
            #expect(result.contains("succeeded"))
            #expect(result.contains("[E"), "navigation must return element refs")
            #expect(result.contains("Interactive Fixture"))
            // Hidden elements are excluded by the visible-only default.
            #expect(!result.contains("hidden-btn"))
        }
    }

    @Test func typeThenSnapshotReflectsTheValue() async throws {
        try await withSmokeExecutor { executor, fixtures in
            let url = try SmokeFixtures.write(SmokeFixtures.loginForm, to: fixtures, name: "login")
            _ = await executor.execute(
                name: "browser_navigate", argumentsJSON: ##"{"url": "\##(url)", "detail": "none"}"##)
            let typed = await executor.execute(
                name: "browser_type",
                argumentsJSON: ##"{"selector": "#email", "text": "user@test.com", "detail": "standard"}"##
            )
            #expect(typed.contains("type succeeded"))
            #expect(typed.contains("user@test.com"), "auto-snapshot must reflect the typed value")
        }
    }

    @Test func batchDoRunsMultipleActionsAndReturnsOneSnapshot() async throws {
        try await withSmokeExecutor { executor, fixtures in
            let url = try SmokeFixtures.write(SmokeFixtures.loginForm, to: fixtures, name: "login")
            _ = await executor.execute(
                name: "browser_navigate", argumentsJSON: ##"{"url": "\##(url)", "detail": "none"}"##)
            let result = await executor.execute(
                name: "browser_do",
                argumentsJSON: """
                    {
                        "actions": [
                            {"action": "type", "selector": "#email", "text": "user@test.com"},
                            {"action": "type", "selector": "#password", "text": "pass123"},
                            {"action": "click", "selector": "#remember"}
                        ],
                        "detail": "standard"
                    }
                    """
            )
            #expect(result.contains("browser_do completed (3 actions)"))
            #expect(result.contains("[E"), "batch must end with one final snapshot")
        }
    }

    @Test func batchDoFailsFastWithIndexAndRecoverySnapshot() async throws {
        try await withSmokeExecutor { executor, fixtures in
            let url = try SmokeFixtures.write(SmokeFixtures.loginForm, to: fixtures, name: "login")
            _ = await executor.execute(
                name: "browser_navigate", argumentsJSON: ##"{"url": "\##(url)", "detail": "none"}"##)
            let result = await executor.execute(
                name: "browser_do",
                argumentsJSON: """
                    {
                        "actions": [
                            {"action": "type", "selector": "#email", "text": "hello"},
                            {"action": "click", "selector": "#no-such-element"},
                            {"action": "type", "selector": "#password", "text": "must not run"}
                        ],
                        "detail": "standard"
                    }
                    """
            )
            #expect(result.contains("Action 1 (click) failed"), "must identify the failing step")
            #expect(result.contains("snapshot"), "failure must carry a recovery snapshot")
            // Fail-fast: the third action never ran.
            let snapshot = await executor.execute(
                name: "browser_snapshot", argumentsJSON: ##"{"detail": "full"}"##)
            #expect(!snapshot.contains("must not run"))
        }
    }

    @Test func batchDoRejectsUnknownActionsAndMissingParams() async throws {
        try await withSmokeExecutor { executor, fixtures in
            let url = try SmokeFixtures.write(SmokeFixtures.loginForm, to: fixtures, name: "login")
            _ = await executor.execute(
                name: "browser_navigate", argumentsJSON: ##"{"url": "\##(url)", "detail": "none"}"##)

            let unknown = await executor.execute(
                name: "browser_do",
                argumentsJSON: ##"{"actions": [{"action": "fly", "selector": "#email"}]}"##)
            #expect(unknown.contains("unknown action type"))

            let missing = await executor.execute(
                name: "browser_do",
                argumentsJSON: ##"{"actions": [{"action": "type", "selector": "#email"}]}"##)
            #expect(missing.contains("missing required 'text' parameter"))

            let empty = await executor.execute(
                name: "browser_do", argumentsJSON: ##"{"actions": [], "detail": "none"}"##)
            #expect(empty.contains("browser_do completed (0 actions)"))
        }
    }

    @Test func refsGoStaleAcrossSnapshots() async throws {
        try await withSmokeExecutor { executor, fixtures in
            let url = try SmokeFixtures.write(SmokeFixtures.interactive, to: fixtures, name: "interactive")
            _ = await executor.execute(
                name: "browser_navigate", argumentsJSON: ##"{"url": "\##(url)", "detail": "compact"}"##)
            // Re-snapshot: the generation advances, invalidating earlier refs.
            _ = await executor.execute(
                name: "browser_snapshot", argumentsJSON: ##"{"detail": "compact"}"##)
            _ = await executor.execute(
                name: "browser_snapshot", argumentsJSON: ##"{"detail": "compact"}"##)
            // A click by ref from an old generation is refused, not misfired —
            // BrowserSession pins each ref map to its snapshot generation.
            let session = BrowserSessionManager.shared.activeAgentIds()
            #expect(!session.isEmpty)
            let stale = await executor.execute(
                name: "browser_click", argumentsJSON: ##"{"ref": "E999", "detail": "none"}"##)
            #expect(stale.contains("Element ref") || stale.contains("not found") || stale.contains("stale"))
        }
    }

    @Test func snapshotFiltersNarrowTheElementSet() async throws {
        try await withSmokeExecutor { executor, fixtures in
            let url = try SmokeFixtures.write(SmokeFixtures.interactive, to: fixtures, name: "interactive")
            _ = await executor.execute(
                name: "browser_navigate", argumentsJSON: ##"{"url": "\##(url)", "detail": "none"}"##)
            let links = await executor.execute(
                name: "browser_snapshot", argumentsJSON: ##"{"filter": "links", "detail": "standard"}"##)
            #expect(links.contains("Page 1"))
            #expect(!links.contains("Primary Action"), "links filter must exclude buttons")
        }
    }

    // MARK: - Hardening coverage

    @Test func fileURLsAreRefusedWithoutTheTestSeam() async throws {
        try await withSmokeExecutor { executor, fixtures in
            let url = try SmokeFixtures.write(SmokeFixtures.interactive, to: fixtures, name: "interactive")
            // Production posture: the seam off means file:// is a policy refusal.
            BrowserSession.allowFileURLsForTesting = false
            defer { BrowserSession.allowFileURLsForTesting = true }
            let result = await executor.execute(
                name: "browser_navigate", argumentsJSON: ##"{"url": "\##(url)"}"##)
            #expect(!ToolEnvelope.isSuccess(result))
            #expect(result.contains("Local file URLs are blocked"))
        }
    }

    @Test func readPageExtractsMainContentNotChrome() async throws {
        try await withSmokeExecutor { executor, fixtures in
            let url = try SmokeFixtures.write(SmokeFixtures.article, to: fixtures, name: "article")
            _ = await executor.execute(
                name: "browser_navigate", argumentsJSON: ##"{"url": "\##(url)", "detail": "none"}"##)
            let result = await executor.execute(name: "browser_read_page", argumentsJSON: "{}")
            #expect(ToolEnvelope.isSuccess(result))
            #expect(result.contains("The History of Fixtures"))
            #expect(result.contains("forty-two"))
            // <main> was selected as the extraction root, so nav/footer chrome
            // stays out of the text.
            #expect(!result.contains("Footer junk"))
            #expect(result.contains("total_chars"))
        }
    }

    @Test func navigateBackReturnsToThePreviousPage() async throws {
        try await withSmokeExecutor { executor, fixtures in
            let first = try SmokeFixtures.write(SmokeFixtures.interactive, to: fixtures, name: "interactive")
            let second = try SmokeFixtures.write(SmokeFixtures.loginForm, to: fixtures, name: "login")
            _ = await executor.execute(
                name: "browser_navigate", argumentsJSON: ##"{"url": "\##(first)", "detail": "none"}"##)
            _ = await executor.execute(
                name: "browser_navigate", argumentsJSON: ##"{"url": "\##(second)", "detail": "none"}"##)
            let back = await executor.execute(
                name: "browser_navigate_back", argumentsJSON: ##"{"detail": "standard"}"##)
            #expect(back.contains("navigate back succeeded"))
            #expect(back.contains("Interactive Fixture"), "back must land on the first page")
        }
    }

    @Test func navigateBackWithoutHistoryFailsTyped() async throws {
        try await withSmokeExecutor { executor, fixtures in
            let url = try SmokeFixtures.write(SmokeFixtures.interactive, to: fixtures, name: "interactive")
            _ = await executor.execute(
                name: "browser_navigate", argumentsJSON: ##"{"url": "\##(url)", "detail": "none"}"##)
            let back = await executor.execute(name: "browser_navigate_back", argumentsJSON: "{}")
            #expect(!ToolEnvelope.isSuccess(back))
            #expect(back.contains("No back history"))
        }
    }

    @Test func shadowDOMElementsAppearInSnapshots() async throws {
        try await withSmokeExecutor { executor, fixtures in
            let url = try SmokeFixtures.write(SmokeFixtures.shadowHost, to: fixtures, name: "shadow")
            let result = await executor.execute(
                name: "browser_navigate", argumentsJSON: ##"{"url": "\##(url)", "detail": "standard"}"##)
            #expect(result.contains("Shadow Button"), "open shadow roots must be pierced")
            #expect(result.contains("Light Button"), "light DOM must still be walked")
        }
    }

    @Test func targetBlankLinksLoadInTheSameWebView() async throws {
        try await withSmokeExecutor { executor, fixtures in
            _ = try SmokeFixtures.write(SmokeFixtures.secondPage, to: fixtures, name: "second")
            let url = try SmokeFixtures.write(SmokeFixtures.blankLink, to: fixtures, name: "blank")
            _ = await executor.execute(
                name: "browser_navigate", argumentsJSON: ##"{"url": "\##(url)", "detail": "none"}"##)
            _ = await executor.execute(
                name: "browser_click", argumentsJSON: ##"{"selector": "#blank-link", "detail": "none"}"##)
            // The new-window request loads in the SAME webview (createWebViewWith).
            let arrived = await executor.execute(
                name: "browser_wait_for", argumentsJSON: ##"{"text": "Arrived", "timeout": 10}"##)
            #expect(ToolEnvelope.isSuccess(arrived), "target=_blank must navigate the session")
        }
    }

    @Test func cookieValuesAreRedactedByDefault() async throws {
        try await withSmokeExecutor { executor, _ in
            let set = await executor.execute(
                name: "browser_cookies",
                argumentsJSON: ##"{"action": "set", "cookie": {"name": "session", "value": "secret123", "domain": "example.com"}}"##
            )
            #expect(ToolEnvelope.isSuccess(set))

            let redacted = await executor.execute(
                name: "browser_cookies", argumentsJSON: ##"{"action": "get"}"##)
            #expect(ToolEnvelope.isSuccess(redacted))
            #expect(!redacted.contains("secret123"), "cookie values must never leak by default")
            #expect(redacted.contains("<redacted>"))

            // include_values is consequential; the smoke confirm auto-approves.
            let full = await executor.execute(
                name: "browser_cookies", argumentsJSON: ##"{"action": "get", "include_values": true}"##)
            #expect(full.contains("secret123"), "approved include_values must return values")
        }
    }

    @Test func screenshotPathsOutsideDownloadsAreRefused() async throws {
        try await withSmokeExecutor { executor, _ in
            let result = await executor.execute(
                name: "browser_screenshot", argumentsJSON: ##"{"path": "/tmp/evil.png"}"##)
            #expect(!ToolEnvelope.isSuccess(result))
            #expect(result.contains("~/Downloads"))
            #expect(!FileManager.default.fileExists(atPath: "/tmp/evil.png"))
        }
    }

    @Test func pendingNavigationIsResolvedWhenSuperseded() async throws {
        try await withSmokeExecutor { executor, fixtures in
            let fixture = try SmokeFixtures.write(
                SmokeFixtures.interactive, to: fixtures, name: "interactive")
            // Touch the executor once so the session exists in the pool.
            _ = await executor.execute(
                name: "browser_navigate", argumentsJSON: ##"{"url": "\##(fixture)", "detail": "none"}"##)
            let manager = BrowserSessionManager.shared
            let agentId = try #require(manager.activeAgentIds().first)
            let session = manager.session(for: agentId)

            // Park a navigation on a non-routable address (long timeout), then
            // supersede it. Pre-fix, the first awaiter hung forever because
            // the second navigate silently replaced its continuation.
            let hanging = Task { await session.navigate(to: "https://10.255.255.1/never", timeout: 30) }
            try? await Task.sleep(nanoseconds: 300_000_000)
            let second = await session.navigate(to: fixture, timeout: 10)
            #expect(second.success, "the superseding navigation must succeed")

            let first = await hanging.value
            #expect(!first.success, "the superseded navigation must resolve with an error, not hang")
        }
    }

    @Test func idleSessionsAreReapedButOpenWindowsAndRunsAreNot() async throws {
        try await withSmokeExecutor { executor, fixtures in
            let url = try SmokeFixtures.write(SmokeFixtures.interactive, to: fixtures, name: "interactive")
            _ = await executor.execute(
                name: "browser_navigate", argumentsJSON: ##"{"url": "\##(url)", "detail": "none"}"##)
            let manager = BrowserSessionManager.shared
            let agentId = try #require(manager.activeAgentIds().first)

            // A pinned (in-run) session survives the reaper even when idle.
            manager.beginRun(for: agentId)
            manager.reapIdleSessions(now: Date(timeIntervalSinceNow: 3600))
            #expect(manager.activeAgentIds().contains(agentId))

            // Unpinned + idle past the threshold → closed.
            manager.endRun(for: agentId)
            manager.reapIdleSessions(now: Date(timeIntervalSinceNow: 3600))
            #expect(!manager.activeAgentIds().contains(agentId))
        }
    }
}
