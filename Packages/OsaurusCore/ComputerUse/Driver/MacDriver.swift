//
//  MacDriver.swift
//  OsaurusCore — Computer Use
//
//  The seam between the Computer Use harness (loop / envelope / gate / policy /
//  feed) and the macOS driver internals (AX / AppKit / private frameworks).
//
//  The harness and `MockMacDriver` only ever speak these `CU…` contract types,
//  reproduced from the driver's REFERENCE.md schemas. `NativeMacDriver` is the
//  in-process conformer over the ported `Driver/Mac/*` classes.
//

import Foundation

// MARK: - Capture Tier

/// Perception modality the harness asks the driver for. Mirrors the driver's
/// `CaptureMode` but lives in the contract so the harness/mock never import
/// driver internals.
public enum CaptureTier: String, Codable, Sendable, CaseIterable {
    /// Accessibility tree only. No Screen Recording permission needed. Fastest.
    case ax
    /// Set-of-mark: AX tree + annotated screenshot.
    case som
    /// Screenshot only (pixels), AX tree still gathered for ids.
    case vision
}

// MARK: - Snapshot contract

/// One actionable element in the model-agnostic, id-stable contract shape.
public struct CUElement: Sendable, Equatable, Codable {
    public let id: String
    public let role: String
    public let roleDescription: String?
    public let label: String?
    public let value: String?
    public let placeholder: String?
    public let path: String?
    public let windowId: Int?
    public let focused: Bool
    public let enabled: Bool
    public let x: Int
    public let y: Int
    public let w: Int
    public let h: Int
    public let actions: [String]

    public init(
        id: String,
        role: String,
        roleDescription: String? = nil,
        label: String? = nil,
        value: String? = nil,
        placeholder: String? = nil,
        path: String? = nil,
        windowId: Int? = nil,
        focused: Bool = false,
        enabled: Bool = true,
        x: Int = 0,
        y: Int = 0,
        w: Int = 0,
        h: Int = 0,
        actions: [String] = []
    ) {
        self.id = id
        self.role = role
        self.roleDescription = roleDescription
        self.label = label
        self.value = value
        self.placeholder = placeholder
        self.path = path
        self.windowId = windowId
        self.focused = focused
        self.enabled = enabled
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.actions = actions
    }

    /// Center point in global screen coordinates.
    public var center: (x: Int, y: Int) { (x + w / 2, y + h / 2) }
}

public struct CUWindowSummary: Sendable, Equatable, Codable {
    public let id: Int
    public let title: String?
    public let focused: Bool
    public let x: Int
    public let y: Int
    public let w: Int
    public let h: Int

