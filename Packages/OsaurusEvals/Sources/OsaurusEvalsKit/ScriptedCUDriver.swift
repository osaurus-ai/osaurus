//
//  ScriptedCUDriver.swift
//  OsaurusEvalsKit
//
//  A deterministic, STATEFUL `MacDriver` for the `computer_use_loop`
//  domain. Unlike `MockMacDriver` (which replays a pre-scripted queue of
//  snapshots in capture order), this driver holds a mutable accessibility
//  tree and MUTATES it in response to the actions the loop performs —
//  `type`/`set_value`/`clear` rewrite a field's value, `click` toggles a
//  switch / stamps other elements / reveals hidden controls. That's the
//  only shape that survives a model-driven run, where the action ORDER is
//  unknown ahead of time so a fixed snapshot queue can't line up.
//
//  Everything the harness needs (perceive → resolve → act → verify) reads
//  back through `capture`, so a mutation immediately shows up as a changed
//  value on the next perception — which is exactly the `verifyChanged`
//  signal the loop and the scorer key off. No real Accessibility, no
//  SkyLight, no Screen Recording: a CU-loop case is reproducible and
//  CI-safe apart from the model call itself.
//

import Foundation
import OsaurusCore

public actor ScriptedCUDriver: MacDriver {

    // MARK: - Mutable cell

    /// One element in the scripted tree. `value`, `hidden`, the click-failure
    /// budget, and the async-reveal countdown are the mutable bits; ids /
    /// roles / labels / tier / scroll gating are fixed for the run so marks and
    /// change-detection keys stay stable.
    private struct Cell {
        let id: String
        let role: String
        let label: String?
        var value: String?
        let placeholder: String?
        let editable: Bool
        var hidden: Bool
        let onClick: EvalCase.ComputerUseLoopExpectations.ClickEffect?
        /// Lowest capture tier at which this cell is rendered.
        let minTier: CaptureTier
        /// Remaining element-addressed click failures (stale-ref simulation).
        var clickFailuresRemaining: Int
        /// Captures that must elapse before a revealed cell actually appears
        /// (async load). `nil` = not pending; `> 0` = ticking down.
        let revealAfterCaptures: Int
        var revealCountdown: Int?
        /// Below the fold until the loop scrolls.
        let revealOnScroll: Bool
    }

    // MARK: - State

    /// Synthetic pid for the single scripted app. Arbitrary but stable.
    private let pid: Int32 = 7777
    private let appName: String
    private var cells: [Cell]
    /// The currently focused element id (clicking or typing into a field
    /// focuses it). Drives `type` with no explicit target.
    private var focusedId: String?
    private var snapshotCounter = 0
    /// Set once the loop performs any scroll; gates `revealOnScroll` cells.
    private var didScroll = false

    // MARK: - Recorded signals (read by the scorer after the run)

    /// Every element/coordinate verb the loop executed, in order — the
    /// behaviour trace the report attributes failures against.
    public private(set) var executedVerbs: [String] = []
    /// Element ids that received at least one click.
    public private(set) var clickedIds: Set<String> = []

    // MARK: - Init

    public init(app: String, elements: [EvalCase.ComputerUseLoopExpectations.SceneElement]) {
        self.appName = app
        self.cells = elements.map { element in
            Cell(
                id: element.id,
                role: element.role,
                label: element.label,
                value: element.value,
                placeholder: element.placeholder,
                editable: element.editable ?? false,
                hidden: element.hidden ?? false,
                onClick: element.onClick,
                minTier: CaptureTier(rawValue: element.minTier ?? "ax") ?? .ax,
                clickFailuresRemaining: max(0, element.clickFailures ?? 0),
                revealAfterCaptures: max(0, element.revealAfterCaptures ?? 0),
                revealCountdown: nil,
                revealOnScroll: element.revealOnScroll ?? false
            )
        }
        // Seed focus on the first AX-visible editable field so a model that
        // types without an explicit target still lands somewhere sensible.
        self.focusedId =
            self.cells.first(where: { $0.editable && $0.minTier == .ax && !$0.hidden && !$0.revealOnScroll })?
            .id
    }

    /// Tier ordering helper: ax < som < vision.
    private static func tierRank(_ tier: CaptureTier) -> Int {
        CaptureTier.allCases.firstIndex(of: tier) ?? 0
    }

    // MARK: - Scorer read-back

    /// The final value of every cell, keyed by id (nil values render empty).
    public func finalValues() -> [String: String] {
        Dictionary(uniqueKeysWithValues: cells.map { ($0.id, $0.value ?? "") })
    }

    public func wasClicked(_ id: String) -> Bool { clickedIds.contains(id) }

    public func verbTrace() -> [String] { executedVerbs }

    // MARK: - MacDriver: perception

    public func availability() async -> MacDriverAvailability {
        MacDriverAvailability(accessibility: true, screenRecording: true, skyLight: true)
    }

    public func listApps() async -> [CUAppListing] {
        [CUAppListing(pid: pid, bundleId: nil, name: appName, active: true, hidden: false)]
    }

    public func listWindows(pid: Int32) async -> [CUWindowInfo] {
        [
            CUWindowInfo(
                windowId: 1,
                title: appName,
                focused: true,
                minimized: false,
                x: 0,
                y: 0,
                w: 1200,
                h: 800
            )
        ]
    }

    public func activeWindow() async -> CUActiveWindow? {
        CUActiveWindow(pid: pid, app: appName, title: appName, x: 0, y: 0, w: 1200, h: 800)
    }

    public func open(
        identifier: String,
        background: Bool
    ) async -> Result<CUAppInfo, MacDriverError> {
        // The scene is a single app; `open` always resolves to it so a model
        // that opens-before-acting and one that acts on the pre-focused app
        // both proceed.
        .success(CUAppInfo(pid: pid, bundleId: nil, name: appName))
    }

    public func capture(
        pid: Int32,
        tier: CaptureTier,
        windowId: Int?,
        maxElements: Int?,
        focusedWindowOnly: Bool,
        interactiveOnly: Bool
    ) async -> CUSnapshot {
        makeSnapshot(tier: tier)
    }

    public func find(
        pid: Int32,
        text: String?,
        roles: [String]?,
        windowId: Int?,
        enabledOnly: Bool,
        limit: Int
    ) async -> CUSnapshot {
        let base = makeSnapshot(tier: .ax)
        var elements = base.elements
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
        elements = Array(elements.prefix(max(0, limit)))
        return CUSnapshot(
            snapshotId: base.snapshotId,
            pid: base.pid,
            app: base.app,
            focusedWindow: base.focusedWindow,
            tier: .ax,
            truncated: base.truncated,
            windows: base.windows,
            elements: elements,
            image: nil
        )
    }

    public func screenshot(pid: Int32?, windowId: Int?, annotate: Bool) async -> CUImage? {
        // A real (tiny) PNG so the vision path receives decodable bytes; the
        // scripted tree is still the source of truth for what's actionable.
        Self.sampleImage
    }

    public func narrate(_ note: String, step: Int?, total: Int?) async {}

    // MARK: - MacDriver: actions

    public func perform(_ action: CUElementAction) async -> CUActionResult {
        switch action {
        case .click(let id, _, _):
            return applyClick(id: id, viaCoordinate: false)
        case .setValue(let id, let value):
            executedVerbs.append("set_value")
            return applyEdit(id: id, value: value)
        case .typeText(let id, _, let text, let replace):
            executedVerbs.append("type")
            guard let targetId = id ?? focusedId else {
                return .failure("No field is focused. Click a text field first, then type.")
            }
            let next: String
            if replace {
                next = text
            } else {
                next = (valueOf(targetId) ?? "") + text
            }
            return applyEdit(id: targetId, value: next)
        case .clearField(let id):
            executedVerbs.append("clear")
            return applyEdit(id: id, value: "")
        case .pressKey(_, let key, _):
            executedVerbs.append("press_key")
            // No global key bindings in the scripted world; the press is a
            // legible no-op success so a model that submits with Return
            // isn't penalised, but the field/toggle state is the contract.
            _ = key
            return .ok(delta: focusDelta())
        }
    }

    public func coordinate(_ action: CUCoordinateAction) async -> CUActionResult {
        switch action {
        case .click(let x, let y, _, _, _):
            // Map a raw coordinate click back to the nearest visible element
            // center. This is the loop's stale-ref fallback path, so a
            // coordinate click ALWAYS lands (ignores `clickFailures`) — that's
            // exactly the recovery the fallback exists to provide.
            if let hit = nearestVisible(toX: x, y: y) {
                return applyClick(id: hit, viaCoordinate: true)
            }
            executedVerbs.append("click")
            return .ok()
        case .scroll:
            executedVerbs.append("scroll")
            // Scrolling brings below-the-fold (`revealOnScroll`) cells into
            // view on the next capture.
            didScroll = true
            return .ok(delta: focusDelta())
        case .drag:
            executedVerbs.append("drag")
            return .ok()
        }
    }

    // MARK: - Mutation primitives

    private func applyClick(id: String, viaCoordinate: Bool) -> CUActionResult {
        guard let index = cells.firstIndex(where: { $0.id == id }), !cells[index].hidden else {
            return CUActionResult(success: false, error: "Element not found.", removed: true)
        }
        // Stale-ref injection: an element-addressed click fails as `removed`
        // until the budget is spent. The coordinate fallback bypasses this, so
        // a model that recovers via coordinates still makes progress.
        if !viaCoordinate, cells[index].clickFailuresRemaining > 0 {
            cells[index].clickFailuresRemaining -= 1
            return CUActionResult(
                success: false,
                error: "The element reference went stale between capture and click.",
                removed: true
            )
        }
        executedVerbs.append("click")
        clickedIds.insert(id)
        focusedId = id

        if let effect = cells[index].onClick {
            if effect.toggle == true {
                let current = (cells[index].value ?? "").lowercased()
                cells[index].value = (current == "on") ? "off" : "on"
            }
            for set in effect.setValues ?? [] {
                if let target = cells.firstIndex(where: { $0.id == set.id }) {
                    cells[target].value = set.value
                }
            }
            for revealId in effect.reveal ?? [] {
                if let target = cells.firstIndex(where: { $0.id == revealId }) {
                    // Async reveal: a cell with `revealAfterCaptures` starts a
                    // countdown and only appears after that many captures, so
                    // the model has to wait/observe; otherwise it shows at once.
                    if cells[target].revealAfterCaptures > 0 {
                        cells[target].revealCountdown = cells[target].revealAfterCaptures
                    } else {
                        cells[target].hidden = false
                    }
                }
            }
        }
        return .ok(delta: focusDelta())
    }

    private func applyEdit(id: String, value: String) -> CUActionResult {
        guard let index = cells.firstIndex(where: { $0.id == id }), !cells[index].hidden else {
            return CUActionResult(success: false, error: "Element not found.", removed: true)
        }
        guard cells[index].editable else {
            return .failure("That element isn't editable. Pick a text field.")
        }
        cells[index].value = value
        focusedId = id
        return .ok(delta: focusDelta())
    }

    // MARK: - Internals

    private func valueOf(_ id: String) -> String? {
        cells.first(where: { $0.id == id })?.value
    }

    /// Whether a cell is rendered into a capture at `tier`, honoring hidden /
    /// async-reveal countdown / scroll gating / minimum tier.
    private func isRendered(_ cell: Cell, tier: CaptureTier) -> Bool {
        if cell.hidden { return false }
        if let cd = cell.revealCountdown, cd > 0 { return false }
        if cell.revealOnScroll && !didScroll { return false }
        if Self.tierRank(cell.minTier) > Self.tierRank(tier) { return false }
        return true
    }

    private func nearestVisible(toX x: Double, y: Double) -> String? {
        // The most permissive tier — a coordinate click targets something the
        // model already saw, so tier gating shouldn't hide it from the hit test.
        let visible = cells.enumerated().filter { isRendered($0.element, tier: .vision) }
        guard !visible.isEmpty else { return nil }
        // Element layout mirrors `makeSnapshot`: a vertical stack, so match
        // on the row whose center y is closest.
        var best: (id: String, distance: Double)?
        for (index, cell) in visible {
            let centerY = Double(60 + index * 40 + 14)
            let centerX = Double(40 + 100)
            let distance = abs(centerY - y) + abs(centerX - x) * 0.01
            if best == nil || distance < best!.distance {
                best = (cell.id, distance)
            }
        }
        return best?.id
    }

    private func focusDelta() -> CUFocusDelta {
        guard let focusedId, let cell = cells.first(where: { $0.id == focusedId }) else {
            return CUFocusDelta(focusedWindow: appName, focusedElement: nil)
        }
        return CUFocusDelta(
            focusedWindow: appName,
            focusedElement: CUFocusedElement(role: cell.role, label: cell.label, value: cell.value)
        )
    }

    private func makeSnapshot(tier: CaptureTier) -> CUSnapshot {
        snapshotCounter += 1
        // Advance async-reveal countdowns one tick per capture; a cell whose
        // countdown reaches zero becomes visible in THIS snapshot, so the model
        // must wait/observe for it.
        for i in cells.indices {
            if let cd = cells[i].revealCountdown, cd > 0 {
                let next = cd - 1
                cells[i].revealCountdown = next
                if next == 0 { cells[i].hidden = false }
            }
        }
        // Stable render order = declaration order of visible cells, so the
        // 1-based marks the model addresses don't shuffle between captures.
        // `index` stays the RAW cell index so element y-coordinates (and the
        // coordinate hit-test in `nearestVisible`) line up.
        var elements: [CUElement] = []
        for (index, cell) in cells.enumerated() where isRendered(cell, tier: tier) {
            elements.append(
                CUElement(
                    id: cell.id,
                    role: cell.role,
                    roleDescription: nil,
                    label: cell.label,
                    value: cell.value,
                    placeholder: cell.placeholder,
                    path: nil,
                    windowId: 1,
                    focused: cell.id == focusedId,
                    enabled: true,
                    x: 40,
                    y: 60 + index * 40,
                    w: 200,
                    h: 28,
                    actions: []
                )
            )
        }
        // SOM / vision captures carry a real (tiny) decodable PNG, not an empty
        // placeholder, so the vision attachment path has genuine bytes.
        let pixels = tier == .ax ? nil : Self.sampleImage
        return CUSnapshot(
            snapshotId: snapshotCounter,
            pid: pid,
            app: appName,
            focusedWindow: appName,
            tier: tier,
            truncated: false,
            windows: [
                CUWindowSummary(id: 1, title: appName, focused: true, x: 0, y: 0, w: 1200, h: 800)
            ],
            elements: elements,
            image: pixels
        )
    }

    /// A real 1×1 PNG (transparent) so SOM/vision snapshots and `screenshot`
    /// carry decodable bytes rather than an empty-string placeholder.
    private static let sampleImage = CUImage(
        base64:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC",
        mimeType: "image/png",
        width: 1,
        height: 1
    )
}
