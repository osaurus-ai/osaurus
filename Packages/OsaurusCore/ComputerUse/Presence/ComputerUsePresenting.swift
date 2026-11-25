//
//  ComputerUsePresenting.swift
//  OsaurusCore — Computer Use
//
//  The seam between `ComputerUseLoop` and whatever shows the user that an
//  agent has the app: the takeover shield, status pill, and keyboard guard in
//  the app; nothing in evals and unit tests. The loop awaits each call, so a
//  presenter can make its surface click-through before a pointer action posts.
//

import CoreGraphics
import Foundation

/// The window the run is driving, from the latest snapshot.
public struct ComputerUsePresenceTarget: Sendable, Equatable {
    public let pid: Int32
    public let app: String
    /// The focused (else first) window in global top-left screen points.
    public let windowFrame: CGRect?

    public init(pid: Int32, app: String, windowFrame: CGRect?) {
        self.pid = pid
        self.app = app
        self.windowFrame = windowFrame
    }

    init?(snapshot: CUSnapshot?) {
        guard let snapshot else { return nil }
        let window = snapshot.windows.first(where: \.focused) ?? snapshot.windows.first
        let frame = window.flatMap { w -> CGRect? in
            guard w.w > 0, w.h > 0 else { return nil }
            return CGRect(x: w.x, y: w.y, width: w.w, height: w.h)
        }
        self.init(pid: snapshot.pid, app: snapshot.app, windowFrame: frame)
    }
}

/// One action about to be performed against the target.
public struct ComputerUsePresenceAct: Sendable, Equatable {
    public let verb: String
    /// Where the action lands, in global top-left screen points, when known.
    public let point: CGPoint?
    /// True for verbs that post mouse events. Those may reach the app through
    /// the HID tap, which hit-tests the topmost window, so a shield must let
    /// mouse events through until `didAct`.
    public let movesPointer: Bool

    public init(verb: String, point: CGPoint?, movesPointer: Bool) {
        self.verb = verb
        self.point = point
        self.movesPointer = movesPointer
    }
}

public protocol ComputerUsePresenting: Sendable {
    func begin(goal: String) async
    func targetChanged(_ target: ComputerUsePresenceTarget?) async
    func willAct(_ act: ComputerUsePresenceAct) async
    func didAct() async
    func confirmPending(_ pending: Bool) async
    /// Called while the run is alive, at `ComputerUseLoop.presenceHeartbeatSeconds`.
    func heartbeat() async
    /// Called exactly once, for every outcome.
    func end(_ outcome: RunOutcome) async
}

public struct ComputerUseNoopPresenter: ComputerUsePresenting {
    public init() {}
    public func begin(goal: String) async {}
    public func targetChanged(_ target: ComputerUsePresenceTarget?) async {}
    public func willAct(_ act: ComputerUsePresenceAct) async {}
    public func didAct() async {}
    public func confirmPending(_ pending: Bool) async {}
    public func heartbeat() async {}
    public func end(_ outcome: RunOutcome) async {}
}
