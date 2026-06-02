//
//  CrashReportingServiceTests.swift
//  osaurusTests
//
//  Covers the consent + lifecycle gating in `CrashReportingService` — that the
//  Sentry SDK only ever boots when the user has opted in (the single telemetry
//  consent) *and* a DSN is configured, that it boots at most once, and that
//  revoking consent tears it down.
//
//  Each test injects fakes through `CrashReportingService.init` (consent flag,
//  DSN resolver, start/close sinks) so nothing touches the real Sentry SDK,
//  the real DSN, or `TelemetryService.shared`.
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

    /// Build a service with injectable consent + DSN and a recording SDK sink.
    private func makeService(
        consented: Bool,
        dsn: String?
    ) -> (service: CrashReportingService, recorder: Recorder) {
        let recorder = Recorder()
        let service = CrashReportingService(
            isConsented: { consented },
            resolveDSN: { dsn },
            startSDK: { d, env in recorder.starts.append((d, env)) },
            closeSDK: { recorder.closes += 1 }
        )
        return (service, recorder)
    }

    // MARK: - No-ops

    @Test func does_not_start_without_consent() {
        let (service, recorder) = makeService(consented: false, dsn: "https://k@o0.ingest.sentry.io/1")
        service.startIfConsented()
        #expect(recorder.starts.isEmpty)
        #expect(service.isStarted == false)
    }

    @Test func does_not_start_without_a_dsn() {
        let (service, recorder) = makeService(consented: true, dsn: nil)
        service.startIfConsented()
        #expect(recorder.starts.isEmpty)
        #expect(service.isStarted == false)
    }

    @Test func does_not_start_with_an_empty_dsn() {
        let (service, recorder) = makeService(consented: true, dsn: "")
        service.startIfConsented()
        #expect(recorder.starts.isEmpty)
        #expect(service.isStarted == false)
    }

    // MARK: - Starts once

    @Test func starts_once_when_consented_with_a_dsn() {
        let (service, recorder) = makeService(consented: true, dsn: "https://k@o0.ingest.sentry.io/1")
        service.startIfConsented()
        #expect(service.isStarted == true)
        #expect(recorder.starts.count == 1)
        #expect(recorder.starts.first?.dsn == "https://k@o0.ingest.sentry.io/1")

        // Idempotent — a second call must not re-init the SDK.
        service.startIfConsented()
        #expect(recorder.starts.count == 1)
    }

    // MARK: - Consent changes

    @Test func applyConsent_true_starts_and_false_closes() {
        let (service, recorder) = makeService(consented: true, dsn: "https://k@o0.ingest.sentry.io/1")

        service.applyConsent(true)
        #expect(service.isStarted == true)
        #expect(recorder.starts.count == 1)

        service.applyConsent(false)
        #expect(service.isStarted == false)
        #expect(recorder.closes == 1)
    }

    @Test func applyConsent_false_is_a_noop_when_never_started() {
        let (service, recorder) = makeService(consented: true, dsn: "https://k@o0.ingest.sentry.io/1")
        // Never started → nothing to tear down.
        service.applyConsent(false)
        #expect(recorder.closes == 0)
        #expect(service.isStarted == false)
    }

    @Test func can_restart_after_a_revoke() {
        let (service, recorder) = makeService(consented: true, dsn: "https://k@o0.ingest.sentry.io/1")

        service.applyConsent(true)
        service.applyConsent(false)
        // Opting back in re-starts the SDK.
        service.applyConsent(true)

        #expect(service.isStarted == true)
        #expect(recorder.starts.count == 2)
        #expect(recorder.closes == 1)
    }
}
