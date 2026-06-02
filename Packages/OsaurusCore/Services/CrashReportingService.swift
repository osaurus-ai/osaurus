//
//  CrashReportingService.swift
//  osaurus
//
//  Crash + app-hang reporting via the Sentry Cocoa SDK. Wraps the SDK so the
//  rest of the app never imports Sentry directly and every lifecycle decision
//  flows through one gate.
//
//  This shares the *single* telemetry opt-in: it only ever starts when the
//  user has granted consent through `TelemetryService` (the onboarding
//  consent step, the existing-user prompt, or Settings → Privacy). There is
//  no separate switch — one decision drives both analytics and crashes.
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

    /// Whether `SentrySDK.start` has been called this process. Guards against
    /// double-starts and lets `applyConsent(false)` know there's something to
    /// tear down.
    private var started = false
    public var isStarted: Bool { started }

    // MARK: - Testing seam

    /// Reads the current consent decision. Production points at the shared
    /// telemetry gate; tests inject a fixed value. `@MainActor` because the
    /// production default reads `TelemetryService.shared` (and the whole
    /// service is main-actor isolated anyway).
    private let isConsented: @MainActor () -> Bool

    /// Resolves the Sentry DSN. Production reads it from the build config /
    /// Info.plist; tests inject a value (or nil to simulate a keyless build).
    private let resolveDSN: @MainActor () -> String?

    /// Boots the SDK with the resolved DSN + environment. Production wires the
    /// real Sentry start; tests inject a capture closure so the consent +
    /// lifecycle behaviour can be verified without the SDK (and without a DSN).
    private let startSDK: @MainActor (_ dsn: String, _ environment: String) -> Void

    /// Tears the SDK down. Production calls `SentrySDK.close()`; tests record it.
    private let closeSDK: @MainActor () -> Void

    /// Default init wires everything to production (consent from
    /// `TelemetryService.shared`, DSN from Info.plist, start/close to the
    /// Sentry SDK); `shared` uses it. The parameters exist purely as a testing
    /// seam — `init` is `internal`, so the app (which links OsaurusCore as a
    /// product) still can't construct its own instance.
    init(
        isConsented: @escaping @MainActor () -> Bool = { TelemetryService.shared.isEnabled },
        resolveDSN: @escaping @MainActor () -> String? = CrashReportingService.resolveDSNFromConfig,
        startSDK: @escaping @MainActor (_ dsn: String, _ environment: String) -> Void =
            CrashReportingService.startSentry,
        closeSDK: @escaping @MainActor () -> Void = { SentrySDK.close() }
    ) {
        self.isConsented = isConsented
        self.resolveDSN = resolveDSN
        self.startSDK = startSDK
        self.closeSDK = closeSDK
    }

    // MARK: - Lifecycle

    /// Start crash reporting iff the user has consented and a DSN is
    /// configured. Call once from `applicationDidFinishLaunching`, as early as
    /// possible so the crash handler is installed before risky startup work.
    ///
    /// Idempotent, and a silent no-op when consent is absent (undecided or
    /// declined) or no DSN is configured — so contributor builds without a DSN,
    /// and users who never opted in, never phone home. The intended tradeoff:
    /// a crash on the very first launch *before* the user opts in is not
    /// captured. Correct for an opt-in product.
    public func startIfConsented() {
        guard !started else { return }
        guard isConsented() else { return }
        guard let dsn = resolveDSN(), !dsn.isEmpty else { return }
        startSDK(dsn, Self.environment)
        started = true
    }

    /// React to a consent change. Granting starts the SDK (so opting in from
    /// onboarding or Settings turns on crash reporting from that point — the
    /// crash handler itself becomes active on the next launch). Revoking closes
    /// the SDK so nothing further is sent. Wired into
    /// `TelemetryService.setEnabled(_:)`, so it tracks the single opt-in.
    public func applyConsent(_ enabled: Bool) {
        if enabled {
            startIfConsented()
        } else {
            guard started else { return }
            closeSDK()
            started = false
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
                            + "(e.g. SLASH = / then https:$(SLASH)$(SLASH)…).", plist)
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
            options.enableWatchdogTerminationTracking = false
            options.enableAutoPerformanceTracing = false
            options.tracesSampleRate = 0.0

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
                // Defense-in-depth on top of `sendDefaultPii = false`: drop the
                // user object and the device hostname (often "<Name>'s MacBook")
                // from every event before it leaves the machine.
                event.user = nil
                event.serverName = nil
                return event
            }

            #if DEBUG
                options.debug = true
            #endif
        }
    }
}
