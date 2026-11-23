import Foundation
import Network

/// Pauses background backfill of older history on expensive (cellular, personal hotspot) or
/// constrained (Low Data Mode) networks, in Low Power Mode, and while the device is hot (thermal
/// state serious or critical), and resumes it otherwise. Hot or in Low Power Mode, it also paces a
/// catch-up (`setGentleSync`). Live sync and on-demand history fetches are unaffected.
public final class BackfillPolicyMonitor: @unchecked Sendable {
    public struct Conditions: Equatable, Sendable {
        public var expensive: Bool
        public var constrained: Bool
        public var lowPower: Bool
        /// Thermal state serious or critical: catching up on old history can wait for it to cool.
        public var hot: Bool

        public init(expensive: Bool, constrained: Bool, lowPower: Bool, hot: Bool = false) {
            self.expensive = expensive
            self.constrained = constrained
            self.lowPower = lowPower
            self.hot = hot
        }

        public var policy: BackfillPolicy {
            expensive || constrained || lowPower || hot ? .paused : .run
        }

        /// Hot or saving power: catching up runs fewer reconciliations at once (`setGentleSync`), so
        /// the same work is spread out rather than holding the CPU.
        public var gentle: Bool { hot || lowPower }
    }

    /// Called on the monitor's queue each time the policy applied to the core changes, with the
    /// conditions that decided it, so an app can log why backfill paused or resumed.
    public var onChange: (@Sendable (BackfillPolicy, Conditions) -> Void)?

    private let core: SyncCore
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ai.osaurus.sync.backfill-policy")
    private var conditions = Conditions(expensive: false, constrained: false, lowPower: false)
    private var applied: BackfillPolicy?
    private var appliedGentle: Bool?
    private var observers: [NSObjectProtocol] = []

    public init(core: SyncCore) {
        self.core = core
    }

    public func start() {
        conditions.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        conditions.hot = Self.isHot()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.update { $0.expensive = path.isExpensive; $0.constrained = path.isConstrained }
        }
        monitor.start(queue: queue)
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil
            ) { [weak self] _ in
                let low = ProcessInfo.processInfo.isLowPowerModeEnabled
                self?.queue.async { self?.update { $0.lowPower = low } }
            })
        observers.append(
            NotificationCenter.default.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil
            ) { [weak self] _ in
                let hot = Self.isHot()
                self?.queue.async { self?.update { $0.hot = hot } }
            })
        queue.async { self.update { _ in } }
    }

    public func stop() {
        monitor.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    deinit { stop() }

    private static func isHot() -> Bool {
        let state = ProcessInfo.processInfo.thermalState
        return state == .serious || state == .critical
    }

    private func update(_ change: (inout Conditions) -> Void) {
        change(&conditions)
        if conditions.gentle != appliedGentle, (try? core.setGentleSync(gentle: conditions.gentle)) != nil {
            appliedGentle = conditions.gentle
        }
        let policy = conditions.policy
        guard policy != applied else { return }
        if (try? core.setBackfillPolicy(policy: policy)) != nil {
            applied = policy
            onChange?(policy, conditions)
        }
    }
}
