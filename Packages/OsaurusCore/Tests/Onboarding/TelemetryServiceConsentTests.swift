//
//  TelemetryServiceConsentTests.swift
//  osaurusTests
//
//  Covers the consent-gated buffering in `TelemetryService` — the logic
//  that lets the onboarding funnel fire before the consent screen (the
//  last step) yet only send anything if the user grants consent there.
//
//  Each test builds its own `TelemetryService` against an isolated
//  `UserDefaults` suite and a capture sink (the injectable seam on
//  `init`), so nothing touches the real Aptabase SDK, the real key, or
//  `.standard` — and tests stay independent and parallel-safe.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct TelemetryServiceConsentTests {

    /// Collects the names of events the service actually emits.
    private final class Sink {
        var names: [String] = []
    }

    /// Build a fresh service backed by a throwaway defaults suite plus a
    /// capture sink. The returned `cleanup` wipes the suite from disk.
    private func makeService() -> (service: TelemetryService, sink: Sink, cleanup: () -> Void) {
        let suiteName = "telemetry-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let sink = Sink()
        let service = TelemetryService(
            defaults: defaults,
            emit: { name, _ in sink.names.append(name) }
        )
        return (service, sink, { defaults.removePersistentDomain(forName: suiteName) })
    }

    // MARK: - Undecided → buffer → flush on grant

    @Test func undecided_buffers_then_grant_flushes_in_order() {
        let (service, sink, cleanup) = makeService()
        defer { cleanup() }
        service.markStartedForTesting()

        // Fresh install: no decision yet reads as "not enabled".
        #expect(service.isEnabled == false)

        service.track("onboarding_started")
        service.track("onboarding_step_viewed")
        // Held, not sent.
        #expect(sink.names.isEmpty)

        service.setEnabled(true)
        #expect(service.isEnabled == true)
        // Buffered events flush in the order they were recorded.
        #expect(sink.names == ["onboarding_started", "onboarding_step_viewed"])

        // Subsequent events now go out live.
        service.track("onboarding_completed")
        #expect(sink.names == ["onboarding_started", "onboarding_step_viewed", "onboarding_completed"])
    }

    // MARK: - Decline drops the buffer and silences future events

    @Test func decline_drops_buffer_and_is_not_resurrected_by_a_later_grant() {
        let (service, sink, cleanup) = makeService()
        defer { cleanup() }
        service.markStartedForTesting()

        service.track("onboarding_started")  // buffered while undecided
        service.setEnabled(false)  // decline → drop the buffer
        #expect(service.isEnabled == false)
        #expect(sink.names.isEmpty)

        service.track("onboarding_step_viewed")  // dropped outright
        #expect(sink.names.isEmpty)

        // Changing one's mind later must NOT replay events that were
        // already dropped — they're gone.
        service.setEnabled(true)
        #expect(sink.names.isEmpty)

        service.track("onboarding_completed")  // live from here
        #expect(sink.names == ["onboarding_completed"])
    }

    // MARK: - Granted sends immediately

    @Test func granted_sends_immediately_without_buffering() {
        let (service, sink, cleanup) = makeService()
        defer { cleanup() }
        service.markStartedForTesting()
        service.setEnabled(true)

        service.track("app_launched")
        #expect(sink.names == ["app_launched"])
    }

    // MARK: - No key (never started) → total no-op

    @Test func unconfigured_service_never_buffers_or_sends() {
        let (service, sink, cleanup) = makeService()
        defer { cleanup() }
        // Note: no `markStartedForTesting()` — simulates "no key resolved".

        service.track("onboarding_started")  // ignored (not started)
        service.setEnabled(true)  // flush finds nothing buffered
        #expect(sink.names.isEmpty)

        service.track("onboarding_completed")  // still not started → ignored
        #expect(sink.names.isEmpty)
    }

    // MARK: - Existing-user consent prompt gating

    @Test func needsConsentDecision_is_true_only_when_started_and_undecided() {
        let (service, _, cleanup) = makeService()
        defer { cleanup() }

        // No key resolved yet → nothing to consent to, so don't prompt.
        #expect(service.needsConsentDecision == false)

        // Configured but no decision recorded → this is the upgrading user we
        // want to ask exactly once.
        service.markStartedForTesting()
        #expect(service.needsConsentDecision == true)

        // Any decision resolves it — never prompt again.
        service.setEnabled(true)
        #expect(service.needsConsentDecision == false)

        service.setEnabled(false)
        #expect(service.needsConsentDecision == false)
    }

    // MARK: - Buffer is bounded

    @Test func buffer_is_capped_and_keeps_the_earliest_events() {
        let (service, sink, cleanup) = makeService()
        defer { cleanup() }
        service.markStartedForTesting()

        let overflow = TelemetryService.maxPending + 25
        for i in 0 ..< overflow {
            service.track("e\(i)")
        }

        service.setEnabled(true)
        // Capped at maxPending; the earliest events are the ones retained
        // (we append until full, then drop the rest).
        #expect(sink.names.count == TelemetryService.maxPending)
        #expect(sink.names.first == "e0")
        #expect(sink.names.last == "e\(TelemetryService.maxPending - 1)")
    }

    // MARK: - Decision persists across sessions

    @Test func consent_decision_persists_for_a_returning_session() {
        let suiteName = "telemetry-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // First launch: user grants consent (persisted to the store).
        let first = TelemetryService(defaults: defaults, emit: { _, _ in })
        first.setEnabled(true)

        // Next launch: a brand-new service reading the same store should
        // already see "granted", so `app_launched` goes out live with no
        // consent prompt.
        let secondSink = Sink()
        let second = TelemetryService(defaults: defaults, emit: { name, _ in secondSink.names.append(name) })
        #expect(second.isEnabled == true)

        second.markStartedForTesting()
        second.track("app_launched")
        #expect(secondSink.names == ["app_launched"])
    }
}
