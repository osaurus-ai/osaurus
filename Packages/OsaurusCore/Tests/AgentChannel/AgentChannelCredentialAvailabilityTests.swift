//
//  AgentChannelCredentialAvailabilityTests.swift
//  osaurus
//
//  Regression coverage for the non-blocking credential-availability
//  snapshot (Sentry APPLE-MACOS-1B5): main-thread reads must never run the
//  live Keychain/filesystem probe, and mutations must refresh the cache.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct AgentChannelCredentialAvailabilityTests {

    private final class ProbeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        private var _value = true
        private var _probedOnMainThread = false

        var count: Int { lock.withLock { _count } }
        var probedOnMainThread: Bool { lock.withLock { _probedOnMainThread } }

        func set(value: Bool) {
            lock.withLock { _value = value }
        }

        func probe() -> Bool {
            lock.withLock {
                _count += 1
                if Thread.isMainThread { _probedOnMainThread = true }
                return _value
            }
        }
    }

    @Test
    func mainThreadReadNeverProbesSynchronously() async throws {
        let recorder = ProbeRecorder()
        let cache = AgentChannelCredentialAvailability(probe: { _ in recorder.probe() })

        // Unseeded main-thread read: pessimistic false, no synchronous probe.
        let first = await MainActor.run { cache.hasCredential(.slack) }
        #expect(first == false)
        #expect(recorder.probedOnMainThread == false)

        // The scheduled background refresh eventually lands the real value.
        var seeded = false
        for _ in 0..<200 {
            if await MainActor.run(body: { cache.hasCredential(.slack) }) {
                seeded = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(seeded, "background refresh should publish the probed value")
        #expect(recorder.probedOnMainThread == false)
    }

    @Test
    func offMainUnseededReadProbesSynchronouslyForCorrectness() async {
        let recorder = ProbeRecorder()
        recorder.set(value: true)
        let cache = AgentChannelCredentialAvailability(probe: { _ in recorder.probe() })

        // Publish-authorization callers off the main thread need a correct
        // answer immediately, even before the launch seed lands.
        let value = await Task.detached { cache.hasCredential(.discord) }.value
        #expect(value == true)
        #expect(recorder.count == 1)
    }

    @Test
    func invalidateRefreshesAfterMutation() async throws {
        let recorder = ProbeRecorder()
        recorder.set(value: false)
        let cache = AgentChannelCredentialAvailability(probe: { _ in recorder.probe() })

        // Seed with "no credential".
        cache.refreshNow(.telegram)
        #expect(await MainActor.run(body: { cache.hasCredential(.telegram) }) == false)

        // Token saved: probe now reports true; invalidate must re-probe.
        recorder.set(value: true)
        cache.invalidate(.telegram)
        var updated = false
        for _ in 0..<200 {
            if await MainActor.run(body: { cache.hasCredential(.telegram) }) {
                updated = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(updated, "invalidate should re-probe and publish the new value")
    }

    @Test
    func freshCachedValueDoesNotReprobe() async {
        let recorder = ProbeRecorder()
        recorder.set(value: true)
        let cache = AgentChannelCredentialAvailability(probe: { _ in recorder.probe() })

        cache.refreshNow(.imessage)
        let baseline = recorder.count
        for _ in 0..<10 {
            _ = await MainActor.run { cache.hasCredential(.imessage) }
        }
        // Give any (incorrectly) scheduled refresh a chance to run.
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(recorder.count == baseline, "fresh cached reads must not re-probe")
    }
}
