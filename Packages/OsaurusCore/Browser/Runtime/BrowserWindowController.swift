//
//  BrowserWindowController.swift
//  OsaurusCore — Native Browser Use
//
//  The one visible window for native browser sessions, adapted from the
//  plugin's `LoginWindow`. Two purposes share the same minimal chrome (back /
//  forward / reload / URL field / WKWebView):
//
//  - `.login` — awaited by the `browser_open_login` tool. The user signs in
//    with a webview on the SAME `WKWebsiteDataStore` identifier as the
//    headless session, so credentials flow straight back to the agent.
//  - `.session` — fire-and-forget, opened from the Browser settings tab. When
//    the agent's session is live, its actual WebView is attached (the session
//    keeps the navigation delegate; this window only observes via KVO).
//    Otherwise a fresh webview restores the saved profile at its last page.
//
//  No tabs, no extensions, no autofill — intentionally minimal.
//

import AppKit
import Foundation
import WebKit

@MainActor
final class BrowserWindowController: NSObject, NSWindowDelegate {
    enum Purpose {
        case login
        case session
    }

    struct CloseResult {
        let closedAt: Date
        let finalURL: String?
        let timedOut: Bool
    }

    private let agentId: UUID
    private let profileId: UUID
    private let purpose: Purpose
    /// Non-nil when embedding a live session's WebView; this controller does
    /// NOT own it and must never change its delegates or tear it down.
    private let borrowedWebView: WKWebView?
    private let initialURL: URL?

    private var window: NSWindow!
    private var webView: WKWebView!
    private var urlField: NSTextField!
    private var backButton: NSButton!
    private var forwardButton: NSButton!
    private var reloadButton: NSButton!
    private var observations: [NSKeyValueObservation] = []

    private var continuation: CheckedContinuation<CloseResult, Never>?
    private var didResume = false
    private var timeoutTask: Task<Void, Never>?

    // MARK: - Session-window registry (one window per agent)

    private static var sessionWindows: [UUID: BrowserWindowController] = [:]

