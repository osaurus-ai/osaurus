//
//  SupportService.swift
//  osaurus
//
//  Help: bug reports the user sends to the Osaurus team and the replies that
//  come back. Owns the list of the user's reports, the unread count behind
//  the Help badge, and the send / reply / mark-read calls.
//
//  Request budget (see docs/OSAURUS_ROUTER.md, "Help and Bug Reports"):
//  - There is no push. Replies are discovered by asking.
//  - Opening Help always refreshes.
//  - Launch, foreground activation and a poll while the app is in front
//    refresh only while the user has a report that is not closed
//    (`ai.osaurus.support.hasOpenThreads`), at most once per 5 minutes after
//    launch, and not at all when the Osaurus Cloud switch is off. A user who
//    never sent a report makes no `/support` calls.
//  - Sending and replying are explicit user actions and work with the Cloud
//    switch off: someone who turned Cloud off because it is broken must still
//    be able to say so.
//

import Foundation

@MainActor
final class SupportService: ObservableObject {
    static let shared = SupportService()

    /// Why a refresh is being considered. Decides the throttle applied.
    enum Trigger: String, Sendable {
        /// App launch. Only while a report is open; skipped if a fetch
        /// landed in the last minute.
        case launch
        /// Foreground activation. Only while a report is open, at most once
        /// per `replyCheckInterval`.
        case activation
        /// The tick while the app is in front (`startPolling`), so a reply
        /// lights the rail's Help dot without the user switching apps. Same
        /// rules as activation.
        case poll
        /// The user opened Help (or pulled to refresh). Always fetches.
        case helpOpened
    }

    /// The network surface, injectable so tests script the router.
    struct API: Sendable {
        var list: @Sendable () async throws -> OsaurusRouterSupportThreadsResponse
        var create: @Sendable (OsaurusRouterSupportReportBody) async throws -> OsaurusRouterSupportThread
        var detail: @Sendable (String) async throws -> OsaurusRouterSupportThread
        var reply: @Sendable (String, String) async throws -> OsaurusRouterSupportThread
        var markRead: @Sendable (String) async throws -> OsaurusRouterSupportThread

        static let live = API(
            list: { try await OsaurusRouterAPIClient.shared.supportThreads() },
            create: { try await OsaurusRouterAPIClient.shared.createSupportThread($0) },
            detail: { try await OsaurusRouterAPIClient.shared.supportThread(id: $0) },
            reply: { try await OsaurusRouterAPIClient.shared.replyToSupportThread(id: $0, body: $1) },
            markRead: { try await OsaurusRouterAPIClient.shared.markSupportThreadRead(id: $0) }
        )
    }

    /// Set while the user has at least one report that is not closed. The
    /// only thing that lets launch / activation spend a request.
    nonisolated static let hasOpenThreadsDefaultsKey = "ai.osaurus.support.hasOpenThreads"
    /// Floor between two background attempts, whatever the trigger.
    nonisolated static let minimumFetchSpacing: TimeInterval = 60
    /// Activation and poll refreshes are at most this frequent, so a reply
    /// reaches a user who keeps the app open within this window.
    nonisolated static let replyCheckInterval: TimeInterval = 5 * 60
    /// How often the poll asks `isFetchDue`. The check is free; the interval
    /// above decides when a request is actually sent.
    nonisolated static let pollTick: Duration = .seconds(60)
    /// Fallback backoff after a 429 with no parseable `retry-after`.
    nonisolated static let defaultRateLimitBackoff: TimeInterval = 10 * 60

    /// The user's reports, newest first, without messages.
    @Published private(set) var threads: [OsaurusRouterSupportThread] = []
    /// Reports with a reply the user has not opened: the Help badge.
    @Published private(set) var unreadCount = 0
    /// Full conversations fetched so far, by thread id.
    @Published private(set) var conversations: [String: OsaurusRouterSupportThread] = [:]
    /// True once a list fetch has succeeded in this run.
    @Published private(set) var hasLoaded = false
    @Published private(set) var isRefreshing = false
    /// Why the last list refresh failed, for the Help page. Cleared by the
    /// next success. Background triggers never surface it anywhere else.
    @Published private(set) var refreshError: String?

