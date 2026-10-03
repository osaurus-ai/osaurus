//
//  OnboardingTelemetry.swift
//  osaurus
//
//  Maps onboarding funnel moments onto `TelemetryService` events. Kept
//  separate from the generic service so the event names and the step
//  vocabulary live next to the onboarding UI they describe.
//

import Aptabase
import Foundation

@MainActor
enum OnboardingTelemetry {
    // The `service` parameter defaults to the shared instance for app use;
    // tests inject a recording service to assert the exact event name and
    // properties each funnel moment produces.

    /// Which DMG the user installed from. `full` ships Raptor 0.6 inside the
    /// app (see `BundledModelSeeder`) and skips the Configure AI step, so
    /// every funnel event carries this so the two flows can be compared.
    enum Distribution: String {
        case light
        case full

        /// Resolved from the installed bundle; overridable for tests.
        static var current: Distribution {
            if let override = overrideForTests { return override }
            return BundledModelSeeder.isFullDistribution ? .full : .light
        }

        nonisolated(unsafe) static var overrideForTests: Distribution?
    }

    static let distributionKey = "distribution"

    private static func withDistribution(
        _ props: [String: Value],
        _ distribution: Distribution
    ) -> [String: Value] {
        var props = props
        props[distributionKey] = distribution.rawValue
        return props
    }

    /// Onboarding began (fired once per run, regardless of entry step).
    static func started(
        distribution: Distribution = .current,
        service: TelemetryService = .shared
    ) {
        service.track("onboarding_started", withDistribution([:], distribution))
    }

    /// A step became visible. The primary funnel signal — counting users per
    /// step yields both reach-per-step and the drop-off point.
    static func stepViewed(
        _ step: OnboardingStep,
        distribution: Distribution = .current,
        service: TelemetryService = .shared
    ) {
        service.track(
            "onboarding_step_viewed",
            withDistribution(["step": step.telemetryName, "step_index": step.rawValue], distribution)
        )
    }

    /// The user committed to a brain on the Configure AI step. `source` is the
    /// low-cardinality path (`hosted` | `local` | `provider_key`); the
    /// bring-your-own-key path also carries the closed-enum `provider` type,
    /// and the local path carries `download_started` — whether committing
    /// kicked off a background model download (vs. an already-downloaded
    /// model). No key, model id, or URL is ever attached. Selection is
    /// payment-free — this fires at the proceed moment, not on any checkout.
    static func brainSourceSelected(
        _ source: BrainSource,
        downloadStarted: Bool? = nil,
        distribution: Distribution = .current,
        service: TelemetryService = .shared
    ) {
        var props: [String: Value] = ["source": source.telemetryValue]
        if let provider = source.providerTelemetryValue {
            props["provider"] = provider
        }
        if let downloadStarted {
            props["download_started"] = downloadStarted
        }
        service.track("brain_source_selected", withDistribution(props, distribution))
    }

    /// The user actively skipped a step via its secondary "Skip" control —
    /// distinguishes "skipped" from "completed" for a given step. The full
    /// distribution also reports Configure AI here when the bundled model
    /// let onboarding bypass the step on the user's behalf.
    static func stepSkipped(
        _ step: OnboardingStep,
        distribution: Distribution = .current,
        service: TelemetryService = .shared
    ) {
        service.track(
            "onboarding_step_skipped",
            withDistribution(["step": step.telemetryName], distribution)
        )
    }

    /// Onboarding closed. `via` separates a genuine finish (Configure AI's
    /// download / connect / set-up-later paths) from an early close (X
    /// button); `lastStep` is the step they were on when they left — the
    /// early-close drop-off point.
    ///
    /// Note: usage consent is now decided on the *first* (Welcome) step. If
    /// the user opted in there, this event — including a `closeButton`
    /// drop-off at any later step — is sent live, which is the whole point of
    /// moving the opt-in up front. If they never opted in, consent stays
    /// undecided and the event is buffered, then dropped when
    /// `finishOnboarding` finalizes the decline.
    static func completed(
        lastStep: OnboardingStep,
        via: Completion,
        distribution: Distribution = .current,
        service: TelemetryService = .shared
    ) {
        service.track(
            "onboarding_completed",
            withDistribution(["last_step": lastStep.telemetryName, "via": via.rawValue], distribution)
        )
    }

    enum Completion: String {
        /// Finished the flow through Configure AI (download, provider
        /// connect, or "Set up later").
        case finishButton = "finish_button"
        /// Closed early via the header X button.
        case closeButton = "close_button"
    }
}

extension OnboardingStep {
    /// Stable, human-readable name used in telemetry. Decoupled from
    /// `rawValue` so the funnel survives reordering or removal of steps in the
    /// upcoming onboarding revamp.
    var telemetryName: String {
        switch self {
        case .welcome: return "welcome"
        case .createAgent: return "create_agent"
        case .configureAI: return "configure_ai"
        }
    }
}