    /// Open (or focus) the settings-tab session window for an agent.
    static func showSessionWindow(
        agentId: UUID,
        profileId: UUID,
        liveWebView: WKWebView?,
        initialURL: URL?
    ) {
        if let existing = sessionWindows[agentId] {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = BrowserWindowController(
            agentId: agentId,
            profileId: profileId,
            purpose: .session,
            liveWebView: liveWebView,
            initialURL: initialURL
        )
        sessionWindows[agentId] = controller
        controller.buildWindowIfNeeded()
        controller.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Close an agent's session window if open (session reset / teardown).
    /// Whether a settings-tab session window is currently open for this agent
    /// (the idle reaper must not yank a webview out from under it).
    static func hasOpenSessionWindow(for agentId: UUID) -> Bool {
        sessionWindows[agentId] != nil
    }

    static func closeSessionWindow(for agentId: UUID) {
        guard let controller = sessionWindows[agentId] else { return }
        controller.window?.close()
    }

    // MARK: - Init

    init(
        agentId: UUID,
        profileId: UUID,
        purpose: Purpose,
        liveWebView: WKWebView?,
        initialURL: URL?
    ) {
        self.agentId = agentId
        self.profileId = profileId
        self.purpose = purpose
        self.borrowedWebView = liveWebView
        self.initialURL = initialURL
        super.init()
    }

    /// Present the window and return when the user closes it (or the timeout
    /// fires). Used by the login flow.
    func presentAndWait(timeoutSeconds: TimeInterval) async -> CloseResult {
        return await withCheckedContinuation { (cont: CheckedContinuation<CloseResult, Never>) in
            self.continuation = cont
            buildWindowIfNeeded()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.finish(timedOut: true)
            }
        }
    }

    // MARK: - Window construction

    private func buildWindowIfNeeded() {
        guard window == nil else { return }

        if let borrowedWebView {
            webView = borrowedWebView
        } else {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = WKWebsiteDataStore(forIdentifier: profileId)
            // Look like a normal browser so login flows and risk-based 2FA
            // behave consistently with what the headless session reports.
            config.applicationNameForUserAgent = BrowserSession.desktopSafariUA
            webView = WKWebView(frame: .zero, configuration: config)
        }

        let contentRect = NSRect(x: 0, y: 0, width: 1100, height: 760)
        let win = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        switch purpose {
        case .login:
            win.title = L("Sign in — Osaurus Browser") + " (\(profileId.uuidString.prefix(8)))"
        case .session:
            let agentName = AgentManager.shared.agents.first(where: { $0.id == agentId })?.name
            win.title = L("Browser Session") + " — " + (agentName ?? L("Agent"))
        }
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self

        let toolbarHeight: CGFloat = 36
        let container = NSView(frame: contentRect)
        container.translatesAutoresizingMaskIntoConstraints = false

        backButton = NSButton(title: "◀", target: self, action: #selector(goBack))
        backButton.bezelStyle = .rounded
        forwardButton = NSButton(title: "▶", target: self, action: #selector(goForward))
        forwardButton.bezelStyle = .rounded
        reloadButton = NSButton(title: "⟳", target: self, action: #selector(reload))
        reloadButton.bezelStyle = .rounded

        urlField = NSTextField(string: initialURL?.absoluteString ?? webView.url?.absoluteString ?? "")
        urlField.placeholderString = L("Enter URL and press Return")
        urlField.target = self
        urlField.action = #selector(urlFieldEntered)
        urlField.usesSingleLineMode = true
        urlField.cell?.wraps = false
        urlField.cell?.isScrollable = true

        let toolbar = NSStackView(views: [backButton, forwardButton, reloadButton, urlField])
        toolbar.orientation = .horizontal
        toolbar.spacing = 6
        toolbar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        webView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(toolbar)
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: container.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: toolbarHeight),

            webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        win.contentView = container
        self.window = win

        // The navigation delegate may belong to the live session, so the
        // toolbar tracks state via KVO — works for both owned and borrowed
        // webviews.
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.updateNavState() }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.updateNavState() }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.updateNavState() }
            },
        ]

        if let url = initialURL {
            webView.load(URLRequest(url: url))
        } else if webView.url == nil {
            let body: String
            switch purpose {
            case .login:
                body = """
                    <h2>Sign in to a site</h2>
                    <p>Type a URL in the address bar above and press Return. Sign in to as many sites
                    as you like — cookies are saved per-agent and your agent's browser sessions will
                    inherit them automatically.</p>
                    <p>Close this window when you're done.</p>
                    """
            case .session:
                body = """
                    <h2>Browser session</h2>
                    <p>This agent hasn't visited any page yet. Type a URL in the address bar above
                    and press Return to browse as this agent.</p>
                    """
            }
            webView.loadHTMLString(
                "<html><body style=\"font-family:-apple-system;padding:40px;color:#333;\">\(body)</body></html>",
                baseURL: nil
            )
        }

        updateNavState()
    }

    private func updateNavState() {
        backButton?.isEnabled = webView?.canGoBack ?? false
        forwardButton?.isEnabled = webView?.canGoForward ?? false
        if let urlString = webView?.url?.absoluteString, urlString.hasPrefix("http") {
            urlField?.stringValue = urlString
        }
    }

    @objc private func goBack() { webView?.goBack() }
    @objc private func goForward() { webView?.goForward() }
    @objc private func reload() { webView?.reload() }

    @objc private func urlFieldEntered() {
        let raw = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        let normalized: String
        if raw.contains("://") {
            normalized = raw
        } else if raw.contains(".") && !raw.contains(" ") {
            normalized = "https://" + raw
        } else {
            normalized =
                "https://www.google.com/search?q="
                + (raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw)
        }
        guard let url = URL(string: normalized) else { return }
        webView.load(URLRequest(url: url))
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        finish(timedOut: false)
    }

    private func finish(timedOut: Bool) {
        guard !didResume else { return }
        didResume = true
        timeoutTask?.cancel()
        timeoutTask = nil
        observations = []

        let result = CloseResult(
            closedAt: Date(),
            finalURL: webView?.url?.absoluteString,
            timedOut: timedOut
        )

        // Detach (never tear down) a borrowed live-session webview.
        if borrowedWebView != nil {
            webView?.removeFromSuperview()
        }
        webView = nil

        if purpose == .session {
            Self.sessionWindows.removeValue(forKey: agentId)
            // Record where the user left the session so restore works even if
            // the agent never navigates again this run.
            if let finalURL = result.finalURL, finalURL.hasPrefix("http") {
                BrowserSessionManager.shared.recordNavigation(
                    agentId: agentId, url: finalURL, title: nil)
            }
        }
        if timedOut {
            window?.orderOut(nil)
            window?.close()
        }

        let cont = continuation
        continuation = nil
        cont?.resume(returning: result)
    }
}
