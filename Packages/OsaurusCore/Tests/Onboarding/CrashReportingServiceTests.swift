//
//  CrashReportingServiceTests.swift
//  osaurusTests
//
//  Covers the consent + lifecycle gating in `CrashReportingService` — that the
//  Sentry SDK only boots when crash reporting is enabled (opt-out: on unless
//  the user turned it off, independent of analytics) *and* a DSN is configured,
//  that it boots at most once, and that revoking consent tears it down.
//
//  Each test backs the service with an isolated `UserDefaults` suite and
//  injects fakes through `CrashReportingService.init` (DSN resolver, start/
//  close sinks) so nothing touches the real Sentry SDK, the real DSN, `.standard`,
//  or `TelemetryService.shared`.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct CrashReportingServiceTests {

    /// Records what the service asked the SDK to do.
    private final class Recorder {
        var starts: [(dsn: String, environment: String)] = []
        var closes = 0
    }

    /// Build a service backed by a throwaway defaults suite plus injectable DSN
    /// and a recording SDK sink. `consent == nil` leaves the key absent (the
    /// opt-out default — enabled); a non-nil value writes an explicit choice.
    /// The returned `cleanup` wipes the suite from disk.
    private func makeService(
        consent: Bool?,
        dsn: String?
    ) -> (service: CrashReportingService, recorder: Recorder, cleanup: () -> Void) {
        let suiteName = "crash-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        if let consent { defaults.set(consent, forKey: "crashReportingEnabled") }
        let recorder = Recorder()
        let service = CrashReportingService(
            defaults: defaults,
            resolveDSN: { dsn },
            startSDK: { d, env in recorder.starts.append((d, env)) },
            closeSDK: { recorder.closes += 1 }
        )
        return (service, recorder, { defaults.removePersistentDomain(forName: suiteName) })
    }

    // MARK: - Opt-out default

    @Test func is_enabled_by_default_when_undecided() {
        let (service, recorder, cleanup) = makeService(consent: nil, dsn: "https://k@o0.ingest.sentry.io/1")
        defer { cleanup() }
        #expect(service.isEnabled == true)
        service.startIfConsented()
        #expect(service.isStarted == true)
        #expect(recorder.starts.count == 1)
    }

    // MARK: - No-ops

    @Test func does_not_start_when_disabled() {
        let (service, recorder, cleanup) = makeService(consent: false, dsn: "https://k@o0.ingest.sentry.io/1")
        defer { cleanup() }
        service.startIfConsented()
        #expect(recorder.starts.isEmpty)
        #expect(service.isStarted == false)
    }

    @Test func does_not_start_without_a_dsn() {
        let (service, recorder, cleanup) = makeService(consent: true, dsn: nil)
        defer { cleanup() }
        service.startIfConsented()
        #expect(recorder.starts.isEmpty)
        #expect(service.isStarted == false)
    }

    @Test func does_not_start_with_an_empty_dsn() {
        let (service, recorder, cleanup) = makeService(consent: true, dsn: "")
        defer { cleanup() }
        service.startIfConsented()
        #expect(recorder.starts.isEmpty)
        #expect(service.isStarted == false)
    }

    // MARK: - Starts once

    @Test func starts_once_when_enabled_with_a_dsn() {
        let (service, recorder, cleanup) = makeService(consent: true, dsn: "https://k@o0.ingest.sentry.io/1")
        defer { cleanup() }
        service.startIfConsented()
        #expect(service.isStarted == true)
        #expect(recorder.starts.count == 1)
        #expect(recorder.starts.first?.dsn == "https://k@o0.ingest.sentry.io/1")

        // Idempotent — a second call must not re-init the SDK.
        service.startIfConsented()
        #expect(recorder.starts.count == 1)
    }

    // MARK: - Consent changes

    @Test func setEnabled_true_starts_and_false_closes() {
        let (service, recorder, cleanup) = makeService(consent: nil, dsn: "https://k@o0.ingest.sentry.io/1")
        defer { cleanup() }

        service.setEnabled(true)
        #expect(service.isStarted == true)
        #expect(recorder.starts.count == 1)

        service.setEnabled(false)
        #expect(service.isStarted == false)
        #expect(service.isEnabled == false)
        #expect(recorder.closes == 1)
    }

    @Test func setEnabled_false_is_a_noop_when_never_started() {
        let (service, recorder, cleanup) = makeService(consent: nil, dsn: "https://k@o0.ingest.sentry.io/1")
        defer { cleanup() }
        // Never started → nothing to tear down.
        service.setEnabled(false)
        #expect(recorder.closes == 0)
        #expect(service.isStarted == false)
    }

    @Test func can_restart_after_a_revoke() {
        let (service, recorder, cleanup) = makeService(consent: nil, dsn: "https://k@o0.ingest.sentry.io/1")
        defer { cleanup() }

        service.setEnabled(true)
        service.setEnabled(false)
        // Opting back in re-starts the SDK.
        service.setEnabled(true)

        #expect(service.isStarted == true)
        #expect(recorder.starts.count == 2)
        #expect(recorder.closes == 1)
    }
}
