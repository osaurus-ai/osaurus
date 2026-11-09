import Foundation
import Testing

@testable import OsaurusCore

/// The subclass is a test-only IPC-latency/counting seam. Production continues
/// using an ordinary UserDefaults instance and Foundation's KVO notifications.
private final class ObservedConsentDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private var delayNextRead = false
    private var delayedOnMain: Bool?
    private weak var consentObserver: NSObject?

    override func addObserver(
        _ observer: NSObject,
        forKeyPath keyPath: String,
        options: NSKeyValueObservingOptions = [],
        context: UnsafeMutableRawPointer?
    ) {
        super.addObserver(observer, forKeyPath: keyPath, options: options, context: context)
        if keyPath == "telemetryEnabled" {
            lock.lock()
            consentObserver = observer
            lock.unlock()
        }
    }

    func replayOlderGrantNotification() {
        lock.lock()
        let observer = consentObserver
        lock.unlock()
        observer?.observeValue(
            forKeyPath: "telemetryEnabled",
            of: self,
            change: [.newKey: true],
            context: nil
        )
    }

    func armReadDelay() {
        lock.lock()
        delayNextRead = true
        lock.unlock()
    }

    func disarm() {
        lock.lock()
        delayNextRead = false
        lock.unlock()
    }

    var observation: (reads: Int, delayedOnMain: Bool?) {
        lock.lock()
        defer { lock.unlock() }
        return (reads, delayedOnMain)
    }

    override func object(forKey key: String) -> Any? {
        guard key == "telemetryEnabled" else { return super.object(forKey: key) }
        lock.lock()
        reads += 1
        let shouldDelay = delayNextRead
        if shouldDelay {
            delayNextRead = false
            delayedOnMain = Thread.isMainThread
        }
        lock.unlock()
        if shouldDelay { Thread.sleep(forTimeInterval: 1.25) }
        return super.object(forKey: key)
    }
}

private final class ConsentMainPulse: @unchecked Sendable {
    private let lock = NSLock()
    private let start = DispatchTime.now().uptimeNanoseconds
    private var elapsed: Double?

    func fire() {
        lock.lock()
        elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        lock.unlock()
    }

    var latency: Double? {
        lock.lock()
        defer { lock.unlock() }
        return elapsed
    }
}

@Suite(.serialized)
@MainActor
struct TelemetryConsentPreferenceTests {
    @Test func eventAndConsentQueriesDoNotReadPreferencesAgain() async throws {
        let suite = "TelemetryConsentPreferenceTests.hot-read.\(UUID())"
        let defaults = try #require(ObservedConsentDefaults(suiteName: suite))
        defer {
            defaults.disarm()
            defaults.removePersistentDomain(forName: suite)
        }
        var emitted: [String] = []
        let service = TelemetryService(defaults: defaults, emit: { name, _ in emitted.append(name) })
        service.markStartedForTesting()
        service.setEnabled(true)
        #expect(service.isEnabled)
        let before = defaults.observation.reads
        defaults.armReadDelay()
        let pulse = ConsentMainPulse()
        DispatchQueue.main.async { pulse.fire() }
        let start = DispatchTime.now().uptimeNanoseconds
        service.track("agent_run")
        #expect(service.isEnabled)
        #expect(!service.needsConsentDecision)
        #expect(service.prepareQuitFlush() != nil)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        let deadline = ContinuousClock.now + .seconds(2)
        while pulse.latency == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(emitted == ["agent_run"])
        #expect(defaults.observation.reads == before)
        #expect(defaults.observation.delayedOnMain == nil)
        #expect(elapsed < 0.5)
        #expect((pulse.latency ?? 99) < 0.5)
        if let directory = ProcessInfo.processInfo.environment["OSAURUS_TEST_EVIDENCE_DIR"] {
            let data = try JSONSerialization.data(
                withJSONObject: [
                    "pid": ProcessInfo.processInfo.processIdentifier,
                    "process_environment": Dictionary(
                        uniqueKeysWithValues: [
                            "OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS", "OSAURUS_TEST_ROOT",
                            "OSU_MODELS_DIR", "OSAURUS_IMAGE_MODELS_DIR", "OSAURUS_TEST_EVIDENCE_DIR",
                        ].map { ($0, ProcessInfo.processInfo.environment[$0] ?? "<absent>") }
                    ),
                    "elapsed_seconds": elapsed,
                    "main_pulse_seconds": pulse.latency ?? -1,
                    "consent_reads_before": before,
                    "consent_reads_after": defaults.observation.reads,
                    "delay_reached": defaults.observation.delayedOnMain != nil,
                    "scope": "Controlled isolated store; not original cfprefsd latency",
                ],
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("telemetry-hot-read-\(UUID()).json"),
                options: [.withoutOverwriting]
            )
        }
    }

