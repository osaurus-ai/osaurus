//
//  AnnouncementsService.swift
//  osaurus
//
//  Router-served community announcements (launches, events, heads-ups).
//  The router owns copy, artwork, CTAs, and the live window, so nothing
//  about a campaign is hard-coded in the app or needs a release to change.
//
//  Contract (see docs/osaurus-integration.md in osaurus-router):
//  - `GET /announcements?app_version=…` is unauthenticated, IP rate-limited,
//    and returns only what is live right now by the router's clock. The
//    client never re-evaluates the schedule locally.
//  - `slug` is the dismissal key: `ai.osaurus.announcement.<slug>.seen`.
//  - The router counts each feed response that includes an announcement as
//    a "delivery", so fetches stay on the natural triggers (launch and
//    foreground activation) — never a timer. On top of the contract this
//    service throttles activation fetches to once per 30 minutes so a user
//    Cmd-Tabbing all day is not a stream of requests.
//  - Failures of any kind mean "no announcements": never block launch and
//    never surface an error.
//
//  This type owns fetching, throttling, eligibility and the persisted seen
//  flags; presentation and the "don't stack" deferrals live in
//  `AppDelegate.presentAnnouncementIfEligible()`.
//

import Foundation

@MainActor
final class AnnouncementsService: ObservableObject {
    static let shared = AnnouncementsService()

    /// Why a fetch is being considered. Decides the throttle applied.
    enum Trigger: String, Sendable {
        /// App launch (non-silent). Fetched unless one landed in the last minute.
        case launch
        /// Foreground activation. Fetched at most once per `activationRefreshInterval`.
        case activation
        /// DEBUG dock item / tests: bypasses the throttles (still honors a 429).
        case debug
    }

    /// Floor between any two fetches, whatever the trigger (except `.debug`).
    nonisolated static let minimumFetchSpacing: TimeInterval = 60
    /// Activation fetches are at most this frequent. Propagation of a new
    /// announcement to a user who keeps the app open is therefore bounded
    /// by this plus the router's 60 s `Cache-Control`.
    nonisolated static let activationRefreshInterval: TimeInterval = 30 * 60
    /// Fallback backoff after a 429 with no parseable `retry-after`.
    nonisolated static let defaultRateLimitBackoff: TimeInterval = 10 * 60

    nonisolated static func seenDefaultsKey(for slug: String) -> String {
        "ai.osaurus.announcement.\(slug).seen"
    }

    /// Announcements from the last successful fetch, in server order
    /// (`priority desc`, then most recently started). Kept across failed
    /// refreshes so a transient outage cannot hide a live announcement.
    @Published private(set) var announcements: [OsaurusRouterAnnouncement] = []
    /// Informational router clock from the last successful fetch.
    private(set) var serverTime: String?
    /// Last successful fetch, by the injected clock; nil until one lands.
    private(set) var lastFetchedAt: Date?
    /// Last attempt (success or failure) — spaces out retries after errors.
    private(set) var lastAttemptAt: Date?
    /// Earliest moment the next attempt may fire after a 429.
    private(set) var retryNotBefore: Date?
    /// True while a dialog is on screen. In-memory only: repeated
    /// activation notifications during a presentation must not stack a
    /// second copy, but a check that never presented must not consume
    /// eligibility either.
    private(set) var isPresenting = false

    private var inFlight: Task<Void, Never>?

    private let defaults: UserDefaults
    private let now: () -> Date
    private let fetch: @Sendable (String?) async throws -> OsaurusRouterAnnouncementsResponse
    private let appVersion: () -> String?
    private let isRouterEnabled: () -> Bool

