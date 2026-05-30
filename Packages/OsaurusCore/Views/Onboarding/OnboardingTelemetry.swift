//
//  OnboardingTelemetry.swift
//  osaurus
//
//  Maps onboarding funnel moments onto `TelemetryService` events. Kept
//  separate from the generic service so the event names and the step
//  vocabulary live next to the onboarding UI they describe.
//

import Foundation

@MainActor
enum OnboardingTelemetry {
    /// Onboarding began (fired once per run, regardless of entry step).
    static func started() {
        TelemetryService.shared.track("onboarding_started")
    }

    /// A step became visible. The primary funnel signal — counting users per
    /// step yields both reach-per-step and the drop-off point.
    static func stepViewed(_ step: OnboardingStep) {
        TelemetryService.shared.track(
            "onboarding_step_viewed",
            ["step": step.telemetryName, "step_index": step.rawValue]
        )
    }

    /// The user actively skipped a step via its secondary "Skip" control —
    /// distinguishes "skipped" from "completed" for a given step.
    static func stepSkipped(_ step: OnboardingStep) {
        TelemetryService.shared.track(
            "onboarding_step_skipped",
            ["step": step.telemetryName]
        )
    }

    /// Onboarding closed. `via` separates a genuine finish (walkthrough) from
    /// an early close (X button); `lastStep` is the step they were on when
    /// they left — the early-close drop-off point.
    static func completed(lastStep: OnboardingStep, via: Completion) {
        TelemetryService.shared.track(
            "onboarding_completed",
            ["last_step": lastStep.telemetryName, "via": via.rawValue]
        )
    }

    enum Completion: String {
        case walkthroughFinish = "walkthrough_finish"
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
        case .identitySetup: return "identity_setup"
        case .sandboxSetup: return "sandbox_setup"
        case .choosePlugins: return "choose_plugins"
        case .walkthrough: return "walkthrough"
        }
    }
}