    @Test func keylessEarlyReturnsDoNotReadPreferences() throws {
        let suite = "TelemetryConsentPreferenceTests.keyless.\(UUID())"
        let defaults = try #require(ObservedConsentDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var emitted: [String] = []
        let service = TelemetryService(defaults: defaults, emit: { name, _ in emitted.append(name) })
        service.track("not_started")
        #expect(!service.needsConsentDecision)
        #expect(service.prepareQuitFlush() == nil)
        #expect(defaults.observation.reads == 0)
        #expect(emitted.isEmpty)
    }

    @Test func olderGrantCallbackCannotReverseAnObservedOptOut() throws {
        let suite = "TelemetryConsentPreferenceTests.stale-grant.\(UUID())"
        let defaults = try #require(ObservedConsentDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var emitted: [String] = []
        let service = TelemetryService(defaults: defaults, emit: { name, _ in emitted.append(name) })
        service.markStartedForTesting()
        service.setEnabled(true)
        defaults.set(false, forKey: "telemetryEnabled")
        #expect(!service.isEnabled)
        // Independently reproduced with two real concurrent Foundation writes:
        // an older grant callback may resume after a later decline completed.
        defaults.replayOlderGrantNotification()
        #expect(!service.isEnabled)
        service.track("must_remain_declined")
        #expect(emitted.isEmpty)
    }

    @Test func directPeerAndRemovalDecisionsKeepExistingEventPolicy() throws {
        let suite = "TelemetryConsentPreferenceTests.peer.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let peer = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var emitted: [String] = []
        let service = TelemetryService(defaults: defaults, emit: { name, _ in emitted.append(name) })
        service.markStartedForTesting()
        service.track("before_decision")
        peer.set(true, forKey: "telemetryEnabled")
        #expect(service.isEnabled)
        service.track("peer_granted")
        #expect(emitted == ["peer_granted"])
        defaults.set(false, forKey: "telemetryEnabled")
        #expect(!service.isEnabled)
        service.track("declined_dropped")
        #expect(emitted == ["peer_granted"])
        peer.removeObject(forKey: "telemetryEnabled")
        #expect(!service.isEnabled)
        #expect(service.needsConsentDecision)
        service.track("undecided_again")
        // External/direct changes affect the gate; only the existing explicit
        // setEnabled action flushes the pre-decision buffer, as before.
        service.setEnabled(true)
        #expect(emitted == ["peer_granted", "before_decision", "undecided_again"])
    }

    @Test func workerOptOutIsEffectiveBeforeTheNextEvent() async throws {
        let suite = "TelemetryConsentPreferenceTests.worker.\(UUID())"
        let defaults = try #require(ObservedConsentDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var emitted: [String] = []
        let service = TelemetryService(defaults: defaults, emit: { name, _ in emitted.append(name) })
        service.markStartedForTesting()
        for _ in 0 ..< 32 {
            service.setEnabled(true)
            await Task.detached { @Sendable [defaults] in
                defaults.set(false, forKey: "telemetryEnabled")
            }.value
            #expect(!service.isEnabled)
            service.track("must_not_send")
        }
        #expect(emitted.isEmpty)
    }

    @Test func outsideProcessOptOutAndRemovalAreObserved() async throws {
        let suite = "TelemetryConsentPreferenceTests.external.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var emitted: [String] = []
        let service = TelemetryService(defaults: defaults, emit: { name, _ in emitted.append(name) })
        service.markStartedForTesting()
        service.setEnabled(true)
        try runDefaults(["write", suite, "telemetryEnabled", "-bool", "false"])
        let declineDeadline = ContinuousClock.now + .seconds(3)
        while service.isEnabled, ContinuousClock.now < declineDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!service.isEnabled)
        #expect(!service.needsConsentDecision)
        service.track("external_decline_dropped")
        #expect(emitted.isEmpty)
        try runDefaults(["delete", suite, "telemetryEnabled"])
        let removalDeadline = ContinuousClock.now + .seconds(3)
        while !service.needsConsentDecision, ContinuousClock.now < removalDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(service.needsConsentDecision)
        service.track("after_removal_buffered")
        service.setEnabled(true)
        #expect(emitted == ["after_removal_buffered"])
    }

    private func runDefaults(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