    /// What the user has typed into "Report a Problem" but not sent. Kept
    /// here, in memory only, so leaving Help to check something does not
    /// throw the description away. Not published: only the form reads it,
    /// once, when it appears.
    var draftDescription = ""

    /// Last successful list fetch, by the injected clock.
    private(set) var lastFetchedAt: Date?
    /// Last attempt (success or failure): spaces out retries after errors.
    private(set) var lastAttemptAt: Date?
    /// Earliest moment a background attempt may fire after a 429.
    private(set) var retryNotBefore: Date?

    private var inFlight: Task<Void, Never>?

    private let defaults: UserDefaults
    private let now: () -> Date
    private let api: API
    private let isRouterEnabled: () -> Bool
    private let hasIdentity: () -> Bool

    /// `shared` uses the standard defaults, wall clock and the live client;
    /// tests inject an isolated suite, a fixed instant and a scripted API.
    init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        api: API = .live,
        isRouterEnabled: @escaping () -> Bool = { OsaurusRouter.isEnabled },
        hasIdentity: @escaping () -> Bool = { OsaurusIdentity.existsCached() }
    ) {
        self.defaults = defaults
        self.now = now
        self.api = api
        self.isRouterEnabled = isRouterEnabled
        self.hasIdentity = hasIdentity
    }

    // MARK: - Refreshing

    /// Whether the user has a report that is not closed, as of the last
    /// time the list was known. Persisted so the next launch can decide
    /// without a request.
    var hasOpenThreads: Bool {
        defaults.bool(forKey: Self.hasOpenThreadsDefaultsKey)
    }

    /// Whether `refreshIfDue(trigger:)` would issue a request right now.
    /// Pure so the request budget is unit-testable without a fetch.
    func isFetchDue(trigger: Trigger) -> Bool {
        // Reports belong to a wallet; without one there is nothing to ask for
        // and signing would only fail.
        guard hasIdentity() else { return false }
        if trigger == .helpOpened { return true }

        guard isRouterEnabled(), hasOpenThreads else { return false }
        let instant = now()
        if let deadline = retryNotBefore, instant < deadline { return false }
        if let last = lastAttemptAt, instant.timeIntervalSince(last) < Self.minimumFetchSpacing {
            return false
        }
        if trigger == .activation || trigger == .poll, let last = lastFetchedAt {
            return instant.timeIntervalSince(last) >= Self.replyCheckInterval
        }
        return true
    }

    private var pollTask: Task<Void, Never>?

    /// Start the in-front poll once per process. `isAppActive` keeps a
    /// backgrounded app silent; activation catches up when it returns.
    func startPolling(isAppActive: @escaping @MainActor () -> Bool) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollTick)
                guard let self, !Task.isCancelled else { return }
                if isAppActive() { await self.refreshIfDue(trigger: .poll) }
            }
        }
    }

    /// Fetch the user's reports if the trigger's budget allows it.
    /// Concurrent callers share one in-flight request. Failures keep the
    /// previous list; only the Help page shows `refreshError`.
    func refreshIfDue(trigger: Trigger) async {
        if let inFlight {
            await inFlight.value
            return
        }
        guard isFetchDue(trigger: trigger) else { return }
        lastAttemptAt = now()
        isRefreshing = true
        let api = api
        let task = Task { [weak self] in
            do {
                let response = try await api.list()
                guard let self else { return }
                self.apply(list: response)
                self.lastFetchedAt = self.now()
                self.retryNotBefore = nil
                self.refreshError = nil
                self.hasLoaded = true
            } catch {
                guard let self else { return }
                if case .rateLimited(let retryAfter)? = error as? OsaurusRouterAPIError {
                    self.retryNotBefore = self.now().addingTimeInterval(
                        AnnouncementsService.backoffInterval(retryAfter: retryAfter, now: self.now()))
                }
                self.refreshError = Self.userMessage(for: error)
            }
        }
        inFlight = task
        await task.value
        inFlight = nil
        isRefreshing = false
    }

    // MARK: - Sending

    /// Send a new report. Call only after the user ticked the Terms and
    /// Privacy box; `report.body(description:)` carries `consent: true`.
    @discardableResult
    func submit(description: String, report: SupportReport) async throws -> OsaurusRouterSupportThread {
        let thread = try await api.create(report.body(description: description))
        store(conversation: thread)
        return thread
    }

    /// Fetch the full conversation for one report and cache it in
    /// `conversations`, which the thread page reads so it is never blank
    /// while a reload is in flight.
    @discardableResult
    func loadConversation(id: String) async throws -> OsaurusRouterSupportThread {
        let thread = try await api.detail(id)
        store(conversation: thread)
        return thread
    }

    /// The user answers. The router moves the thread back to `open`, which
    /// also reopens a closed one.
    @discardableResult
    func reply(threadId: String, body: String) async throws -> OsaurusRouterSupportThread {
        let thread = try await api.reply(threadId, body)
        store(conversation: thread)
        return thread
    }

    /// Clear the unread flag for a report the user is looking at. The badge
    /// drops immediately; a failed call is retried by the next open, and the
    /// next list refresh restores the truth either way.
    func markRead(threadId: String) async {
        guard let index = threads.firstIndex(where: { $0.id == threadId }), threads[index].unread
        else { return }
        setUnread(false, threadId: threadId)
        if let updated = try? await api.markRead(threadId) {
            replaceSummary(updated.summary)
        }
    }

    // MARK: - State

    private func apply(list response: OsaurusRouterSupportThreadsResponse) {
        threads = response.data.map(\.summary)
        unreadCount = response.unreadCount
        // Forget conversations for reports the router no longer lists.
        let ids = Set(threads.map(\.id))
        conversations = conversations.filter { ids.contains($0.key) }
        persistOpenFlag()
    }

    private func store(conversation thread: OsaurusRouterSupportThread) {
        conversations[thread.id] = thread
        replaceSummary(thread.summary)
    }

    /// Insert or update one row, keeping newest-first order and the derived
    /// unread count and open flag in step.
    private func replaceSummary(_ summary: OsaurusRouterSupportThread) {
        if let index = threads.firstIndex(where: { $0.id == summary.id }) {
            threads[index] = summary
        } else {
            threads.insert(summary, at: 0)
        }
        unreadCount = threads.filter(\.unread).count
        persistOpenFlag()
    }

    private func setUnread(_ unread: Bool, threadId: String) {
        guard let index = threads.firstIndex(where: { $0.id == threadId }) else { return }
        let current = threads[index]
        threads[index] = OsaurusRouterSupportThread(
            id: current.id, subject: current.subject, statusRaw: current.statusRaw, unread: unread,
            lastUserMessageAt: current.lastUserMessageAt,
            lastStaffMessageAt: current.lastStaffMessageAt,
            createdAt: current.createdAt, updatedAt: current.updatedAt, messages: nil)
        unreadCount = threads.filter(\.unread).count
    }

    private func persistOpenFlag() {
        let open = threads.contains(where: \.isOpen)
        if open != hasOpenThreads {
            defaults.set(open, forKey: Self.hasOpenThreadsDefaultsKey)
        }
    }

    /// Reports that count toward the router's cap of three not closed.
    var openThreadCount: Int { threads.filter(\.isOpen).count }

    // MARK: - Errors

    /// A sentence for the user. Router messages are written for logs, so the
    /// cases Help can hit are spelled out here.
    nonisolated static func userMessage(for error: Error) -> String {
        guard let routerError = error as? OsaurusRouterAPIError else {
            return L("Something went wrong. Please try again.")
        }
        switch routerError {
        case .noIdentity:
            return L("Set up your Osaurus ID to send reports and read replies.")
        case .rateLimited:
            return L("You have sent a lot in a short time. Please try again later.")
        case .transport:
            return L("Could not reach Osaurus. Check your connection and try again.")
        case .unauthorized:
            return L("Osaurus could not verify this Mac. Check that the date and time are correct, then try again.")
        case .accountFrozen:
            return L("Your Osaurus account is on hold, so reports cannot be sent from the app right now.")
        case .server(let code, _, let status):
            if code == "INVALID_STATE" {
                return L("You already have 3 open reports. Add to one of them, or wait until one is closed.")
            }
            if status == 413 {
                return L("This report is too large to send. Shorten the description and try again.")
            }
            if status == 404 {
                return L("This report is no longer available.")
            }
            if status >= 500 {
                return L("Osaurus had a problem on its side. Please try again in a moment.")
            }
            return L("That could not be sent. Please try again.")
        default:
            return L("Something went wrong. Please try again.")
        }
    }
}
