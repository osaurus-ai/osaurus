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

    static let dialogsAndUpload = """
        <!DOCTYPE html>
        <html><head><title>Dialog Fixture</title></head><body>
            <input type="file" id="upload">
        </body></html>
        """

    static let submissionControls = """
        <!DOCTYPE html><html><head><title>Submission Gate Fixture</title></head><body>
        <form id="form" onsubmit="event.preventDefault(); window.submissions++">
            <input id="name" aria-label="Full name">
            <button id="explicit" type="submit">Create demo account</button>
            <button id="implicit">Créer un compte</button>
            <button id="nested"><span id="nested-span">계정 만들기</span></button>
            <input id="image" type="image" alt="Continue">
            <input id="input-submit" type="submit" value="Weiter">
        </form>
        <button id="external" form="form">Continue</button>
        <button id="edit" type="button" onclick="window.edits++">Add to cart</button>
        <label for="check" id="check-label">Remember me</label><input id="check" type="checkbox">
        <button id="disabled" disabled>Disabled</button>
        <a id="link" href="#catalog">Catalog</a>
        <script>window.submissions = 0; window.edits = 0;</script>
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
        agentId: UUID = UUID(),
        policy: AutonomyPolicy = .defaultPolicy,
        forms: CUAFormsAgentRun? = nil,
        feed: SubagentFeed? = nil,
        isInterrupted: @escaping @Sendable () -> Bool = { false },
        confirm: @escaping @MainActor (ActionPreview) async -> Bool = { _ in true },
        _ body: (BrowserToolExecutor, _ fixtures: URL) async throws -> Void
    ) async rethrows {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-browser-smoke-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let previousCatalogDir = BrowserSessionCatalog.overrideDirectory
        BrowserSessionCatalog.overrideDirectory = dir
        BrowserSessionCatalog.resetCacheForTests()

        // The scheme policy blocks file:// in production; the fixtures here
        // legitimately load over file://, so opt into the test seam.
        BrowserSession.allowFileURLsForTesting = true
        let executor = BrowserToolExecutor(
            agentId: agentId,
            toolCallId: "smoke-\(UUID().uuidString)",
            gate: BrowserGate(policy: policy),
            forms: forms,
            feed: feed,
            isInterrupted: isInterrupted,
            confirm: confirm
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

    @Test func webKitDelegateHandlesDialogsAndDeclinesFileUpload() async throws {
        try await withSmokeExecutor { executor, fixtures in
            let url = try SmokeFixtures.write(
                SmokeFixtures.dialogsAndUpload,
                to: fixtures,
                name: "dialogs"
            )
            _ = await executor.execute(
                name: "browser_navigate",
                argumentsJSON: ##"{"url": "\##(url)", "detail": "none"}"##
            )
            let agentId = try #require(BrowserSessionManager.shared.activeAgentIds().first)
            let session = BrowserSessionManager.shared.session(for: agentId)

            let alert = await session.executeScript("alert('alert-marker'); return 'alert-done';")
            #expect(alert.error == nil)
            #expect(alert.result as? String == "alert-done")
            #expect(session.lastDialog?["kind"] as? String == "alert")
            #expect(session.lastDialog?["message"] as? String == "alert-marker")

            session.setDialogPolicy(accept: false, promptText: nil)
            let confirm = await session.executeScript("return confirm('confirm-marker');")
            #expect(confirm.error == nil)
            #expect(confirm.result as? Bool == false)
            #expect(session.lastDialog?["kind"] as? String == "confirm")
            #expect(session.lastDialog?["accepted"] as? Bool == false)

            session.setDialogPolicy(accept: true, promptText: "prompt-result")
            let prompt = await session.executeScript("return prompt('prompt-marker', 'default');")
            #expect(prompt.error == nil)
            #expect(prompt.result as? String == "prompt-result")
            #expect(session.lastDialog?["kind"] as? String == "prompt")
            #expect(session.lastDialog?["response"] as? String == "prompt-result")

            _ = await executor.execute(
                name: "browser_click",
                argumentsJSON: ##"{"selector": "#upload", "detail": "none"}"##
            )
            let status = await executor.execute(
                name: "browser_handle_dialog",
                argumentsJSON: ##"{"action": "status"}"##
            )
            #expect(status.contains("file_chooser"))
            #expect(status.contains("aren't supported"))
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

    // Regression: Gemma clicked a real form submit labelled "Create demo account"
    // without a consequential confirmation. Exercise DOM effects, not just labels.
    @Test(arguments: ["explicit", "implicit", "nested-span", "image", "input-submit", "external"], [false, true])
    func formSubmissionsCannotBypassDenial(selectorID: String, batched: Bool) async throws {
        let agentId = UUID()
        var effects: [EffectClass] = []
        try await withSmokeExecutor(
            agentId: agentId,
            confirm: { preview in
                effects.append(preview.effect)
                return false
            }
        ) { executor, fixtures in
            let url = try SmokeFixtures.write(SmokeFixtures.submissionControls, to: fixtures, name: "submit")
            _ = await executor.execute(
                name: "browser_navigate",
                argumentsJSON: ##"{"url":"\##(url)","detail":"none"}"##
            )
            let args =
                batched
                ? ##"{"actions":[{"action":"click","selector":"#\##(selectorID)"},{"action":"click","selector":"#edit"}],"detail":"none"}"##
                : ##"{"selector":"#\##(selectorID)","detail":"none"}"##
            let result = await executor.execute(name: batched ? "browser_do" : "browser_click", argumentsJSON: args)
            #expect(!ToolEnvelope.isSuccess(result))
            #expect(result.contains("declined"))
            #expect(effects == [.consequential])
            let state = await BrowserSessionManager.shared.session(for: agentId).executeScript(
                "return [window.submissions, window.edits];"
            )
            #expect(state.result as? [Int] == [0, 0], "Neither denied submit nor later batch action may run")
        }
    }

    @Test(arguments: [AutonomyPreset.balanced, .trusted])
    func approvedNativeSubmitExecutesExactlyOnce(preset: AutonomyPreset) async throws {
        let agentId = UUID()
        var effects: [EffectClass] = []
        try await withSmokeExecutor(
            agentId: agentId,
            policy: AutonomyPolicy(globalPreset: preset),
            confirm: { preview in
                effects.append(preview.effect)
                return true
            }
        ) { executor, fixtures in
            let url = try SmokeFixtures.write(SmokeFixtures.submissionControls, to: fixtures, name: "submit")
            _ = await executor.execute(
                name: "browser_navigate",
                argumentsJSON: ##"{"url":"\##(url)","detail":"none"}"##
            )
            let result = await executor.execute(
                name: "browser_click",
                argumentsJSON: ##"{"selector":"#explicit","detail":"none"}"##
            )
            #expect(ToolEnvelope.isSuccess(result))
            #expect(effects == [.consequential])
            let state = await BrowserSessionManager.shared.session(for: agentId).executeScript(
                "return window.submissions;"
            )
            #expect(state.result as? Int == 1)
        }
    }

    @Test func readOnlyBlocksStateChangingClicksButAllowsRealLinks() async throws {
        let agentId = UUID()
        var confirmations = 0
        try await withSmokeExecutor(
            agentId: agentId,
            policy: AutonomyPolicy(globalPreset: .readOnly),
            confirm: { _ in
                confirmations += 1
                return true
            }
        ) { executor, fixtures in
            let url = try SmokeFixtures.write(SmokeFixtures.submissionControls, to: fixtures, name: "readonly")
            _ = await executor.execute(
                name: "browser_navigate",
                argumentsJSON: ##"{"url":"\##(url)","detail":"none"}"##
            )
            for selector in ["#edit", "#check", "#check-label", "#explicit"] {
                let result = await executor.execute(
                    name: "browser_click",
                    argumentsJSON: ##"{"selector":"\##(selector)","detail":"none"}"##
                )
                #expect(!ToolEnvelope.isSuccess(result))
                #expect(result.contains("policy blocks"))
            }
            let link = await executor.execute(
                name: "browser_click",
                argumentsJSON: ##"{"selector":"#link","detail":"none"}"##
            )
            #expect(ToolEnvelope.isSuccess(link))
            #expect(confirmations == 0)
            let state = await BrowserSessionManager.shared.session(for: agentId).executeScript(
                "return [window.submissions, window.edits, document.querySelector('#check').checked ? 1 : 0];"
            )
            #expect(state.result as? [Int] == [0, 0, 0])
        }
    }

    @Test(arguments: [
        "el.type = 'submit'; el.setAttribute('form', 'form');",
        "el.outerHTML = el.outerHTML;",
        "el.setAttribute('aria-label', 'Different action');",
        "el.disabled = true;",
        "el.insertAdjacentHTML('afterend', el.outerHTML);",
    ])
    func targetChangesDuringApprovalDoNotExecute(mutation: String) async throws {
        let agentId = UUID()
        var confirmations = 0
        try await withSmokeExecutor(
            agentId: agentId,
            confirm: { preview in
                confirmations += 1
                #expect(preview.effect == .edit)
                let change = await BrowserSessionManager.shared.session(for: agentId).executeScript(
                    "const el = document.querySelector('#edit'); \(mutation) return true;"
                )
                #expect(change.error == nil)
                return true
            }
        ) { executor, fixtures in
            let url = try SmokeFixtures.write(SmokeFixtures.submissionControls, to: fixtures, name: "changing")
            _ = await executor.execute(
                name: "browser_navigate",
                argumentsJSON: ##"{"url":"\##(url)","detail":"none"}"##
            )
            let result = await executor.execute(
                name: "browser_click",
                argumentsJSON: ##"{"selector":"#edit","detail":"none"}"##
            )
            #expect(!ToolEnvelope.isSuccess(result))
            #expect(confirmations == 1)
            let state = await BrowserSessionManager.shared.session(for: agentId).executeScript(
                "return [window.submissions, window.edits];"
            )
            #expect(state.result as? [Int] == [0, 0])
        }
    }

    @Test func browserFormAdapterBindsValuesAndExcludesUnsupportedControls() async throws {
        let agentId = UUID()
        try await withSmokeExecutor(agentId: agentId) { executor, fixtures in
            let url = try SmokeFixtures.write(SmokeFixtures.loginForm, to: fixtures, name: "form-fields")
            _ = await executor.execute(
                name: "browser_navigate",
                argumentsJSON: ##"{"url":"\##(url)","detail":"none"}"##
            )
            let session = BrowserSessionManager.shared.session(for: agentId)
            let captured = try await session.captureFormFields()
            #expect(captured.fields.count == 1, "Password, checkbox and button are not S1 text-fill targets")
            let field = try #require(captured.fields.first)
            try await session.fillFormField(field, value: "a@example.test")
            let state = await session.executeScript(
                "return [document.querySelector('#email').value, document.querySelector('#password').value];"
            )
            #expect(state.result as? [String] == ["a@example.test", ""])
            await #expect(throws: CUAFormsError.self) { try await session.fillFormField(field, value: "overwritten") }
        }
    }

    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["CUA_FORMS_REFERENCE_DIR"] != nil),
        arguments: ["apply", "revoke", "interrupt", "decline", "partialRevoke"]
    )
    func nativeS1BrowserFillUsesGrantedProfileAndHonorsRevocation(mode: String) async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CUA_FORMS_REFERENCE_DIR"]))
        let agentId = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("s1-grant-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = CUAFormProfile(
            name: "Synthetic",
            entities: [
                CUAFormEntity(label: "Name", value: "Avery Stone"),
                CUAFormEntity(label: "Email", value: "a@example.test"),
            ]
        )
        let config = CUAFormsConfiguration(
            enabled: true,
            modelDirectory: root.appendingPathComponent("scorer").path,
            profiles: [profile],
            agentGrants: [CUAFormAgentGrant(agentID: agentId, profileID: profile.id)]
        )
        let store = CUAFormContextStore(directory: directory)
        try await store.save(config)
        let context = try #require(try CUAFormsRunContext.resolve(configuration: config, agentID: agentId))
        let run = CUAFormsAgentRun(context: context, store: store)
        let interrupt = InterruptToken()
        var confirmations = 0
        try await withSmokeExecutor(
            agentId: agentId,
            forms: run,
            isInterrupted: { interrupt.isInterrupted },
            confirm: { _ in
                confirmations += 1
                if mode == "revoke" || (mode == "partialRevoke" && confirmations == 2) {
                    var denied = config; denied.agentGrants = []; try? await store.save(denied)
                }
                if mode == "interrupt" { interrupt.interrupt() }
                return mode != "decline"
            }
        ) { executor, fixtures in
            let url = try SmokeFixtures.write(
                """
                <html><head><title>Contact form</title></head><body>
                <form onsubmit="event.preventDefault(); window.submissions++">
                  <label>Full name<input id="name"></label><label>Email address<input id="email" type="email"></label>
                  <button>Create account</button>
                </form><script>window.submissions=0;</script></body></html>
                """,
                to: fixtures,
                name: "native-s1"
            )
            _ = await executor.execute(
                name: "browser_navigate",
                argumentsJSON: ##"{"url":"\##(url)","detail":"none"}"##
            )
            let result = await executor.execute(name: "browser_fill_form", argumentsJSON: "{}")
            #expect(ToolEnvelope.isSuccess(result) == (mode == "apply"))
            let receipt = try #require(await run.receipt())
            #expect(receipt.batches == 1 && receipt.scoredFields == 2)
            let count = mode == "apply" ? 2 : (mode == "partialRevoke" ? 1 : 0)
            #expect(receipt.appliedFields == count)
            #expect(confirmations == (["apply", "partialRevoke"].contains(mode) ? 2 : 1))
            let state = await BrowserSessionManager.shared.session(for: agentId).executeScript(
                "return [document.querySelector('#name').value, document.querySelector('#email').value, String(window.submissions)];"
            )
            #expect(
                state.result as? [String] == [count > 0 ? "Avery Stone" : "", count == 2 ? "a@example.test" : "", "0"]
            )
        }
    }

    @Test func formsToolCannotRunWithoutAGrant() async throws {
        await withSmokeExecutor { executor, _ in
            let result = await executor.execute(name: "browser_fill_form", argumentsJSON: "{}")
            #expect(!ToolEnvelope.isSuccess(result))
            #expect(result.contains("No form profile"))
        }
    }

    @Test func ambiguousAndDisabledTargetsFailBeforeConfirmation() async throws {
        var confirmations = 0
        try await withSmokeExecutor(confirm: { _ in
            confirmations += 1; return true
        }) { executor, fixtures in
            let url = try SmokeFixtures.write(SmokeFixtures.submissionControls, to: fixtures, name: "unresolved")
            _ = await executor.execute(
                name: "browser_navigate",
                argumentsJSON: ##"{"url":"\##(url)","detail":"none"}"##
            )
            for selector in ["button", "#disabled", "#missing"] {
                let result = await executor.execute(
                    name: "browser_click",
                    argumentsJSON: ##"{"selector":"\##(selector)","detail":"none"}"##
                )
                #expect(!ToolEnvelope.isSuccess(result))
            }
            #expect(confirmations == 0)
        }
    }
}
