//
//  ThermalStateMonitor.swift
//  osaurus
//
//  Tracks `ProcessInfo.thermalState` so background inference work can shed
//  itself while the chassis is throttled. This matters most on fanless
//  laptops (MacBook Air): once macOS reaches `.serious` it is already
//  down-clocking the GPU, and every discretionary inference we run both
//  slows the user's foreground turn and keeps the enclosure hot longer.
//
//  Scope: this PR wires exactly one consumer (`GenerativeGreetingPool`).
//  Batch sizing and generation policy stay untouched until there is
//  measured evidence they should react to thermals.
//

import Foundation

@MainActor
public final class ThermalStateMonitor: ObservableObject {
    public static let shared = ThermalStateMonitor()

    /// Last observed thermal state. `@Published` so future UI or policy
    /// surfaces can observe transitions the same way they observe
    /// `SystemMonitorService`.
    @Published public private(set) var thermalState: ProcessInfo.ThermalState

    /// True while macOS reports `.serious` or `.critical`.
    public var isThrottled: Bool { Self.isThrottled(thermalState) }

    private var observer: NSObjectProtocol?
    private var transitionSequence: UInt64 = 0

    private init() {
        thermalState = ProcessInfo.processInfo.thermalState
    }

    /// Begin observing thermal-state changes. Idempotent. Called once at
    /// launch (AppDelegate) so throttle transitions are caught even before
    /// any chat window exists.
    public func start() {
        guard observer == nil else { return }
        // A process launched while the machine is already hot never sees a
        // transition, so sync the initial state (and gate the pool) here
        // instead of waiting for the first notification.
        let initial = ProcessInfo.processInfo.thermalState
        if thermalState != initial { thermalState = initial }
        if Self.isThrottled(initial) {
            announceAndPush(throttled: true, state: initial)
        }
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            // System notifications can arrive outside a Swift task context;
            // use a real actor hop instead of assumeIsolated.
            Task { @MainActor in
                ThermalStateMonitor.shared.apply(ProcessInfo.processInfo.thermalState)
            }
        }
    }

    /// Records the new state and, on a throttle-boundary crossing, logs
    /// once and pushes the flag into the greeting pool. Intermediate
    /// nominal↔fair changes are state-only: they carry no policy meaning
    /// yet and logging them would just be noise.
    private func apply(_ newState: ProcessInfo.ThermalState) {
        let wasThrottled = Self.isThrottled(thermalState)
        if thermalState != newState { thermalState = newState }
        let nowThrottled = Self.isThrottled(newState)
        guard nowThrottled != wasThrottled else { return }
        announceAndPush(throttled: nowThrottled, state: newState)
    }

    /// One log line per boundary crossing + the actual consumer fan-out.
    /// Today the only consumer is the greeting pool; when a second one
    /// arrives this becomes the subscription seam.
    private func announceAndPush(throttled: Bool, state: ProcessInfo.ThermalState) {
        if throttled {
            NSLog(
                "[Osaurus] thermal: %@ — shedding background inference work",
                Self.healthLabel(for: state)
            )
        } else {
            NSLog(
                "[Osaurus] thermal: recovered to %@ — resuming background inference work",
                Self.healthLabel(for: state)
            )
        }
        transitionSequence &+= 1
        let sequence = transitionSequence
        Task {
            await GenerativeGreetingPool.shared.setThermallyThrottled(
                throttled, transitionSequence: sequence)
        }
    }

    // MARK: - Pure mappings (unit-tested)

    /// Throttle threshold is `.serious`: that is the level at which macOS
    /// documents that it is reducing performance and asks apps to cut
    /// resource usage. `.fair` only signals elevated temperature — shedding
    /// pre-warm work there would cost cache hits for no measured benefit.
    nonisolated static func isThrottled(_ state: ProcessInfo.ThermalState) -> Bool {
        switch state {
        case .serious, .critical: return true
        case .nominal, .fair: return false
        @unknown default:
            // A future hotter-than-critical level should shed work, not
            // silently run at full tilt.
            return true
        }
    }

    /// Stable string form for the `/health` endpoint. Kept as an explicit
    /// mapping (not `String(describing:)`) so the wire contract can't drift
    /// with an SDK rename.
    nonisolated static func healthLabel(for state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "critical"
        }
    }
}
