//
//  ThermalStateMonitorTests.swift
//  osaurusTests
//
//  Covers the pure thermal mappings (throttle threshold at `.serious`,
//  /health label contract) plus a live smoke test that the monitor's
//  initial state is readable, and the greeting pool's thermal gate
//  (throttled → `warmUp` is a no-op; recovery clears the flag).
//

import Foundation
import Testing

@testable import OsaurusCore

struct ThermalStateMonitorTests {

    // MARK: - Throttle threshold

    @Test func throttleFlipsExactlyAtSerious() {
        // `.serious` is where macOS starts cutting performance and asks
        // apps to shed work; `.fair` must NOT shed or we'd lose greeting
        // cache hits on every warm afternoon.
        #expect(!ThermalStateMonitor.isThrottled(.nominal))
        #expect(!ThermalStateMonitor.isThrottled(.fair))
        #expect(ThermalStateMonitor.isThrottled(.serious))
        #expect(ThermalStateMonitor.isThrottled(.critical))
    }

    // MARK: - /health label contract

    @Test func healthLabelsMatchWireContract() {
        #expect(ThermalStateMonitor.healthLabel(for: .nominal) == "nominal")
        #expect(ThermalStateMonitor.healthLabel(for: .fair) == "fair")
        #expect(ThermalStateMonitor.healthLabel(for: .serious) == "serious")
        #expect(ThermalStateMonitor.healthLabel(for: .critical) == "critical")
    }

    @Test func everyLabelIsThrottleConsistent() {
        // The /health string and the shedding decision must never disagree
        // about the same state.
        let states: [ProcessInfo.ThermalState] = [.nominal, .fair, .serious, .critical]
        for state in states {
            let throttledLabel = ["serious", "critical"]
                .contains(ThermalStateMonitor.healthLabel(for: state))
            #expect(ThermalStateMonitor.isThrottled(state) == throttledLabel)
        }
    }

    // MARK: - Live smoke test (notification plumbing)

    @Test @MainActor func initialStateIsReadableAndConsistent() {
        let monitor = ThermalStateMonitor.shared
        monitor.start()
        // Whatever hardware runs this, the published state must be one of
        // the four documented levels and agree with `isThrottled`.
        let states: [ProcessInfo.ThermalState] = [.nominal, .fair, .serious, .critical]
        #expect(states.contains(monitor.thermalState))
        #expect(monitor.isThrottled == ThermalStateMonitor.isThrottled(monitor.thermalState))
    }

    // MARK: - Greeting pool gate

    @Test func throttledPoolIgnoresWarmUpAndRecovers() async {
        let pool = GenerativeGreetingPool.shared
        // Synthetic agent: the gate rejects before any lookup, so only the
        // id matters (same rationale as the pool persistence tests).
        let agent = Agent(
            id: UUID(),
            name: "Thermal Probe",
            description: "Synthetic agent for thermal-gate tests.",
            systemPrompt: "Test prompt.",
            isBuiltIn: false
        )

        await pool.setThermallyThrottled(true)
        #expect(await pool._testingIsThermallyThrottled())

        // Gated before any refill task is registered, so this is
        // deterministic — no race against a refill completing.
        await pool.warmUp(for: agent, model: "test-model")
        #expect(await !pool._testingHasRefillTask(for: agent.id))

        // Always clear the shared singleton's flag so other suites see
        // the default state.
        await pool.setThermallyThrottled(false)
        #expect(await !pool._testingIsThermallyThrottled())
    }

    @Test func staleThermalTransitionsCannotOverwriteNewerState() async {
        let pool = GenerativeGreetingPool.shared
        await pool.setThermallyThrottled(true, transitionSequence: 10_002)
        await pool.setThermallyThrottled(false, transitionSequence: 10_001)
        #expect(await pool._testingIsThermallyThrottled())
        await pool.setThermallyThrottled(false, transitionSequence: 10_003)
        #expect(await !pool._testingIsThermallyThrottled())
    }
}
