//
//  MockMacDriver.swift
//  OsaurusCore — Computer Use
//
//  An in-memory `MacDriver` conformer for tests and the PR1 demo. Serves
//  scripted snapshots and action results and records every call so harness
//  behavior (perceive → decide → gate → act → verify) can be asserted without
//  touching the real Accessibility / SkyLight stack.
//

import Foundation

public actor MockMacDriver: MacDriver {
    // MARK: Scriptable state

    private var _availability: MacDriverAvailability
    private var apps: [CUAppListing]
    private var windowsByPid: [Int32: [CUWindowInfo]]
    private var active: CUActiveWindow?
    private var openOverride: Result<CUAppInfo, MacDriverError>?

    /// Per-pid queue of snapshots returned by `capture`/`find`, in order. The
    /// last entry repeats once the queue is exhausted (steady state).
    private var snapshotQueue: [Int32: [CUSnapshot]]
    private var snapshotCursor: [Int32: Int] = [:]

    /// Optional queue of action results; when empty, actions succeed.
    private var actionResultQueue: [CUActionResult] = []

    // MARK: Recorded calls (for assertions)

    public private(set) var elementActions: [CUElementAction] = []
    public private(set) var coordinateActions: [CUCoordinateAction] = []
    public private(set) var narrations: [(note: String, step: Int?, total: Int?)] = []
    public private(set) var captureCount: Int = 0
    /// `interactiveOnly` argument from the most recent `capture` call, so tests
    /// can assert the screen-context distiller requests a content-inclusive tree.
    public private(set) var lastCaptureInteractiveOnly: Bool?

    // MARK: Init

    public init(
        availability: MacDriverAvailability = MacDriverAvailability(
            accessibility: true,
            screenRecording: true,
            skyLight: true
        ),
        apps: [CUAppListing] = [],
        windowsByPid: [Int32: [CUWindowInfo]] = [:],
        activeWindow: CUActiveWindow? = nil,
        snapshots: [Int32: [CUSnapshot]] = [:]
    ) {
        self._availability = availability
        self.apps = apps
        self.windowsByPid = windowsByPid
        self.active = activeWindow
        self.snapshotQueue = snapshots
    }

    // MARK: Scripting API

    public func setAvailability(_ a: MacDriverAvailability) { _availability = a }
    public func setApps(_ a: [CUAppListing]) { apps = a }
    public func setOpenResult(_ r: Result<CUAppInfo, MacDriverError>) { openOverride = r }
    public func enqueueSnapshots(_ snaps: [CUSnapshot], pid: Int32) {
        snapshotQueue[pid, default: []].append(contentsOf: snaps)
    }
    public func enqueueActionResults(_ results: [CUActionResult]) {
        actionResultQueue.append(contentsOf: results)
    }

    // MARK: MacDriver

    public func availability() async -> MacDriverAvailability { _availability }

    public func listApps() async -> [CUAppListing] { apps }

    public func listWindows(pid: Int32) async -> [CUWindowInfo] { windowsByPid[pid] ?? [] }

    public func activeWindow() async -> CUActiveWindow? { active }

    public func open(
        identifier: String,
        background: Bool
    ) async -> Result<CUAppInfo, MacDriverError> {
        if let openOverride { return openOverride }
        if let match = apps.first(where: {
            $0.name.lowercased() == identifier.lowercased()
                || $0.bundleId?.lowercased() == identifier.lowercased()
        }) {
            return .success(CUAppInfo(pid: match.pid, bundleId: match.bundleId, name: match.name))
        }
        // Synthesize a new app so demos/tests can drive a never-seen identifier.
        let pid = Int32(truncatingIfNeeded: abs(identifier.hashValue) % 90000 + 1000)
        let info = CUAppInfo(pid: pid, bundleId: nil, name: identifier)
        apps.append(CUAppListing(pid: pid, bundleId: nil, name: identifier, active: false, hidden: true))
        return .success(info)
    }

    public func capture(
        pid: Int32,
        tier: CaptureTier,
        windowId: Int?,
        maxElements: Int?,
        focusedWindowOnly: Bool,
        interactiveOnly: Bool
    ) async -> CUSnapshot {
        captureCount += 1
        lastCaptureInteractiveOnly = interactiveOnly
        return nextSnapshot(pid: pid, tier: tier)
    }

    public func find(
        pid: Int32,
        text: String?,
        roles: [String]?,
        windowId: Int?,
        enabledOnly: Bool,
        limit: Int
    ) async -> CUSnapshot {
        var snap = nextSnapshot(pid: pid, tier: .ax)
        // Apply a best-effort filter so `find` behaves like a server-side query.
        var elements = snap.elements
        if let text, !text.isEmpty {
            let needle = text.lowercased()
            elements = elements.filter {
                ($0.label?.lowercased().contains(needle) ?? false)
                    || ($0.value?.lowercased().contains(needle) ?? false)
            }
        }
        if let roles, !roles.isEmpty {
            let want = Set(roles.map { $0.lowercased() })
            elements = elements.filter { want.contains($0.role.lowercased()) }
        }
        if enabledOnly { elements = elements.filter { $0.enabled } }
        elements = Array(elements.prefix(limit))
        snap = CUSnapshot(
            snapshotId: snap.snapshotId,
            pid: snap.pid,
            app: snap.app,
            focusedWindow: snap.focusedWindow,
            tier: .ax,
            truncated: snap.truncated,
            windows: snap.windows,
            elements: elements,
            image: nil
        )
        return snap
    }

    public func perform(_ action: CUElementAction) async -> CUActionResult {
        elementActions.append(action)
        return nextActionResult()
    }

    public func coordinate(_ action: CUCoordinateAction) async -> CUActionResult {
        coordinateActions.append(action)
        return nextActionResult()
    }

    public func screenshot(pid: Int32?, windowId: Int?, annotate: Bool) async -> CUImage? {
        CUImage(base64: "", mimeType: "image/jpeg", width: 0, height: 0)
    }

    public func narrate(_ note: String, step: Int?, total: Int?) async {
        narrations.append((note, step, total))
    }

    // MARK: Internals

    private func nextSnapshot(pid: Int32, tier: CaptureTier) -> CUSnapshot {
        guard let queue = snapshotQueue[pid], !queue.isEmpty else {
            return CUSnapshot(
                snapshotId: captureCount,
                pid: pid,
                app: appName(pid),
                focusedWindow: nil,
                tier: tier,
                truncated: false,
                windows: [],
                elements: [],
                image: nil
            )
        }
        let idx = min(snapshotCursor[pid] ?? 0, queue.count - 1)
        snapshotCursor[pid] = idx + 1
        return queue[idx]
    }

    private func nextActionResult() -> CUActionResult {
        if actionResultQueue.isEmpty { return .ok() }
        return actionResultQueue.removeFirst()
    }

    private func appName(_ pid: Int32) -> String {
        apps.first(where: { $0.pid == pid })?.name ?? "MockApp"
    }
}

