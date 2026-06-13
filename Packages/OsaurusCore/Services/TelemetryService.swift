//
//  TelemetryService.swift
//  osaurus
//
//  Central analytics entry point. Wraps the Aptabase SDK so the rest of the
//  app never imports Aptabase directly and every event flows through a single
//  gate
//

import Aptabase
import CryptoKit
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

    /// `UserDefaults` flag the onboarding consent screen toggles. Three
    /// states, keyed off presence/value (see `consent`): absent = the user
    /// hasn't decided yet, `true` = granted, `false` = declined.
    private static let consentKey = "telemetryEnabled"

    /// Whether `configure()` successfully initialized the SDK with a key.
    private var started = false

    /// Events recorded before the user makes a consent decision are held
    /// here and only sent if they later grant consent (the consent screen is
    /// the last onboarding step, so the whole funnel happens pre-decision).
    /// In-memory only — a session that quits without consent simply drops
    /// them, which is the intended "no consent, no data" behaviour. Bounded
    /// so a user who never reaches the consent screen can't grow it without
    /// limit across repeated re-tracking.
    private var pending: [PendingEvent] = []
    static let maxPending = 64

    private struct PendingEvent {
        let name: String
        let props: [String: Value]
    }

    /// Where the consent decision is persisted. Injectable so unit tests
    /// can use an isolated suite instead of polluting `.standard`.
    private let defaults: UserDefaults

    /// Performs the actual event send. Production points at the Aptabase
    /// SDK; tests inject a capture closure so the consent + buffering
    /// behaviour can be verified without the SDK (and without a real key).
    private let emit: (String, [String: Value]) -> Void

    /// Default init wires `emit` to the Aptabase SDK and consent to
    /// `.standard`; `shared` uses it. The parameters exist purely as a
    /// testing seam — `init` is `internal`, so the app (which links
    /// OsaurusCore as a product) still can't construct its own instance.
    init(
        defaults: UserDefaults = .standard,
        emit: @escaping (String, [String: Value]) -> Void = { Aptabase.shared.trackEvent($0, with: $1) }
    ) {
        self.defaults = defaults
        self.emit = emit
    }

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

    /// Marks the service as configured without initializing the Aptabase
    /// SDK, so unit tests can exercise the consent + buffering logic
    /// (`track` early-returns until `started`). `internal`, so it's
    /// invisible to the app and reachable only from `@testable` tests.
    func markStartedForTesting() {
        started = true
    }

    /// Best-effort synchronous flush for the quit path. Aptabase's send queue
    /// is in-memory only (no disk persistence), and the app now hard-exits with
    /// `_exit(0)`, which skips the SDK's own `willTerminate` flush. Kick a final
    /// send and hold the main thread a bounded window so the in-flight URLSession
    /// request — which runs off-main — has a chance to leave before the process
    /// dies. This stays best-effort: the SDK's public `flush()` is fire-and-forget
    /// with no completion handle, so we can't confirm delivery, only give it room.
    /// No-ops (and costs nothing on quit) unless telemetry actually started and
    /// the user granted consent, so keyless/disabled/undecided builds never block.
    public func flushForQuit(timeout: TimeInterval = 0.6) {
        guard started, isEnabled else { return }
        Aptabase.shared.flush()
        Thread.sleep(forTimeInterval: timeout)
    }

    // MARK: - Consent

    /// The user's consent decision, derived from `consentKey`.
    private enum Consent {
        /// No choice made yet — events are buffered until one is.
        case undecided
        case granted
        case declined
    }

    private var consent: Consent {
        guard let decided = defaults.object(forKey: Self.consentKey) as? Bool else {
            return .undecided
        }
        return decided ? .granted : .declined
    }

    /// Whether the user has granted consent. `false` while undecided so
    /// callers can't read this as "tracking is live" before a choice.
    public var isEnabled: Bool {
        if case .granted = consent { return true }
        return false
    }

    /// True when telemetry is live (a key resolved at launch) *and* the user
    /// has never made a consent decision. The onboarding consent step covers
    /// new users; this lets the app prompt users who upgraded from a build
    /// without that step exactly once, so we never start sending without an
    /// explicit choice. False on keyless builds (nothing to consent to) and
    /// the moment any decision — grant or decline — is recorded.
    public var needsConsentDecision: Bool {
        guard started else { return false }
        if case .undecided = consent { return true }
        return false
    }

    /// Record the consent decision. Called by the onboarding consent screen.
    /// Granting flushes everything buffered during onboarding; declining
    /// drops it. Both paths make all future `track()` calls send or no-op
    /// with no other code changes.
    public func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.consentKey)
        if enabled {
            flushPending()
        } else {
            pending.removeAll()
        }
    }

    private func flushPending() {
        guard started else {
            // No SDK (no key) — nothing can be sent; discard so we don't
            // hold a stale buffer.
            pending.removeAll()
            return
        }
        for event in pending {
            emit(event.name, event.props)
        }
        pending.removeAll()
    }

    // MARK: - Tracking

    /// Track an event with optional properties. No-ops when telemetry is
    /// unconfigured (no key). Before the user decides on consent the event is
    /// buffered and only sent if they later grant it; once granted events go
    /// out immediately; once declined they're dropped.
    public func track(_ event: String, _ props: [String: Value] = [:]) {
        guard started else { return }

        // Attach a coarse hardware-RAM bucket to every event so funnel /
        // bounce metrics can be segmented by machine class (e.g. the 26B-A4B
        // MoE that bounced 36% on lower-RAM Macs) without shipping an exact,
        // potentially-identifying memory size. Never overwrites a value a
        // caller set explicitly.
        var enriched = props
        if enriched["total_memory_gb"] == nil {
            enriched["total_memory_gb"] = Self.totalMemoryBucketLabel
        }

        switch consent {
        case .granted:
            emit(event, enriched)
        case .undecided:
            guard pending.count < Self.maxPending else { return }
            pending.append(PendingEvent(name: event, props: enriched))
        case .declined:
            break
        }
    }

    /// Coarse physical-RAM bucket label (whole GB) attached to every event.
    /// Computed once — installed memory doesn't change within a process.
    /// Sourced from `ProcessInfo.physicalMemory` (always populated,
    /// synchronous) rather than the sampled `SystemMonitorService`, and
    /// snapped to a small set of Apple Silicon tiers so it stays
    /// non-identifying. `"128+"` caps the high end.
    nonisolated static let totalMemoryBucketLabel: String = {
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
        let tiers: [Int] = [8, 16, 18, 24, 32, 36, 48, 64, 96, 128]
        // Physical RAM reads slightly under the nominal spec on some Macs, so
        // snap up to the nearest tier with a small tolerance.
        if let tier = tiers.first(where: { gb <= Double($0) + 0.5 }) {
            return String(tier)
        }
        return "128+"
    }()

    // MARK: - Anonymization

    /// Fixed app constant mixed into remote-identifier hashes. It is the
    /// same for every install (NOT a per-device random) on purpose: that's
    /// what lets two users who both configured "my-proxy/gpt-4o" produce the
    /// same hash, so the dashboard can count distinct custom models without
    /// ever receiving the raw string.
    ///
    /// IMPORTANT privacy caveat (documented in `docs/TELEMETRY.md`): a shared
    /// salt plus a low-entropy input is not cryptographically irreversible —
    /// someone holding this salt could brute-force a guessed string back to
    /// its hash. That's an accepted trade-off precisely because we (a) only
    /// hash user-typed *remote* ids, never built-in catalog ids, and (b)
    /// treat `provider_type` (a closed enum) as the primary remote dimension;
    /// `model_hash` is only a secondary distinct-count signal. The 12-char
    /// truncation further limits what leaves the device.
    nonisolated private static let remoteIdSalt = "osaurus.telemetry.remote-id.v1"

    /// Number of leading hex characters kept from the digest. 12 hex = 48
    /// bits, ample to keep distinct custom models distinct in aggregate while
    /// shipping far less than the full digest.
    nonisolated private static let remoteIdHashLength = 12

    /// Salted, truncated SHA-256 of a user-typed remote identifier (a remote
    /// model id like `"my-proxy/gpt-4o"`). Used so distinct custom models can
    /// be counted in aggregate without the raw, potentially identifying
    /// string ever leaving the device. Never call this on built-in catalog
    /// ids — those are safe to send verbatim. See the salt note above for the
    /// reversibility caveat.
    nonisolated public static func anonymizedRemoteId(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data("\(remoteIdSalt):\(trimmed)".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(remoteIdHashLength))
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
