//
//  BrowserSessionManager.swift
//  OsaurusCore — Native Browser Use
//
//  Pools one `BrowserSession` per agent, keyed by the persistent WebKit
//  profile UUID recorded in `BrowserSessionCatalog`. Replaces the plugin's
//  `SessionManager`: the host-bridge `profile_id` round-trip becomes a direct
//  catalog lookup (agent id → profile UUID) and the semaphore/lock pool
//  becomes plain `@MainActor` state.
//
//  Session reset deliberately wipes the store IN PLACE via
//  `removeData(ofTypes:modifiedSince:)` and then orphans the directory under a
//  freshly minted identifier. `WKWebsiteDataStore.remove(forIdentifier:)` races
//  with the WebKit networking XPC processes and segfaults the host — see the
//  plugin's SessionManager history for the full autopsy.
//

import AppKit
import Foundation
import WebKit

@MainActor
public final class BrowserSessionManager {
    public static let shared = BrowserSessionManager()

    /// Live sessions keyed by agent id.
    private var pool: [UUID: BrowserSession] = [:]
    /// Last time each pooled session was touched (for idle reclamation).
    private var lastUsed: [UUID: Date] = [:]
    /// Agents with a `browser_use` run in flight (refcounted). A run parked on
    /// an approval card must not have its page state reaped mid-run.
    private var activeRunCounts: [UUID: Int] = [:]
    /// Idle sessions are torn down after this long (their WKWebView + WebKit
    /// XPC processes go away; the profile restores at its last page on next
    /// use). Var so tests can shrink it.
    var idleCloseSeconds: TimeInterval = 15 * 60
    private var reaper: Task<Void, Never>?

    private init() {}

    // MARK: - Session access

    /// The agent's live session, creating (and marking active) on first call.
    func session(for agentId: UUID) -> BrowserSession {
        touch(agentId)
        if let existing = pool[agentId] { return existing }
        let profileId = BrowserSessionCatalog.profileId(for: agentId)
        let session = BrowserSession(profileId: profileId)
        pool[agentId] = session
        BrowserSessionCatalog.update(agentId: agentId) { record in
            record.isActive = true
            record.lastActivity = Date()
        }
        return session
    }

    // MARK: - Idle reclamation

    /// Mark a `browser_use` run in flight for this agent, pinning its session
    /// against the idle reaper (approval cards can park runs for a while).
    public func beginRun(for agentId: UUID) {
        activeRunCounts[agentId, default: 0] += 1
    }

    public func endRun(for agentId: UUID) {
        let next = (activeRunCounts[agentId] ?? 1) - 1
        if next <= 0 {
            activeRunCounts.removeValue(forKey: agentId)
            touch(agentId)
        } else {
            activeRunCounts[agentId] = next
        }
    }

    private func touch(_ agentId: UUID) {
        lastUsed[agentId] = Date()
        startReaperIfNeeded()
    }

