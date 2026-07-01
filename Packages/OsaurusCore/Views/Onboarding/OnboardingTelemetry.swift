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

    /// Onboarding began (fired once per run, regardless of entry step).
    static func started(service: TelemetryService = .shared) {
        service.track("onboarding_started")
    }

    /// A step became visible. The primary funnel signal — counting users per
    /// step yields both reach-per-step and the drop-off point.
    static func stepViewed(_ step: OnboardingStep, service: TelemetryService = .shared) {
        service.track(
            "onboarding_step_viewed",
            ["step": step.telemetryName, "step_index": step.rawValue]
        )
    }

    /// The user committed to a brain on the Configure AI step. `source` is the
    /// low-cardinality path (`local` | `provider_key`); the bring-your-own-key
    /// path also carries the closed-enum `provider` type. No key, model id, or
    /// URL is ever attached. Selection is payment-free — this fires at the
    /// proceed moment, not on any checkout.
    static func brainSourceSelected(
        _ source: BrainSource,
        service: TelemetryService = .shared
    ) {
        var props: [String: Value] = ["source": source.telemetryValue]
        if let provider = source.providerTelemetryValue {
            props["provider"] = provider
        }
        service.track("brain_source_selected", props)
    }

    /// The user actively skipped a step via its secondary "Skip" control —
    /// distinguishes "skipped" from "completed" for a given step.
    static func stepSkipped(_ step: OnboardingStep, service: TelemetryService = .shared) {
        service.track(
            "onboarding_step_skipped",
            ["step": step.telemetryName]
        )
    }

    /// Onboarding closed. `via` separates a genuine finish (the consent
    /// step's CTA) from an early close (X button); `lastStep` is the step
    /// they were on when they left — the early-close drop-off point.
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
        service: TelemetryService = .shared
    ) {
        service.track(
            "onboarding_completed",
            ["last_step": lastStep.telemetryName, "via": via.rawValue]
        )
    }

    enum Completion: String {
        /// Reached the consent step and tapped its final CTA.
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
        case .choosePlugins: return "choose_plugins"
        case .walkthrough: return "walkthrough"
        case .consent: return "consent"
        }
    }
}
