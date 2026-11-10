import Foundation
import Network

/// Pauses background backfill of older history on expensive (cellular, personal hotspot) or
/// constrained (Low Data Mode) networks and in Low Power Mode, and resumes it otherwise.
/// Live sync and on-demand history fetches are unaffected.
public final class BackfillPolicyMonitor: @unchecked Sendable {
    public struct Conditions: Equatable, Sendable {
        public var expensive: Bool
        public var constrained: Bool
        public var lowPower: Bool

        public init(expensive: Bool, constrained: Bool, lowPower: Bool) {
            self.expensive = expensive
            self.constrained = constrained
            self.lowPower = lowPower
        }

        public var policy: BackfillPolicy {
            expensive || constrained || lowPower ? .paused : .run
        }
    }

    private let core: SyncCore
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ai.osaurus.sync.backfill-policy")
    private var conditions = Conditions(expensive: false, constrained: false, lowPower: false)
    private var applied: BackfillPolicy?
    private var observer: NSObjectProtocol?

    public init(core: SyncCore) {
        self.core = core
    }

    public func start() {
        conditions.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        monitor.pathUpdateHandler = { [weak self] path in
            self?.update { $0.expensive = path.isExpensive; $0.constrained = path.isConstrained }
        }
        monitor.start(queue: queue)
        observer = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            let low = ProcessInfo.processInfo.isLowPowerModeEnabled
            self?.queue.async { self?.update { $0.lowPower = low } }
        }
        queue.async { self.update { _ in } }
    }

    public func stop() {
        monitor.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    deinit { stop() }

    private func update(_ change: (inout Conditions) -> Void) {
        change(&conditions)
        let policy = conditions.policy
        guard policy != applied else { return }
        if (try? core.setBackfillPolicy(policy: policy)) != nil {
            applied = policy
        }
    }
}