// MARK: - Demo / test fixtures

extension MockMacDriver {
    /// A minimal driver seeded with one app and a two-element snapshot, suitable
    /// for the PR1 read-only demo and quick tests.
    public static func demo() -> MockMacDriver {
        let pid: Int32 = 4242
        let app = CUAppListing(
            pid: pid,
            bundleId: "com.example.Demo",
            name: "Demo",
            active: false,
            hidden: true
        )
        let window = CUWindowSummary(
            id: 1,
            title: "Demo Window",
            focused: true,
            x: 0,
            y: 0,
            w: 1200,
            h: 800
        )
        let elements = [
            CUElement(
                id: "s1-1",
                role: "textfield",
                label: "Search",
                value: nil,
                path: "Window[Demo] > textfield",
                windowId: 1,
                focused: true,
                enabled: true,
                x: 40,
                y: 60,
                w: 400,
                h: 28,
                actions: ["confirm"]
            ),
            CUElement(
                id: "s1-2",
                role: "button",
                label: "Go",
                path: "Window[Demo] > button[Go]",
                windowId: 1,
                enabled: true,
                x: 460,
                y: 60,
                w: 60,
                h: 28,
                actions: ["press"]
            ),
        ]
        let snapshot = CUSnapshot(
            snapshotId: 1,
            pid: pid,
            app: "Demo",
            focusedWindow: "Demo Window",
            tier: .ax,
            truncated: false,
            windows: [window],
            elements: elements,
            image: nil
        )
        return MockMacDriver(apps: [app], snapshots: [pid: [snapshot]])
    }
}
