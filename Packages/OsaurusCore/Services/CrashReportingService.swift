//
//  CrashReportingService.swift
//  osaurus
//
//  Crash + app-hang reporting via the Sentry Cocoa SDK. Wraps the SDK so the
//  rest of the app never imports Sentry directly and every lifecycle decision
//  flows through one gate.
//
//  Consent is independent from usage analytics (`TelemetryService`). Crash
//  reporting is *opt-out*: enabled by default and active from launch unless the
//  user has explicitly turned it off (onboarding, the existing-user prompt, or
//  Settings → Privacy). Crashes carry no PII (see `startSentry`), so defaulting
//  on maximises the signal that actually helps fix what breaks; analytics, by
//  contrast, stays opt-in.
//

import Foundation
import Sentry

@MainActor
public final class CrashReportingService {
    public static let shared = CrashReportingService()

    /// Sentry environment, decided at compile time, mirroring
    /// `TelemetryService`'s tracking mode: DEBUG crashes land in a `debug`
    /// environment so local testing never pollutes the production issue
    /// stream, Release reports as `production`.
    #if DEBUG
        private static let environment = "debug"
    #else
        private static let environment = "production"
    #endif

    /// `UserDefaults` flag the consent UI toggles. Crash reporting is opt-out,
    /// so the key is read as "enabled unless explicitly false": absent (a fresh
    /// install or a user who never touched it) = on; `false` = the user turned
    /// it off.
    private static let consentKey = "crashReportingEnabled"

    /// Whether `SentrySDK.start` has been called this process. Guards against
    /// double-starts and lets `setEnabled(false)` know there's something to
    /// tear down.
    private var started = false
    public var isStarted: Bool { started }

    // MARK: - Testing seam

    /// Where the consent decision is persisted. Injectable so unit tests can
    /// use an isolated suite instead of polluting `.standard`.
    private let defaults: UserDefaults

    /// Resolves the Sentry DSN. Production reads it from the build config /
    /// Info.plist; tests inject a value (or nil to simulate a keyless build).
    private let resolveDSN: @MainActor () -> String?

    /// Boots the SDK with the resolved DSN + environment. Production wires the
    /// real Sentry start; tests inject a capture closure so the consent +
    /// lifecycle behaviour can be verified without the SDK (and without a DSN).
    private let startSDK: @MainActor (_ dsn: String, _ environment: String) -> Void

    /// Tears the SDK down. Production calls `SentrySDK.close()`; tests record it.
    private let closeSDK: @MainActor () -> Void

    /// Default init wires everything to production (consent persisted in
    /// `.standard`, DSN from Info.plist, start/close to the Sentry SDK);
    /// `shared` uses it. The parameters exist purely as a testing seam —
    /// `init` is `internal`, so the app (which links OsaurusCore as a product)
    /// still can't construct its own instance.
    init(
        defaults: UserDefaults = .standard,
        resolveDSN: @escaping @MainActor () -> String? = CrashReportingService.resolveDSNFromConfig,
        startSDK: @escaping @MainActor (_ dsn: String, _ environment: String) -> Void =
            CrashReportingService.startSentry,
        closeSDK: @escaping @MainActor () -> Void = { SentrySDK.close() }
    ) {
        self.defaults = defaults
        self.resolveDSN = resolveDSN
        self.startSDK = startSDK
        self.closeSDK = closeSDK
    }

    // MARK: - Consent

    /// Whether crash reporting is enabled. Opt-out: true unless the user has
    /// explicitly turned it off, so a fresh install (absent key) reports on.
    public var isEnabled: Bool {
        defaults.object(forKey: Self.consentKey) as? Bool ?? true
    }

    // MARK: - Lifecycle

    /// Start crash reporting iff it's enabled and a DSN is configured. Call
    /// once from `applicationDidFinishLaunching`, as early as possible so the
    /// crash handler is installed before risky startup work.
    ///
    /// Idempotent, and a silent no-op when crash reporting is disabled or no DSN
    /// is configured — so contributor builds without a DSN never phone home.
    /// Because reporting is opt-out (enabled by default), this boots Sentry on
    /// the very first launch, so even first-run crashes are captured unless the
    /// user has turned it off.
    public func startIfConsented() {
        guard !started else { return }
        guard isEnabled else { return }
        guard let dsn = resolveDSN(), !dsn.isEmpty else { return }
        startSDK(dsn, Self.environment)
        started = true
    }

