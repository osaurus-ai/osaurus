//
//  TelemetryService.swift
//  osaurus
//
//  Central analytics entry point. Wraps the Aptabase SDK so the rest of the
//  app never imports Aptabase directly and every event flows through a single
//  gate
//

import Aptabase
import Foundation

@MainActor
public final class TelemetryService {
    public static let shared = TelemetryService()

    /// Tracking mode handed to the Aptabase SDK, decided at compile time.
    ///
    /// DEBUG builds route every event into Aptabase's **Debug** bucket (which
    /// the production dashboard filters out), so local wiring and testing
    /// never pollute real metrics. Release builds report as production
    /// automatically so no manual switch before shipping.
    #if DEBUG
        private static let trackingMode: TrackingMode = .asDebug
    #else
        private static let trackingMode: TrackingMode = .asRelease
    #endif

    /// `UserDefaults` flag the future onboarding consent screen will toggle.
    /// Absent (first run) defaults to enabled; the consent UI flips it and
    /// every `track()` call respects it with no other code changes.
    private static let consentKey = "telemetryEnabled"

    /// Whether `configure()` successfully initialized the SDK with a key.
    private var started = false

    private init() {}

    // MARK: - Lifecycle

    /// Resolve the app key and initialize Aptabase. Call once from
    /// `applicationDidFinishLaunching`. No-ops (tracking stays disabled) when
    /// no key is configured, so dev builds without a key are silent.
    public func configure() {
        guard !started else { return }
        guard let appKey = Self.resolveAppKey() else { return }

        Aptabase.shared.initialize(
            appKey: appKey,
            with: InitOptions(trackingMode: Self.trackingMode)
        )
        started = true

        // Baseline launch signal
        track("app_launched")
    }

    // MARK: - Consent

    public var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.consentKey) as? Bool ?? true
    }

    public func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.consentKey)
    }

    // MARK: - Tracking

    /// Track an event with optional properties. No-ops when telemetry is
    /// unconfigured (no key) or disabled via consent.
    public func track(_ event: String, _ props: [String: Value] = [:]) {
        guard started, isEnabled else { return }
        Aptabase.shared.trackEvent(event, with: props)
    }

    // MARK: - Key resolution

    /// Key precedence:
    ///   1. (DEBUG only) `APTABASE_APP_KEY` environment variable — optional
    ///      override for one-off local runs; never committed.
    ///   2. `AptabaseAppKey` in Info.plist, populated by the `$(APTABASE_APP_KEY)`
    ///      build setting. In DEBUG that comes from the gitignored
    ///      `App/osaurus/Secrets.xcconfig` (the project's Debug base config. see
    ///      `Secrets.example.xcconfig`). in Release it's injected by CI
    ///      (`build_arm64.sh` ← the `APTABASE_APP_KEY` GitHub secret).
    /// The env-var path is compiled out of Release builds so a stray
    /// environment value can never override the shipped key. Returns nil when
    /// no key is found so tracking stays disabled.
    private static func resolveAppKey() -> String? {
        #if DEBUG
            if let env = ProcessInfo.processInfo.environment["APTABASE_APP_KEY"],
                !env.isEmpty
            {
                return env
            }
        #endif
        if let plist = Bundle.main.object(forInfoDictionaryKey: "AptabaseAppKey") as? String,
            !plist.isEmpty
        {
            return plist
        }
        return nil
    }
}