    /// `shared` uses the standard defaults, wall clock, the live API client
    /// and the bundle version; tests inject an isolated suite, a fixed
    /// instant and a scripted fetch.
    init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        fetch: (@Sendable (String?) async throws -> OsaurusRouterAnnouncementsResponse)? = nil,
        appVersion: @escaping () -> String? = {
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        },
        isRouterEnabled: @escaping () -> Bool = { OsaurusRouter.isEnabled }
    ) {
        self.defaults = defaults
        self.now = now
        self.fetch = fetch ?? { try await OsaurusRouterAPIClient.shared.announcements(appVersion: $0) }
        self.appVersion = appVersion
        self.isRouterEnabled = isRouterEnabled
    }

    // MARK: - Fetching

    /// Whether `refreshIfDue(trigger:)` would issue a request right now.
    /// Pure so the throttle contract is unit-testable without a fetch.
    func isFetchDue(trigger: Trigger) -> Bool {
        guard isRouterEnabled() else { return false }
        let instant = now()
        if let deadline = retryNotBefore, instant < deadline { return false }
        if trigger == .debug { return true }
        if let last = lastAttemptAt, instant.timeIntervalSince(last) < Self.minimumFetchSpacing {
            return false
        }
        if trigger == .activation, let last = lastFetchedAt,
            instant.timeIntervalSince(last) < Self.activationRefreshInterval
        {
            return false
        }
        return true
    }

    /// Fetch the live feed if the trigger's throttle allows it. Concurrent
    /// callers share one in-flight request. Returns when the attempt (if
    /// any) has settled, so the caller can present from `announcements`.
    func refreshIfDue(trigger: Trigger) async {
        if let inFlight {
            await inFlight.value
            return
        }
        guard isFetchDue(trigger: trigger) else { return }
        lastAttemptAt = now()
        let version = appVersion()
        let fetch = fetch
        let task = Task { [weak self] in
            do {
                let response = try await fetch(version)
                guard let self else { return }
                self.announcements = response.announcements
                self.serverTime = response.serverTime
                self.lastFetchedAt = self.now()
                self.retryNotBefore = nil
            } catch let error as OsaurusRouterAPIError {
                guard let self else { return }
                if case .rateLimited(let retryAfter) = error {
                    // Strict dedicated limit — honor `retry-after`, fall back
                    // to a conservative pause when it's absent/unparseable.
                    self.retryNotBefore = self.now().addingTimeInterval(
                        Self.backoffInterval(retryAfter: retryAfter))
                }
                // Every other failure (transport, non-200, malformed body):
                // keep the previous list; the next natural trigger retries.
            } catch {
                // Transport-level failure: same — silent, retry later.
            }
        }
        inFlight = task
        await task.value
        inFlight = nil
    }

    /// Seconds to wait after a 429. `retry-after` arrives as delta-seconds
    /// or an HTTP-date; anything unparseable gets the conservative default.
    nonisolated static func backoffInterval(retryAfter: String?, now: Date = Date()) -> TimeInterval {
        guard let raw = retryAfter?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else { return defaultRateLimitBackoff }
        if let seconds = TimeInterval(raw), seconds > 0 {
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'"
        if let date = formatter.date(from: raw) {
            return max(1, date.timeIntervalSince(now))
        }
        return defaultRateLimitBackoff
    }

    // MARK: - Eligibility

    /// Whether the user has already dismissed this slug (any dismissal
    /// path). Persisted, so it survives restarts and app updates.
    func hasSeen(_ slug: String) -> Bool {
        defaults.bool(forKey: Self.seenDefaultsKey(for: slug))
    }

    /// The announcement that may be presented right now, or `nil`: the first
    /// (server order) renderable, unseen one. Purely the service's own gates
    /// — the caller layers UI-coordination deferrals on top. Nothing is
    /// eligible while a dialog is already on screen.
    var eligibleAnnouncement: OsaurusRouterAnnouncement? {
        guard !isPresenting else { return nil }
        return announcements.first { $0.isRenderable && !hasSeen($0.slug) }
    }

    /// Call at the moment of presentation. Marks the slug seen immediately
    /// so its dialog can never appear a second time — even if the app quits
    /// mid-presentation — and guards duplicate activations while it is up.
    func willPresent(_ announcement: OsaurusRouterAnnouncement) {
        isPresenting = true
        markSeen(announcement.slug)
    }

    /// Call from the dialog's dismiss path (any button, Escape, outside
    /// click, or host teardown all funnel through it).
    func didDismiss() {
        isPresenting = false
    }

    /// Idempotent; safe to call from every dismissal path.
    func markSeen(_ slug: String) {
        defaults.set(true, forKey: Self.seenDefaultsKey(for: slug))
    }

    #if DEBUG
        /// Dock-menu "Reset Announcements & Fetch": forget every seen flag for
        /// the currently cached slugs and allow an immediate refetch, so the
        /// normal eligibility/presentation path can run on demand.
        func resetForDebugTesting() {
            for announcement in announcements {
                defaults.removeObject(forKey: Self.seenDefaultsKey(for: announcement.slug))
            }
            retryNotBefore = nil
            lastAttemptAt = nil
            lastFetchedAt = nil
            isPresenting = false
        }
    #endif
}
