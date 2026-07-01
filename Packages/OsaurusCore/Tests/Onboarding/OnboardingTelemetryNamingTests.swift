//
//  OnboardingTelemetryNamingTests.swift
//  osaurusTests
//
//  Locks the onboarding telemetry "contract" — the stable string names
//  for each funnel step and each completion path. These strings are the
//  dimension values the analytics dashboards group by, so an accidental
//  rename (or a reordered/removed step) would silently split or break the
//  funnel without any compile error. These tests fail loudly instead.
//

import Testing

@testable import OsaurusCore

@MainActor
struct OnboardingTelemetryNamingTests {

    @Test func step_names_match_the_documented_contract() {
        #expect(OnboardingStep.welcome.telemetryName == "welcome")
        #expect(OnboardingStep.createAgent.telemetryName == "create_agent")
        #expect(OnboardingStep.configureAI.telemetryName == "configure_ai")
        #expect(OnboardingStep.choosePlugins.telemetryName == "choose_plugins")
        #expect(OnboardingStep.walkthrough.telemetryName == "walkthrough")
        #expect(OnboardingStep.consent.telemetryName == "consent")
    }

    /// `telemetryName` is intentionally decoupled from `rawValue` so the
    /// funnel survives reordering. Guard that every case still maps to a
    /// distinct, non-empty name — a duplicate would merge two steps in the
    /// dashboard, an empty one would drop a step.
    @Test func every_step_has_a_unique_non_empty_name() {
        let names = OnboardingStep.allCases.map(\.telemetryName)
        #expect(names.allSatisfy { !$0.isEmpty })
        #expect(Set(names).count == OnboardingStep.allCases.count)
    }

    @Test func completion_raw_values_match_the_documented_contract() {
        #expect(OnboardingTelemetry.Completion.finishButton.rawValue == "finish_button")
        #expect(OnboardingTelemetry.Completion.closeButton.rawValue == "close_button")
    }
}
