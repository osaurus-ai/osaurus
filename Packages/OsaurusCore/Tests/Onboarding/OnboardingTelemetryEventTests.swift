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

    /// Drops the global `total_memory_gb` bucket AND the per-event
    /// `distribution` dimension (asserted separately below) so the shape
    /// assertions stay focused on each event's own props.
    private func business(_ props: [String: Any]) -> [String: Any] {
        props.filter { $0.key != "total_memory_gb" && $0.key != "build_channel" && $0.key != "distribution" }
    }

    @Test func started_emits_onboarding_started_with_distribution_only() {
        let (service, rec, cleanup) = makeRecordingService()
        defer { cleanup() }

        OnboardingTelemetry.started(distribution: .light, service: service)

        #expect(rec.events.count == 1)
        #expect(rec.events[0].name == "onboarding_started")
        #expect(business(rec.events[0].props).isEmpty)
        #expect(rec.events[0].props["distribution"] as? String == "light")
    }

    /// Every funnel event carries `distribution` (`light` | `full`) so the
    /// model-bundled DMG's shorter flow can be compared against the standard
    /// one. Default resolves from the installed bundle; tests pin it.
    @Test func every_event_carries_distribution() {
        let (service, rec, cleanup) = makeRecordingService()
        defer { cleanup() }

        OnboardingTelemetry.started(distribution: .full, service: service)
        OnboardingTelemetry.stepViewed(.welcome, distribution: .full, service: service)
        OnboardingTelemetry.brainSourceSelected(.local, downloadStarted: false, distribution: .full, service: service)
        OnboardingTelemetry.stepSkipped(.configureAI, distribution: .full, service: service)
        OnboardingTelemetry.completed(lastStep: .welcome, via: .finishButton, distribution: .full, service: service)

        #expect(rec.events.count == 5)
        #expect(rec.events.allSatisfy { $0.props["distribution"] as? String == "full" })
    }

    @Test func distribution_defaults_to_installed_bundle_and_honors_override() {
        let previous = OnboardingTelemetry.Distribution.overrideForTests
        defer { OnboardingTelemetry.Distribution.overrideForTests = previous }

        OnboardingTelemetry.Distribution.overrideForTests = .full
        #expect(OnboardingTelemetry.Distribution.current == .full)
        OnboardingTelemetry.Distribution.overrideForTests = .light
        #expect(OnboardingTelemetry.Distribution.current == .light)

        // The SwiftPM test bundle has no BundledModels manifest: light.
        OnboardingTelemetry.Distribution.overrideForTests = nil
        let previousSeeder = BundledModelSeeder.isFullDistributionOverrideForTests
        defer { BundledModelSeeder.isFullDistributionOverrideForTests = previousSeeder }
        BundledModelSeeder.isFullDistributionOverrideForTests = nil
        #expect(OnboardingTelemetry.Distribution.current == .light)
        BundledModelSeeder.isFullDistributionOverrideForTests = true
        #expect(OnboardingTelemetry.Distribution.current == .full)
    }

    @Test func distribution_raw_values_match_the_documented_contract() {
        #expect(OnboardingTelemetry.Distribution.light.rawValue == "light")
        #expect(OnboardingTelemetry.Distribution.full.rawValue == "full")
        #expect(OnboardingTelemetry.distributionKey == "distribution")
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
        #expect(business(event.props).count == 3)
        #expect(event.props["source"] as? String == "provider_key")
        #expect(event.props["surface"] as? String == "onboarding")
        #expect(event.props["provider"] as? String == ProviderPreset.openai.rawValue)
        #expect(event.props["privacy_tier"] == nil)
    }

    @Test func brainSourceSelected_local_carries_source_only() {
        let (service, rec, cleanup) = makeRecordingService()
        defer { cleanup() }

        OnboardingTelemetry.brainSourceSelected(.local, service: service)

        let event = rec.events[0]
        #expect(event.name == "brain_source_selected")
        #expect(business(event.props).count == 2)
        #expect(event.props["source"] as? String == "local")
    }

    /// The local path distinguishes "kicked off a background download" from
    /// "model was already on disk" via the boolean `download_started` prop.
    @Test func brainSourceSelected_local_carries_download_started_when_provided() {
        let (service, rec, cleanup) = makeRecordingService()
        defer { cleanup() }

        OnboardingTelemetry.brainSourceSelected(.local, downloadStarted: true, service: service)

        let event = rec.events[0]
        #expect(event.name == "brain_source_selected")
        #expect(business(event.props).count == 3)
        #expect(event.props["source"] as? String == "local")
        #expect(event.props["download_started"] as? Bool == true)
    }

    /// The managed Osaurus default reports the documented `hosted` token and,
    /// like local, never a provider property.
    @Test func brainSourceSelected_osaurus_carries_hosted_source_only() {
        let (service, rec, cleanup) = makeRecordingService()
        defer { cleanup() }

        OnboardingTelemetry.brainSourceSelected(.osaurus, service: service)

        let event = rec.events[0]
        #expect(event.name == "brain_source_selected")
        #expect(business(event.props).count == 2)
        #expect(event.props["source"] as? String == "hosted")
        #expect(event.props["provider"] == nil)
    }

    @Test func stepSkipped_emits_step_name_only() {
        let (service, rec, cleanup) = makeRecordingService()
        defer { cleanup() }

        OnboardingTelemetry.stepSkipped(.configureAI, service: service)

        #expect(rec.events.count == 1)
        let event = rec.events[0]
        #expect(event.name == "onboarding_step_skipped")
        #expect(business(event.props).count == 1)
        #expect(event.props["step"] as? String == "configure_ai")
    }

    @Test func completed_emits_last_step_and_via() {
        let (service, rec, cleanup) = makeRecordingService()
        defer { cleanup() }

        OnboardingTelemetry.completed(lastStep: .configureAI, via: .finishButton, service: service)

        #expect(rec.events.count == 1)
        let event = rec.events[0]
        #expect(event.name == "onboarding_completed")
        #expect(business(event.props).count == 2)
        #expect(event.props["last_step"] as? String == "configure_ai")
        #expect(event.props["via"] as? String == "finish_button")
    }

    /// Skip setup carries `skip_button`, distinguishing a drop-off from a
    /// genuine finish on the same `onboarding_completed` event.
    @Test func completed_via_skip_button_is_distinct() {
        let (service, rec, cleanup) = makeRecordingService()
        defer { cleanup() }

        OnboardingTelemetry.completed(lastStep: .welcome, via: .skipButton, service: service)

        let event = rec.events[0]
        #expect(event.props["last_step"] as? String == "welcome")
        #expect(event.props["via"] as? String == "skip_button")
    }

    @Test func brainSourceSelected_from_chat_sheet_carries_its_surface() {
        let (service, rec, cleanup) = makeRecordingService()
        defer { cleanup() }

        OnboardingTelemetry.brainSourceSelected(.claudeCode, surface: "chat_sheet", service: service)

        let event = rec.events[0]
        #expect(event.props["source"] as? String == "claude_code")
        #expect(event.props["surface"] as? String == "chat_sheet")
        #expect(business(event.props).count == 2)
    }

    @Test func keepResolved_maps_each_outcome_to_its_token() {
        let (service, rec, cleanup) = makeRecordingService()
        defer { cleanup() }

        OnboardingTelemetry.keepResolved(offer: "turn_on", outcome: .turnedOn, service: service)
        OnboardingTelemetry.keepResolved(offer: "turn_on", outcome: .declined, service: service)
        OnboardingTelemetry.keepResolved(offer: "turn_on", outcome: .failed("no schedule"), service: service)

        #expect(rec.events.map(\.name) == Array(repeating: "onboarding_keep_resolved", count: 3))
        #expect(rec.events.map { $0.props["outcome"] as? String } == ["taken", "declined", "failed"])
        #expect(rec.events.allSatisfy { $0.props["offer"] as? String == "turn_on" })
        // The failure reason is free text and never leaves the Mac.
        #expect(rec.events.allSatisfy { business($0.props).count == 2 })
        #expect(rec.events.allSatisfy { $0.props["distribution"] != nil })
    }

    @Test func brainChooserOpened_has_no_business_props() {
        let (service, rec, cleanup) = makeRecordingService()
        defer { cleanup() }

        OnboardingTelemetry.brainChooserOpened(service: service)

        #expect(rec.events.map(\.name) == ["onboarding_brain_chooser_opened"])
        #expect(business(rec.events[0].props).isEmpty)
    }
}