    private func startReaperIfNeeded() {
        guard reaper == nil else { return }
        reaper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard let self else { return }
                self.reapIdleSessions()
                if self.pool.isEmpty {
                    self.reaper = nil
                    return
                }
            }
        }
    }

    /// Close sessions idle past the threshold. Skips agents with a run in
    /// flight and agents whose session window is open on screen.
    func reapIdleSessions(now: Date = Date()) {
        for agentId in Array(pool.keys) {
            guard activeRunCounts[agentId] == nil else { continue }
            guard !BrowserWindowController.hasOpenSessionWindow(for: agentId) else { continue }
            let last = lastUsed[agentId] ?? .distantPast
            guard now.timeIntervalSince(last) >= idleCloseSeconds else { continue }
            closeSession(for: agentId)
        }
    }

    /// The agent's live session if one exists in this run, else nil.
    func activeSession(for agentId: UUID) -> BrowserSession? {
        pool[agentId]
    }

    /// Agent ids that currently have a live session attached.
    public func activeAgentIds() -> [UUID] {
        Array(pool.keys)
    }

    // MARK: - Catalog observations

    /// Record the page an agent's session landed on: last URL / domain /
    /// title / activity, plus observed sign-in transitions. A navigation that
    /// lands on a login page marks the host `signInRequired`; a later page on
    /// a host previously marked `signInRequired` upgrades it to
    /// `observedSignedIn` (the login wall cleared). Cookie presence alone
    /// never flips status.
    func recordNavigation(agentId: UUID, url: String?, title: String?) {
        guard let url, let host = URL(string: url)?.host else { return }
        let loginHost = BrowserLoginDetector.loginHost(finalURL: url, title: title ?? "")
        BrowserSessionCatalog.update(agentId: agentId) { record in
            record.isActive = true
            record.lastURL = url
            record.lastDomain = host
            record.lastTitle = title
            record.lastActivity = Date()
            if let loginHost {
                record.services[loginHost] = .signInRequired
            } else if record.services[host] == .signInRequired {
                record.services[host] = .observedSignedIn
            }
        }
    }

    /// Record that the user completed a sign-in for a host (login window
    /// closed on a non-login page).
    func recordObservedSignIn(agentId: UUID, host: String) {
        guard !host.isEmpty else { return }
        BrowserSessionCatalog.update(agentId: agentId) { record in
            record.services[host] = .observedSignedIn
            record.lastActivity = Date()
        }
    }

    // MARK: - Login window

    /// Present the visible sign-in window on the agent's profile and wait for
    /// the user to close it (or the timeout). Observed sign-in status is
    /// updated from the window's final page.
    func presentLoginWindow(
        agentId: UUID,
        initialURL: URL?,
        timeoutSeconds: TimeInterval
    ) async -> BrowserWindowController.CloseResult {
        let profileId = BrowserSessionCatalog.profileId(for: agentId)
        let controller = BrowserWindowController(
            agentId: agentId,
            profileId: profileId,
            purpose: .login,
            liveWebView: nil,
            initialURL: initialURL
        )
        let result = await controller.presentAndWait(timeoutSeconds: timeoutSeconds)
        if let finalURL = result.finalURL,
            let host = URL(string: finalURL)?.host,
            BrowserLoginDetector.loginHost(finalURL: finalURL, title: "") == nil
        {
            recordObservedSignIn(agentId: agentId, host: host)
        }
        return result
    }

    /// Open (or focus) the settings-tab session window for an agent. When the
    /// session is live its actual WebView is attached; otherwise the saved
    /// profile is restored at its last page.
    public func openSessionWindow(for agentId: UUID) {
        let record = BrowserSessionCatalog.record(for: agentId)
        let profileId = record?.profileId ?? BrowserSessionCatalog.profileId(for: agentId)
        let live = pool[agentId]?.liveWebView
        let restoreURL = record?.lastURL.flatMap(URL.init(string:))
        BrowserWindowController.showSessionWindow(
            agentId: agentId,
            profileId: profileId,
            liveWebView: live,
            initialURL: live == nil ? restoreURL : nil
        )
    }

    // MARK: - Lifecycle / cleanup

    /// Detach an agent's live session without touching stored data (app is
    /// quitting or the settings tab asked to close the window/session).
    public func closeSession(for agentId: UUID) {
        lastUsed.removeValue(forKey: agentId)
        guard let session = pool.removeValue(forKey: agentId) else { return }
        session.tearDown()
        BrowserWindowController.closeSessionWindow(for: agentId)
        BrowserSessionCatalog.update(agentId: agentId) { $0.isActive = false }
    }

    /// Tear down every live session (app termination). Stored profiles and
    /// catalog records survive for the next run.
    public func shutdownAll() {
        for (agentId, session) in pool {
            session.tearDown()
            BrowserWindowController.closeSessionWindow(for: agentId)
            BrowserSessionCatalog.update(agentId: agentId) { $0.isActive = false }
        }
        pool.removeAll()
        lastUsed.removeAll()
        reaper?.cancel()
        reaper = nil
    }

    /// Wipe an agent's browser data and forget its session record. The next
    /// use mints a brand-new profile UUID, so the orphaned on-disk directory
    /// is never touched again. Used by session reset, agent deletion, and the
    /// settings tab's destructive reset.
    public func resetSession(for agentId: UUID) async {
        let record = BrowserSessionCatalog.record(for: agentId)
        let removed = pool.removeValue(forKey: agentId)
        lastUsed.removeValue(forKey: agentId)
        BrowserWindowController.closeSessionWindow(for: agentId)

        // Grab a strong data-store reference before tearing down the webview.
        let store: WKWebsiteDataStore?
        if let live = removed?.websiteDataStore {
            store = live
        } else if let profileId = record?.profileId {
            store = WKWebsiteDataStore(forIdentifier: profileId)
        } else {
            store = nil
        }
        removed?.tearDown()

        if let store {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                store.removeData(
                    ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                    modifiedSince: .distantPast
                ) {
                    continuation.resume()
                }
            }
        }
        BrowserSessionCatalog.remove(agentId: agentId)
    }

    /// Factory reset: wipe every known profile and the whole catalog.
    public func resetAllSessions() async {
        let agentIds = Set(BrowserSessionCatalog.allRecords().map(\.agentId))
            .union(pool.keys)
        for agentId in agentIds {
            await resetSession(for: agentId)
        }
        BrowserSessionCatalog.removeAll()
    }
}