    /// Record the consent decision and act on it. Persists the choice, then
    /// starts the SDK if enabled (the crash handler becomes active immediately,
    /// covering the rest of this session) or closes it if disabled so nothing
    /// further is sent. Called from the onboarding consent step and
    /// Settings → Privacy.
    public func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.consentKey)
        if enabled {
            startIfConsented()
        } else {
            guard started else { return }
            closeSDK()
            started = false
        }
    }

    // MARK: - Runtime telemetry

    /// Run `body` with Sentry's app-hang watchdog paused.
    ///
    /// Use for work that is *expected* to block the main thread for a while — e.g. a
    /// synchronous accessibility/automation plugin call that drives another app and waits on
    /// it — so a legitimately long operation isn't reported as a false-positive app hang.
    /// Other main-thread hangs stay covered. A no-op (just runs `body`) when crash reporting
    /// isn't running.
    public func withAppHangTrackingPaused<T>(_ body: () throws -> T) rethrows -> T {
        guard started else { return try body() }
        SentrySDK.pauseAppHangTracking()
        defer { SentrySDK.resumeAppHangTracking() }
        return try body()
    }

    /// Record a breadcrumb on the active Sentry scope so the next captured event (e.g. an app
    /// hang) shows what was happening. Pass identifiers only — never user content or PII.
    ///
    /// `static` and `nonisolated` so hot, off-main paths (such as plugin tool invocation) can
    /// annotate without hopping to the main actor, which can deadlock when the main thread is
    /// busy. A no-op when crash reporting isn't running (Sentry drops breadcrumbs with no SDK).
    ///
    /// Each breadcrumb is also mirrored as a structured Sentry Log row. Breadcrumbs only
    /// travel attached to a captured event, so a release with few events has almost no
    /// queryable timeline — the 0.22.6 triage had zero Logs rows to correlate hangs against.
    /// The mirror gives release triage a searchable stream (same category/message contract:
    /// identifiers only) without instrumenting every call site twice.
    public nonisolated static func recordBreadcrumb(category: String, message: String) {
        guard SentrySDK.isEnabled else { return }
        // Serialize/record off the caller's thread: `addBreadcrumb` serializes
        // the crumb (including an ICU date-format of its timestamp), which has
        // stalled the main thread for seconds under memory pressure. The
        // serial queue preserves breadcrumb ordering; the timestamp is stamped
        // at `Breadcrumb` init inside the block, a few ms after the call.
        breadcrumbQueue.async {
            let crumb = Breadcrumb(level: .info, category: category)
            crumb.message = message
            SentrySDK.addBreadcrumb(crumb)
            SentrySDK.logger.info(message, attributes: ["category": category])
        }
    }

    private nonisolated static let breadcrumbQueue = DispatchQueue(
        label: "com.dinoki.osaurus.crash-breadcrumbs", qos: .utility)

    // MARK: - Main-thread stall reporting

    /// Privacy-safe description of one operation in flight during a stall
    /// (identifiers only — never content, paths, or account names).
    public struct StallOperation: Sendable {
        public let subsystem: String
        public let operation: String
        public let ageSeconds: TimeInterval

        public init(subsystem: String, operation: String, ageSeconds: TimeInterval) {
            self.subsystem = subsystem
            self.operation = operation
            self.ageSeconds = ageSeconds
        }
    }

    /// Report a `MainThreadWatchdog` breach to Sentry as a first-class event.
    ///
    /// The event is fingerprinted on the longest-running instrumented
    /// operation, so a Keychain stall, a database stall, and an AX stall
    /// become separate, individually-actionable issue groups instead of
    /// collapsing into one omnibus "app hang" bucket. The watchdog throttles
    /// calls (one per stall episode, minimum interval between reports);
    /// this method assumes that and always records.
    ///
    /// `static`/`nonisolated`: called from the watchdog's background queue
    /// while the main thread is — by definition — blocked. Must never hop
    /// to the main actor.
    public nonisolated static func recordMainThreadStall(
        thresholdSeconds: TimeInterval,
        operations: [StallOperation]
    ) {
        guard SentrySDK.isEnabled else { return }
        breadcrumbQueue.async {
            let primary = operations.max(by: { $0.ageSeconds < $1.ageSeconds })
            let opsSummary =
                operations.isEmpty
                ? "none"
                : operations
                    .map { "\($0.subsystem).\($0.operation)(\(Int($0.ageSeconds))s)" }
                    .joined(separator: ",")

            let event = Event(level: .warning)
            event.message = SentryMessage(
                formatted:
                    "Main thread blocked >\(Int(thresholdSeconds))s — \(primary.map { "\($0.subsystem).\($0.operation)" } ?? "uninstrumented")"
            )
            // Stable, operation-based grouping. Uninstrumented stalls share
            // one group ("uninstrumented") — a signal that ledger coverage
            // is missing where users actually hang.
            event.fingerprint = [
                "main-thread-stall",
                primary?.subsystem ?? "uninstrumented",
                primary?.operation ?? "unknown",
            ]
            event.tags = [
                "stall.subsystem": primary?.subsystem ?? "uninstrumented",
                "stall.operation": primary?.operation ?? "unknown",
            ]
            event.context = [
                "main_thread_stall": [
                    "threshold_seconds": thresholdSeconds,
                    "operations": opsSummary,
                ]
            ]
            SentrySDK.capture(event: event)
        }
    }

    // MARK: - DSN resolution

    /// Key precedence mirrors `TelemetryService.resolveAppKey()`:
    ///   1. (DEBUG only) `SENTRY_DSN` environment variable — optional override
    ///      for one-off local runs; never committed.
    ///   2. `SentryDSN` in Info.plist, populated by the `$(SENTRY_DSN)` build
    ///      setting. In DEBUG that comes from the gitignored
    ///      `App/osaurus/Secrets.xcconfig`; in Release it's injected by CI.
    /// The env-var path is compiled out of Release builds. Returns nil when no
    /// DSN is found so crash reporting stays disabled.
    private static func resolveDSNFromConfig() -> String? {
        #if DEBUG
            if let env = ProcessInfo.processInfo.environment["SENTRY_DSN"],
                !env.isEmpty
            {
                return env
            }
        #endif
        if let plist = Bundle.main.object(forInfoDictionaryKey: "SentryDSN") as? String,
            !plist.isEmpty
        {
            #if DEBUG
                // Common footgun: an `.xcconfig` treats `//` as a comment, so a
                // raw `https://…@…/…` DSN gets truncated to `https:` — non-empty
                // (so it passes the gate) but unparseable, and Sentry silently
                // disables itself. Flag it loudly rather than failing quietly.
                if !plist.contains("://") {
                    NSLog(
                        "[Osaurus] SENTRY_DSN looks truncated (\"%@\"). An xcconfig treats "
                            + "// as a comment — escape the scheme slashes in Secrets.xcconfig "
                            + "(e.g. SLASH = / then https:$(SLASH)$(SLASH)…).",
                        plist
                    )
                }
            #endif
            return plist
        }
        return nil
    }

    // MARK: - SDK configuration

    /// The production `SentrySDK.start`. Deliberately lean and privacy-first:
    /// crash reporting and app-hang tracking only — no tracing, profiling,
    /// metrics, screenshots, view hierarchy, or PII.
    private static func startSentry(dsn: String, environment: String) {
        SentrySDK.start { options in
            options.dsn = dsn
            options.environment = environment
            // releaseName defaults to "<bundle id>@<version>+<build>".

            // Scope: crashes + app hangs. Watchdog termination is not
            // available on macOS; everything performance-related is off.
            options.enableCrashHandler = true
            options.enableAppHangTracking = true
            // The SDK's 2s default fires on transient, non-fully-blocking
            // stalls — a few dropped frames during heavy SwiftUI updates or
            // model metadata loads — which dominate the issue stream as
            // low-actionability noise (the captured stack is just wherever the
            // main thread was sampled, not a real blocking call). On iOS the
            // SDK can split fully- from non-fully-blocking hangs and drop the
            // latter via `enableReportNonFullyBlockingAppHangs`, but that
            // differentiation does not exist on macOS. Raising the threshold is
            // the macOS-equivalent lever: 3s still catches genuine multi-second
            // freezes while filtering out the brief churn.
            options.appHangTimeoutInterval = 3.0
            options.enableWatchdogTerminationTracking = false
            options.enableAutoPerformanceTracing = false
            options.tracesSampleRate = 0.0

            // Release health: sessions are what turn raw event counts into
            // "N of M users affected" and crash-free rates per release. On by
            // default in the SDK, but pinned explicitly because triage depends
            // on it — 0.22.6 had to be triaged from bare event counts.
            options.enableAutoSessionTracking = true

            // Structured logs (mirrored from `recordBreadcrumb`): gives each
            // release a queryable operation timeline in Sentry → Logs. Same
            // privacy contract as breadcrumbs — identifiers only, no content.
            options.enableLogs = true

            // Don't turn transient network failures into issues, and don't log
            // outgoing request URLs as breadcrumbs — both are on by default,
            // both are out of scope (a failed HTTP response isn't a crash), and
            // the URLs would reveal which endpoints/providers the app talks to.
            options.enableCaptureFailedRequests = false
            options.enableNetworkBreadcrumbs = false

            // Privacy. Never attach identity or the device hostname — consistent
            // with the consent prompt's "nothing is tied to you" promise.
            // (Screenshot / view-hierarchy attachment are iOS/tvOS-only options
            // and don't exist on the macOS SDK, so there's nothing to disable.)
            options.sendDefaultPii = false
            options.beforeSend = { event in
                // Defense-in-depth on top of `sendDefaultPii = false`: strip
                // the device hostname (often "<Name>'s MacBook") and every
                // identifying user field from the event before it leaves the
                // machine. Keep ONLY the SDK's anonymous installation id — a
                // random UUID stored locally, attached by the SDK as `user.id`
                // when no user is set. Blanking the whole user (as 0.22.6 did)
                // made Sentry report "Users Impacted: 0" on every issue, so
                // release triage couldn't tell one broken machine from a fleet.
                let anonymous = User()
                anonymous.userId = event.user?.userId
                event.user = anonymous
                event.serverName = nil
                annotateAppHangEvent(event)
                return event
            }

            #if DEBUG
                options.debug = true
            #endif
        }
    }

    /// Enrich the SDK's own AppHang events with the operation the
    /// `MainThreadOperationLedger` says was in flight when the hang fired.
    ///
    /// Without this, every hang groups purely by sampled stack — and since a
    /// blocked main thread is usually sampled somewhere inside AppKit/SwiftUI
    /// plumbing rather than at the blocking call, unrelated hangs collapsed
    /// into one un-actionable omnibus issue (APPLE-MACOS-5, 13k events). With
    /// an instrumented operation active, the event is re-fingerprinted on
    /// `subsystem.operation`, splitting Keychain stalls from database stalls
    /// from AX stalls into individually-triageable groups. Hangs with no
    /// instrumented operation keep the SDK's default stack grouping (there is
    /// nothing better to group on — and their volume tells us where ledger
    /// coverage is still missing).
    ///
    /// `nonisolated`: `beforeSend` runs on the SDK's ANR-monitor thread while
    /// the main thread is blocked; the ledger is lock-protected and safe.
    private nonisolated static func annotateAppHangEvent(_ event: Event) {
        let isAppHang =
            event.exceptions?.contains { $0.type?.hasPrefix("App Hang") == true } ?? false
        guard isAppHang else { return }

        let operations = MainThreadOperationLedger.shared.snapshot()
        guard let primary = operations.first else {
            event.tags = (event.tags ?? [:]).merging(
                ["stall.subsystem": "uninstrumented"], uniquingKeysWith: { _, new in new }
            )
            return
        }
        event.tags = (event.tags ?? [:]).merging(
            [
                "stall.subsystem": primary.subsystem,
                "stall.operation": primary.operation,
            ],
            uniquingKeysWith: { _, new in new }
        )
        event.fingerprint = ["app-hang", primary.subsystem, primary.operation]
    }
}