    public init(
        id: Int,
        title: String?,
        focused: Bool,
        x: Int,
        y: Int,
        w: Int,
        h: Int
    ) {
        self.id = id
        self.title = title
        self.focused = focused
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

/// Encoded screenshot bytes for the som/vision tiers.
public struct CUImage: Sendable, Equatable {
    public let base64: String
    public let mimeType: String
    public let width: Int
    public let height: Int

    public init(base64: String, mimeType: String, width: Int, height: Int) {
        self.base64 = base64
        self.mimeType = mimeType
        self.width = width
        self.height = height
    }
}

/// A perceived view of an app at a point in time. `snapshotId` scopes the
/// element ids: an id from an older snapshot is "stale" once it rotates out.
public struct CUSnapshot: Sendable {
    public let snapshotId: Int
    public let pid: Int32
    public let app: String
    public let focusedWindow: String?
    public let tier: CaptureTier
    public let truncated: Bool
    public let windows: [CUWindowSummary]
    public let elements: [CUElement]
    public let image: CUImage?

    public init(
        snapshotId: Int,
        pid: Int32,
        app: String,
        focusedWindow: String?,
        tier: CaptureTier,
        truncated: Bool,
        windows: [CUWindowSummary],
        elements: [CUElement],
        image: CUImage?
    ) {
        self.snapshotId = snapshotId
        self.pid = pid
        self.app = app
        self.focusedWindow = focusedWindow
        self.tier = tier
        self.truncated = truncated
        self.windows = windows
        self.elements = elements
        self.image = image
    }

    public var focusedWindowId: Int? { windows.first(where: { $0.focused })?.id }
}

// MARK: - App / window listings

public struct CUAppInfo: Sendable, Equatable, Codable {
    public let pid: Int32
    public let bundleId: String?
    public let name: String

    public init(pid: Int32, bundleId: String?, name: String) {
        self.pid = pid
        self.bundleId = bundleId
        self.name = name
    }
}

public struct CUAppListing: Sendable, Equatable, Codable {
    public let pid: Int32
    public let bundleId: String?
    public let name: String
    public let active: Bool
    public let hidden: Bool

    public init(pid: Int32, bundleId: String?, name: String, active: Bool, hidden: Bool) {
        self.pid = pid
        self.bundleId = bundleId
        self.name = name
        self.active = active
        self.hidden = hidden
    }
}

public struct CUWindowInfo: Sendable, Equatable, Codable {
    public let windowId: Int
    public let title: String?
    public let focused: Bool
    public let minimized: Bool
    public let x: Int
    public let y: Int
    public let w: Int
    public let h: Int

    public init(
        windowId: Int,
        title: String?,
        focused: Bool,
        minimized: Bool,
        x: Int,
        y: Int,
        w: Int,
        h: Int
    ) {
        self.windowId = windowId
        self.title = title
        self.focused = focused
        self.minimized = minimized
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

public struct CUActiveWindow: Sendable, Equatable, Codable {
    public let pid: Int32
    public let app: String
    public let title: String?
    public let x: Int
    public let y: Int
    public let w: Int
    public let h: Int

    public init(pid: Int32, app: String, title: String?, x: Int, y: Int, w: Int, h: Int) {
        self.pid = pid
        self.app = app
        self.title = title
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

// MARK: - Action result

/// What the focus moved to after an action — the harness's primary verify
/// signal alongside the re-observed snapshot.
public struct CUFocusedElement: Sendable, Equatable, Codable {
    public let role: String
    public let label: String?
    public let value: String?

    public init(role: String, label: String?, value: String?) {
        self.role = role
        self.label = label
        self.value = value
    }
}

public struct CUFocusDelta: Sendable, Equatable, Codable {
    public let focusedWindow: String?
    public let focusedElement: CUFocusedElement?

    public init(focusedWindow: String?, focusedElement: CUFocusedElement?) {
        self.focusedWindow = focusedWindow
        self.focusedElement = focusedElement
    }
}

/// Result of an element/coordinate action. `stale`/`removed` tell the harness
/// to re-observe rather than abandon the goal.
public struct CUActionResult: Sendable, Equatable, Codable {
    public let success: Bool
    public let error: String?
    public let stale: Bool
    public let removed: Bool
    public let delta: CUFocusDelta?
    /// Which input transport actually delivered the event, for actions that
    /// synthesize input (click/type/press/scroll/drag). `nil` for actions that
    /// don't (observe/find/screenshot). Lets the agent and tests see when the
    /// cursor warped (`hidFallback`) or a Chromium click likely missed
    /// (`perPid`), instead of the transport being invisible.
    public let routeUsed: InputRoute?

    public init(
        success: Bool,
        error: String? = nil,
        stale: Bool = false,
        removed: Bool = false,
        delta: CUFocusDelta? = nil,
        routeUsed: InputRoute? = nil
    ) {
        self.success = success
        self.error = error
        self.stale = stale
        self.removed = removed
        self.delta = delta
        self.routeUsed = routeUsed
    }

    public static func ok(delta: CUFocusDelta? = nil, routeUsed: InputRoute? = nil) -> CUActionResult {
        CUActionResult(success: true, delta: delta, routeUsed: routeUsed)
    }

    public static func failure(_ message: String) -> CUActionResult {
        CUActionResult(success: false, error: message)
    }
}

// MARK: - Action inputs

public enum CUMouseButton: String, Sendable, Codable {
    case left
    case right
    case center
}

public enum CUScrollDirection: String, Sendable, Codable, CaseIterable {
    case up
    case down
    case left
    case right
}

/// An action addressed to a cached snapshot element id (or, for type/press, a
/// pid context). These are the actions the loop's Verify folds with a capture.
public enum CUElementAction: Sendable {
    case click(id: String, button: CUMouseButton = .left, doubleClick: Bool = false)
    case setValue(id: String, value: String)
    case typeText(id: String?, pid: Int32?, text: String, replace: Bool = true)
    case pressKey(pid: Int32?, key: String, modifiers: [String] = [])
    case clearField(id: String)
}

/// An action addressed to raw screen coordinates / a pid (no element id).
public enum CUCoordinateAction: Sendable {
    case click(
        x: Double,
        y: Double,
        button: CUMouseButton = .left,
        doubleClick: Bool = false,
        pid: Int32? = nil
    )
    case scroll(
        direction: CUScrollDirection,
        amount: Int32 = 3,
        x: Double? = nil,
        y: Double? = nil,
        pid: Int32? = nil
    )
    case drag(startX: Double, startY: Double, endX: Double, endY: Double, pid: Int32? = nil)
}

// MARK: - Availability + errors

/// macOS permission/capability posture the harness checks before driving.
public struct MacDriverAvailability: Sendable, Equatable {
    public let accessibility: Bool
    public let screenRecording: Bool
    public let skyLight: Bool

    public init(accessibility: Bool, screenRecording: Bool, skyLight: Bool) {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
        self.skyLight = skyLight
    }
}

public enum MacDriverError: Error, Sendable, Equatable {
    case accessibilityNotGranted
    case screenRecordingNotGranted
    case appNotFound(String)
    case captureFailed(String)
    case other(String)

    public var message: String {
        switch self {
        case .accessibilityNotGranted:
            return L("Accessibility permission is required to perceive and control apps.")
        case .screenRecordingNotGranted:
            return L("Screen Recording permission is required for screenshot (som/vision) capture.")
        case .appNotFound(let id):
            return L("Application not found: \(id)")
        case .captureFailed(let m):
            return L("Capture failed: \(m)")
        case .other(let m):
            return m
        }
    }
}

// MARK: - MacDriver protocol

/// The single seam the harness drives macOS through. Conformers: the
/// in-process `NativeMacDriver` and the in-memory `MockMacDriver`.
public protocol MacDriver: Sendable {
    /// Current macOS permission posture.
    func availability() async -> MacDriverAvailability

    /// Running, AX-addressable GUI apps.
    func listApps() async -> [CUAppListing]

    /// Windows for a pid, with stable on-screen window ids.
    func listWindows(pid: Int32) async -> [CUWindowInfo]

    /// The user's current frontmost window (for context, never to raise).
    func activeWindow() async -> CUActiveWindow?

    /// Launch (or attach to) an app, backgrounded by default.
    func open(identifier: String, background: Bool) async -> Result<CUAppInfo, MacDriverError>

    /// Perceive an app at a given tier. `interactiveOnly` controls whether the
    /// AX traversal keeps only actionable elements (buttons, fields, …) or also
    /// includes passive content roles like `statictext` — the latter is what
    /// the screen-context distiller needs to surface real on-screen text rather
    /// than UI chrome.
    func capture(
        pid: Int32,
        tier: CaptureTier,
        windowId: Int?,
        maxElements: Int?,
        focusedWindowOnly: Bool,
        interactiveOnly: Bool
    ) async -> CUSnapshot

    /// Server-side element query (a filtered capture). Always ax-tier.
    func find(
        pid: Int32,
        text: String?,
        roles: [String]?,
        windowId: Int?,
        enabledOnly: Bool,
        limit: Int
    ) async -> CUSnapshot

    /// Perform an element-addressed action.
    func perform(_ action: CUElementAction) async -> CUActionResult

    /// Perform a coordinate/pid-addressed action.
    func coordinate(_ action: CUCoordinateAction) async -> CUActionResult

    /// Capture a screenshot (used by the escalation/vision path).
    func screenshot(pid: Int32?, windowId: Int?, annotate: Bool) async -> CUImage?

    /// Record side-effect-free narration/telemetry for legibility.
    func narrate(_ note: String, step: Int?, total: Int?) async
}

// MARK: - Convenience overloads

extension MacDriver {
    public func capture(pid: Int32, tier: CaptureTier) async -> CUSnapshot {
        await capture(
            pid: pid,
            tier: tier,
            windowId: nil,
            maxElements: nil,
            focusedWindowOnly: false,
            interactiveOnly: true
        )
    }

    public func find(pid: Int32, text: String?, roles: [String]?) async -> CUSnapshot {
        await find(
            pid: pid,
            text: text,
            roles: roles,
            windowId: nil,
            enabledOnly: false,
            limit: 10
        )
    }

    public func open(identifier: String) async -> Result<CUAppInfo, MacDriverError> {
        await open(identifier: identifier, background: true)
    }
}
