//
//  OnboardingTelemetryEventTests.swift
//  osaurusTests
//
//  Verifies that each `OnboardingTelemetry` funnel moment emits the exact
//  event name AND properties the analytics dashboards expect. The naming
//  tests lock the value strings in isolation; these tests lock how those
//  strings are wired into a `track` call (event name + the props dict and
//  its keys) — the part the dashboards actually query.
//
//  Each test injects a recording `TelemetryService` (granted + started) so
//  events emit synchronously into a capture buffer, with no SDK, real key,
//  or `.standard` involvement.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct OnboardingTelemetryEventTests {

    /// One emitted event, with props boxed to `Any` so assertions can cast
    /// to concrete types (`as? String` / `as? Int`) without naming the
    /// Aptabase `Value` protocol or importing the SDK.
    private struct Event {
        let name: String
        let props: [String: Any]
    }

    private final class Recorder {
        var events: [Event] = []
    }

    /// Drops the global `total_memory_gb` bucket (attached to every event by
    /// `TelemetryService.track`) so per-event shape assertions stay focused on
    /// the event-specific props.
    private func business(_ props: [String: Any]) -> [String: Any] {
        props.filter { $0.key != "total_memory_gb" }
    }

    /// A granted + started service whose sends are captured. Returns the
    /// service, the recorder, and a cleanup that wipes the defaults suite.
    private func makeRecordingService() -> (TelemetryService, Recorder, () -> Void) {
        let suiteName = "telemetry-evt-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let recorder = Recorder()
        let service = TelemetryService(
            defaults: defaults,
            emit: { name, props in
                recorder.events.append(Event(name: name, props: props.mapValues { $0 as Any }))
            }
        )
        service.markStartedForTesting()
        service.setEnabled(true)  // granted → emit immediately, no buffering
        return (service, recorder, { defaults.removePersistentDomain(forName: suiteName) })
    }

    @Test func started_emits_onboarding_started_with_no_props() {
        let (service, rec, cleanup) = makeRecordingService()
        defer { cleanup() }

        OnboardingTelemetry.started(service: service)

        #expect(rec.events.count == 1)
        #expect(rec.events[0].name == "onboarding_started")
        #expect(business(rec.events[0].props).isEmpty)
    }

    @Test func stepViewed_emits_step_name_and_index() {
        let (service, rec, cleanup) = makeRecordingService()
        defer { cleanup() }

        OnboardingTelemetry.stepViewed(.configureAI, service: service)

        #expect(rec.events.count == 1)
        let event = rec.events[0]
        #expect(event.name == "onboarding_step_viewed")
        #expect(business(event.props).count == 2)
        #expect(event.props["step"] as? String == "configure_ai")
        #expect(event.props["step_index"] as? Int == OnboardingStep.configureAI.rawValue)
    }

    @Test func brainSourceSelected_providerKey_carries_provider_type() {
        let (service, rec, cleanup) = makeRecordingService()
        defer { cleanup() }

        OnboardingTelemetry.brainSourceSelected(.providerKey(.openai), service: service)

        let event = rec.events[0]
        #expect(event.name == "brain_source_selected")
        #expect(business(event.props).count == 2)
        #expect(event.props["source"] as? String == "provider_key")
        #expect(event.props["provider"] as? String == ProviderPreset.openai.rawValue)
        #expect(event.props["privacy_tier"] == nil)
    }

    @Test func brainSourceSelected_local_carries_source_only() {
        let (service, rec, cleanup) = makeRecordingService()
        defer { cleanup() }

        OnboardingTelemetry.brainSourceSelected(.local, service: service)

        let event = rec.events[0]
        #expect(event.name == "brain_source_selected")
        #expect(business(event.props).count == 1)
        #expect(event.props["source"] as? String == "local")
    }

    @Test func stepSkipped_emits_step_name_only() {
        let (service, rec, cleanup) = makeRecordingService()
        defer { cleanup() }

        OnboardingTelemetry.stepSkipped(.choosePlugins, service: service)

        #expect(rec.events.count == 1)
        let event = rec.events[0]
        #expect(event.name == "onboarding_step_skipped")
        #expect(business(event.props).count == 1)
        #expect(event.props["step"] as? String == "choose_plugins")
    }

    @Test func completed_emits_last_step_and_via() {
        let (service, rec, cleanup) = makeRecordingService()
        defer { cleanup() }

        OnboardingTelemetry.completed(lastStep: .walkthrough, via: .finishButton, service: service)

        #expect(rec.events.count == 1)
        let event = rec.events[0]
        #expect(event.name == "onboarding_completed")
        #expect(business(event.props).count == 2)
        #expect(event.props["last_step"] as? String == "walkthrough")
        #expect(event.props["via"] as? String == "finish_button")
    }

    /// The early-close path carries `close_button`, distinguishing a
    /// drop-off from a genuine finish on the same `onboarding_completed`
    /// event.
    @Test func completed_via_close_button_is_distinct() {
        let (service, rec, cleanup) = makeRecordingService()
        defer { cleanup() }

        OnboardingTelemetry.completed(lastStep: .createAgent, via: .closeButton, service: service)

        let event = rec.events[0]
        #expect(event.props["last_step"] as? String == "create_agent")
        #expect(event.props["via"] as? String == "close_button")
    }
}
