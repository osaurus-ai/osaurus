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

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import OsaurusCore
import UniformTypeIdentifiers

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
        /// Effect of Return while this cell is focused (scene `onReturn`).
        let onReturn: EvalCase.ComputerUseLoopExpectations.ClickEffect?
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
        /// Titles `select` can pick (scene `options`).
        let options: [String]?
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
    /// When true, `open` reports `ready: false` and the next capture is empty
    /// — the "process is up, tree not queryable yet" shape.
    private let openNotReady: Bool
    /// Captures still to serve as an empty tree (armed by a not-ready open).
    private var emptyCapturesRemaining = 0

    // MARK: - Recorded signals (read by the scorer after the run)

    /// Every element/coordinate verb the loop executed, in order — the
    /// behaviour trace the report attributes failures against.
    public private(set) var executedVerbs: [String] = []
    /// Element ids that received at least one click.
    public private(set) var clickedIds: Set<String> = []
    /// Element ids the pointer hovered over.
    public private(set) var hoveredIds: Set<String> = []

    // MARK: - Init

    public init(
        app: String,
        elements: [EvalCase.ComputerUseLoopExpectations.SceneElement],
        openNotReady: Bool = false
    ) {
        self.appName = app
        self.openNotReady = openNotReady
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
                onReturn: element.onReturn,
                minTier: CaptureTier(rawValue: element.minTier ?? "ax") ?? .ax,
                clickFailuresRemaining: max(0, element.clickFailures ?? 0),
                revealAfterCaptures: max(0, element.revealAfterCaptures ?? 0),
                revealCountdown: nil,
                revealOnScroll: element.revealOnScroll ?? false,
                options: element.options
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
        executedVerbs.append("open")
        if openNotReady {
            // Readiness poll exhausted: the loop's follow-up capture must come
            // back empty so it reports the open as not ready, not "Opened".
            emptyCapturesRemaining = 1
            return .success(CUAppInfo(pid: pid, bundleId: nil, name: appName, ready: false))
        }
        return .success(CUAppInfo(pid: pid, bundleId: nil, name: appName))
    }

    public func capture(
        pid: Int32,
        tier: CaptureTier,
        windowId: Int?,
        maxElements: Int?,
        focusedWindowOnly: Bool,
        interactiveOnly: Bool
    ) async -> CUSnapshot {
        if emptyCapturesRemaining > 0 {
            emptyCapturesRemaining -= 1
            snapshotCounter += 1
            return CUSnapshot(
                snapshotId: snapshotCounter,
                pid: pid,
                app: appName,
                focusedWindow: nil,
                tier: tier,
                truncated: false,
                windows: [],
                elements: [],
                image: nil
            )
        }
        return makeSnapshot(tier: tier)
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
        renderImage(tier: .vision, region: Self.windowFrame, scale: Self.frameScale)
    }

    public func zoom(pid: Int32, region: CUScreenRegion) async -> CUImage? {
        let area = CGRect(x: region.x, y: region.y, width: region.w, height: region.h).intersection(Self.windowFrame)
        guard !area.isNull, area.width >= 1, area.height >= 1 else { return nil }
        return renderImage(tier: .vision, region: area, scale: 1)
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
        case .adjust:
            executedVerbs.append("adjust")
            return .failure("The scripted world has no adjustable controls.")
        case .selectOption(let id, let option):
            executedVerbs.append("select")
            guard let index = cells.firstIndex(where: { $0.id == id }), !cells[index].hidden else {
                return CUActionResult(success: false, error: "Element not found.", removed: true)
            }
            guard let options = cells[index].options else {
                return .failure("This control doesn't open a list of options. Click it, then click the option.")
            }
            let want = option.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let picked = options.first(where: { $0.lowercased() == want }) else {
                return .failure(
                    "No single option matches \"\(option)\". Options: \(options.joined(separator: ", "))."
                )
            }
            cells[index].value = picked
            focusedId = id
            return .ok(delta: focusDelta())
        case .pressKey(_, let key, let modifiers):
            executedVerbs.append("press_key")
            // No global key bindings in the scripted world. The one binding a
            // scene can declare is Return on the focused field (`onReturn`),
            // the conventional submit — so a type→Return plan has an
            // observable result to verify, exactly like a real form. Any other
            // key is a legible no-op success.
            let k = key.lowercased()
            let isReturn = (k == "return" || k == "enter" || k == "\r") && modifiers.isEmpty
            if isReturn, let focusedId,
                let index = cells.firstIndex(where: { $0.id == focusedId }),
                let effect = cells[index].onReturn
            {
                apply(effect, on: index)
            }
            return .ok(delta: focusDelta())
        }
    }

    public func coordinate(_ action: CUCoordinateAction) async -> CUActionResult {
        switch action {
        case .click(let x, let y, _, _, _):
            // A coordinate click lands on whatever element contains the point
            // (the loop's stale-ref fallback clicks an element's center, and a
            // `target.point` click its own spot). It ignores `clickFailures` —
            // that's the recovery the fallback exists to provide.
            if let hit = visibleCell(atX: x, y: y) {
                return applyClick(id: hit, viaCoordinate: true)
            }
            executedVerbs.append("click")
            return .ok()
        case .move(let x, let y, _):
            executedVerbs.append("hover")
            if let hit = visibleCell(atX: x, y: y) { hoveredIds.insert(hit) }
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
            apply(effect, on: index)
        }
        return .ok(delta: focusDelta())
    }

    /// Apply a scene effect (toggle → setValues → reveal) with `index` as
    /// the acting cell. Shared by click and Return-key effects.
    private func apply(_ effect: EvalCase.ComputerUseLoopExpectations.ClickEffect, on index: Int) {
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

    /// The visible cell whose frame contains the point. The most permissive
    /// tier: a coordinate targets something the model already saw.
    private func visibleCell(atX x: Double, y: Double) -> String? {
        for (index, cell) in cells.enumerated() where isRendered(cell, tier: .vision) {
            if Self.frame(index: index).contains(CGPoint(x: x, y: y)) { return cell.id }
        }
        return nil
    }

    // MARK: - Layout

    /// The scripted window, in screen points.
    static let windowFrame = CGRect(x: 0, y: 0, width: 1200, height: 800)
    /// Pixels per point of a full screenshot (a 600×400 frame).
    static let frameScale: CGFloat = 0.5

    /// Cell `index`'s frame: a vertical stack in declaration order.
    static func frame(index: Int) -> CGRect {
        CGRect(x: 40, y: 60 + index * 40, width: 200, height: 28)
    }

    /// Draw the cells rendered at `tier` that fall inside `region` (points)
    /// as a PNG at `scale` pixels per point.
    private func renderImage(tier: CaptureTier, region: CGRect, scale: CGFloat) -> CUImage? {
        let width = max(1, Int((region.width * scale).rounded()))
        let height = max(1, Int((region.height * scale).rounded()))
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Top-left origin in screen points.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -region.minX, y: -region.minY)
        let font = CTFontCreateWithName("Helvetica" as CFString, 13, nil)
        for (index, cell) in cells.enumerated() where isRendered(cell, tier: tier) {
            let rect = Self.frame(index: index)
            context.setFillColor(CGColor(red: 0.93, green: 0.94, blue: 0.96, alpha: 1))
            context.fill(rect)
            context.setStrokeColor(CGColor(red: 0.55, green: 0.57, blue: 0.62, alpha: 1))
            context.setLineWidth(1)
            context.stroke(rect)
            let text = [cell.label, cell.value].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
            guard !text.isEmpty else { continue }
            let attributed = NSAttributedString(
                string: text,
                attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                        CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1),
                ]
            )
            let line = CTLineCreateWithAttributedString(attributed)
            context.saveGState()
            context.translateBy(x: rect.minX + 6, y: rect.midY + 4.5)
            context.scaleBy(x: 1, y: -1)
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
        }
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return CUImage(
            base64: (data as Data).base64EncodedString(),
            mimeType: "image/png",
            width: width,
            height: height,
            region: CUScreenRegion(x: region.minX, y: region.minY, w: region.width, h: region.height)
        )
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
                    x: Int(Self.frame(index: index).minX),
                    y: Int(Self.frame(index: index).minY),
                    w: Int(Self.frame(index: index).width),
                    h: Int(Self.frame(index: index).height),
                    actions: []
                )
            )
        }
        // SOM / vision captures carry a rendering of the scene with its
        // screen region, so points in it map back to the cells.
        let pixels = tier == .ax ? nil : renderImage(tier: tier, region: Self.windowFrame, scale: Self.frameScale)
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
}
