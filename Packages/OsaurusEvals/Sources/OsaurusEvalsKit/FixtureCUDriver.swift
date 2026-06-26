//
//  FixtureCUDriver.swift
//  OsaurusEvalsKit
//
//  A read-only `MacDriver` that replays a frozen `ScreenContextFixture` so the
//  `ScreenContextDistiller` can be scored deterministically — the perception
//  analogue of `ScriptedCUDriver` (which is stateful and action-driven for the
//  `computer_use_loop` domain). Here nothing mutates: the distiller only
//  perceives (availability → activeWindow → listApps → listWindows → capture →
//  focusedContent → optional find), so every action verb is a no-op.
//
//  Two perception details are modeled faithfully because the distiller's
//  reliability heuristics depend on them:
//    1. `capture(maxElements:)` honors the budget (prefix-clips and flags
//       `truncated`), reproducing the chrome-heavy-app case where the bounded
//       traversal exhausts before the editor.
//    2. `find(...)` searches the FULL fixture element set (not the clipped
//       capture), like the real server-side AX query — so the distiller's
//       targeted `textarea` fallback can recover an editor the capture missed.
//

import Foundation
import OsaurusCore

public actor FixtureCUDriver: MacDriver {

    private let fixture: ScreenContextFixture
    /// Monotonic capture id so successive `capture`/`find` calls get distinct
    /// snapshot ids (the distiller doesn't rely on it, but real snapshots have
    /// unique ids and a fixture should behave the same).
    private var snapshotCounter = 0

    public init(fixture: ScreenContextFixture) {
        self.fixture = fixture
    }

    // MARK: - Perception

    public func availability() async -> MacDriverAvailability {
        // AX granted (the fixture IS the accessibility tree). Screen-recording /
        // SkyLight are irrelevant to the text-only distiller but reported true
        // so nothing gates on them.
        MacDriverAvailability(accessibility: true, screenRecording: true, skyLight: true)
    }

    public func listApps() async -> [CUAppListing] {
        fixture.apps
    }

    public func listWindows(pid: Int32) async -> [CUWindowInfo] {
        fixture.windows(forPid: pid)
    }

    public func activeWindow() async -> CUActiveWindow? {
        fixture.activeWindow
    }

    public func focusedContent(pid: Int32) async -> CUFocusedContent? {
        fixture.focusedContent
    }

    public func capture(
        pid: Int32,
        tier: CaptureTier,
        windowId: Int?,
        maxElements: Int?,
        focusedWindowOnly: Bool,
        interactiveOnly: Bool
    ) async -> CUSnapshot {
        snapshotCounter += 1
        return fixture.cuSnapshot(pid: pid, snapshotId: snapshotCounter, maxElements: maxElements)
    }

    public func find(
        pid: Int32,
        text: String?,
        roles: [String]?,
        windowId: Int?,
        enabledOnly: Bool,
        limit: Int
    ) async -> CUSnapshot {
        snapshotCounter += 1
        // Search the FULL element set (server-side AX query semantics), not the
        // budget-clipped capture — that's what lets the distiller's fallback
        // recover an editor a chrome-heavy capture exhausted past.
        var elements = fixture.snapshot.elements
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
        if enabledOnly {
            elements = elements.filter { $0.enabled }
        }
        elements = Array(elements.prefix(max(0, limit)))
        return CUSnapshot(
            snapshotId: snapshotCounter,
            pid: pid,
            app: fixture.snapshot.app,
            focusedWindow: fixture.snapshot.focusedWindow,
            tier: .ax,
            truncated: false,
            windows: fixture.snapshot.windows,
            elements: elements,
            image: nil
        )
    }

    public func screenshot(pid: Int32?, windowId: Int?, annotate: Bool) async -> CUImage? {
        // Text-only fixtures carry no pixels; the distiller never asks anyway.
        nil
    }

    // MARK: - Actions (read-only fixture → no-ops)

    public func open(
        identifier: String,
        background: Bool
    ) async -> Result<CUAppInfo, MacDriverError> {
        if let active = fixture.activeWindow {
            return .success(CUAppInfo(pid: active.pid, bundleId: nil, name: active.app))
        }
        if let app = fixture.apps.first {
            return .success(CUAppInfo(pid: app.pid, bundleId: app.bundleId, name: app.name))
        }
        return .failure(.appNotFound(identifier))
    }

    public func perform(_ action: CUElementAction) async -> CUActionResult {
        .failure("FixtureCUDriver is read-only (perception replay); actions are not supported.")
    }

    public func coordinate(_ action: CUCoordinateAction) async -> CUActionResult {
        .failure("FixtureCUDriver is read-only (perception replay); actions are not supported.")
    }

    public func narrate(_ note: String, step: Int?, total: Int?) async {}
}
