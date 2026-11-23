//
//  WorkflowFlowViewer.swift
//  osaurus
//
//  A workflow's whole flow on one big canvas, over the window: zoom and
//  pan, follow a run as it goes, open map steps and nested workflows in
//  place, and find or step through them from the keyboard. A chip in the
//  bar says whether anything leaves this Mac, and selecting a step opens
//  its details on the right. Opens from the Architect's Steps, a saved
//  workflow's page, and a run's page.
//

import AppKit
import SwiftUI

struct WorkflowFlowViewer: View {
    let root: WorkflowFlowSource
    /// Puts text in the Architect chat's composer, for a draft.
    var onAsk: ((String) -> Void)?

    @ObservedObject private var drafts = WorkflowDraftStore.shared
    @ObservedObject private var runs = WorkflowRunStore.shared
    @ObservedObject private var workflows = InstalledWorkflowStore.shared
    @ObservedObject private var dialogs = DialogCoordinator.shared

    /// Nested workflows opened from the root, innermost last.
    @State private var trail: [WorkflowFlowSource] = []
    @State private var localSelection: String?
    @State private var focusMode = true
    /// Dims every step but those that send data off this Mac.
    @State private var showsReach = false
    @State private var query = ""
    @State private var matchIndex = 0
    /// Bumped by Cmd+F to put the cursor back in search.
    @State private var searchToken = 0
    @State private var zoom: CGFloat = 1
    @State private var pinch: CGFloat = 1
    @State private var pinchAnchor: (canvas: CGPoint, screen: CGPoint)?
    @State private var position = ScrollPosition(point: .zero)
    /// The part of the scroll content on screen, in zoomed points.
    @State private var visible: CGRect = .zero
    @State private var viewport: CGSize = .zero
    /// The canvas's size before zoom.
    @State private var content: CGSize = .zero
    @State private var frames: [String: CGRect] = [:]
    @State private var expandedMaps: Set<String> = []
    @State private var openEdge: WorkflowFlowEdgeTap?
    @State private var editing: EditTarget?
    @State private var needsFit = true
    /// Set when fitting turns the cards into smaller pills, so the fit runs
    /// again on the pills' size.
    @State private var refitsPills = false
    @FocusState private var canvasFocused: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct EditTarget: Identifiable {
        let draftID: UUID
        let nodeID: String
        var id: String { nodeID }
    }

    private static let zoomStep: CGFloat = 1.25
    private static let searchWidth: CGFloat = 180
    private static let zoomReadoutWidth: CGFloat = 44
    static let minimumSize = CGSize(width: 720, height: 520)
    static let idealSize = CGSize(width: 1400, height: 900)

    private var source: WorkflowFlowSource { trail.last ?? root }
    private var effectiveZoom: CGFloat { WorkflowFlowLayout.clampZoom(zoom * pinch) }

    var body: some View {
        Group {
            if let snapshot = WorkflowFlowSnapshot.resolve(source) {
                loaded(snapshot)
            } else {
                missing
            }
        }
        .background(theme.surface.canvas)
        // Start on the canvas so the arrow keys and F work, not in search.
        .defaultFocus($canvasFocused, true, priority: .userInitiated)
        .sheet(item: $editing) { target in
            if let node = drafts.draft(id: target.draftID)?.definition.node(target.nodeID) {
                WorkflowNodeEditor(draftID: target.draftID, node: node) { editing = nil }
            }
        }
        .onChange(of: source) { _, _ in
            localSelection = nil
            expandedMaps = []
            openEdge = nil
            query = ""
            showsReach = false
            needsFit = true
        }
        .onChange(of: frames) { _, _ in fitIfReady() }
    }

    // MARK: - Layout

    private func loaded(_ snapshot: WorkflowFlowSnapshot) -> some View {
        let rows = WorkflowFlowLayout.cachedRows(snapshot.definition)
        let selected = selection(snapshot)
        let matches = WorkflowFlowLayout.matches(query, in: snapshot.definition, rows: rows)
        let badges = snapshot.badges()
        let reach = WorkflowFlowStory.reach(rows.flatMap { $0 }, badges: badges)
        let node = selected.flatMap { snapshot.definition.node($0) }
        return VStack(spacing: theme.space.s0) {
            topBar(snapshot, rows: rows, matches: matches, reach: reach)
            ThemeHairlineDivider()
            HStack(spacing: theme.space.s0) {
                canvasArea(
                    snapshot, rows: rows, selected: selected, matches: matches, badges: badges, reach: reach)
                if let node {
                    ThemeHairlineDivider(axis: .vertical)
                    inspector(snapshot, node: node, badges: badges)
                        .frame(width: WorkflowFlowInspector.width)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(theme.surface.raised)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : theme.motion.standard, value: node == nil)
        }
    }

    private var missing: some View {
        VStack(spacing: theme.space.s12) {
            Image(systemName: "flowchart")
                .glyphSize(.display)
                .foregroundColor(theme.text.tertiary)
            Text(verbatim: L("This workflow isn't here anymore."))
                .textStyle(.body, weight: 600)
                .foregroundColor(theme.text.primary)
            SettingsButton(.secondary, "Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Top bar

    private func topBar(
        _ snapshot: WorkflowFlowSnapshot, rows: [[String]], matches: [String], reach: WorkflowFlowStory.Reach
    ) -> some View {
        HStack(spacing: theme.space.s12) {
            breadcrumbs(snapshot)
            if let run = snapshot.run {
                StatusChip(
                    WorkflowRunPresentation.shortStatus(run.status),
                    tone: WorkflowRunPresentation.tone(run.status), showsDot: !run.status.isTerminal,
                    help: run.isTest ? L("The latest test") : nil)
                WorkflowRunElapsed(run: run)
            }
            reachChip(reach)
            Spacer(minLength: theme.space.s8)
            search(matches) { query in WorkflowFlowLayout.matches(query, in: snapshot.definition, rows: rows) }
            SettingsIconButton(
                "scope", help: focusMode ? L("Stop Focusing on the Selected Step (F)") : L("Focus on the Selected Step (F)"),
                size: .compact, isActive: focusMode
            ) { focusMode.toggle() }
            zoomControls
            SettingsIconButton("xmark", help: trail.isEmpty ? L("Close (Esc)") : L("Back (Esc)"), size: .compact) {
                close()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, theme.space.s16)
        .padding(.vertical, theme.space.s12)
        .background(theme.surface.raised)
        .background {
            Button(L("Find a Step")) { searchToken += 1 }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: .zero, height: .zero)
                .accessibilityHidden(true)
        }
    }

    /// Whether anything leaves this Mac; when something does, clicking it
    /// picks out those steps.
    @ViewBuilder
    private func reachChip(_ reach: WorkflowFlowStory.Reach) -> some View {
        let leaves = !reach.steps.isEmpty
        let chip = StatusChip(
            reach.title, tone: showsReach ? .accent : leaves ? .warning : .success,
            icon: leaves ? "network" : "lock")
        if leaves {
            Button {
                showsReach.toggle()
            } label: {
                chip
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help(showsReach ? L("Show all the steps again") : reach.detail)
            .accessibilityAddTraits(showsReach ? [.isButton, .isSelected] : .isButton)
        } else {
            chip.help(reach.detail)
        }
    }

    private func breadcrumbs(_ snapshot: WorkflowFlowSnapshot) -> some View {
        let sources = [root] + trail
        return HStack(spacing: theme.space.s4) {
            Image(systemName: "flowchart")
                .glyphSize(.caption, weight: .semibold)
                .foregroundColor(theme.text.link)
            ForEach(Array(sources.enumerated()), id: \.offset) { index, crumb in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .glyphSize(.tiny, weight: .semibold)
                        .foregroundColor(theme.text.tertiary)
                }
                let title =
                    index == sources.count - 1
                    ? snapshot.title : (WorkflowFlowSnapshot.resolve(crumb)?.title ?? L("Workflow"))
                if index == sources.count - 1 {
                    Text(verbatim: title)
                        .textStyle(.label, weight: 600)
                        .foregroundColor(theme.text.primary)
                        .lineLimit(1)
                } else {
                    Button {
                        trail = Array(trail.prefix(index))
                    } label: {
                        Text(verbatim: title)
                            .textStyle(.label)
                            .foregroundColor(theme.text.link)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help(L("Back to \(title)"))
                }
            }
        }
        .layoutPriority(1)
    }

    private func search(_ matches: [String], matching: @escaping (String) -> [String]) -> some View {
        HStack(spacing: theme.space.s6) {
            SearchField(
                text: $query, placeholder: "Find a step", width: Self.searchWidth,
                onSubmit: {
                    let backwards = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                    step(through: matches, by: backwards ? -1 : 1)
                },
                onCancel: {
                    query = ""
                    canvasFocused = true
                },
                autofocus: searchToken > 0,
                joinsKeyLoop: false
            )
            .id(searchToken)
            .onChange(of: query) { _, query in
                matchIndex = 0
                if let first = matching(query).first { reveal(first) }
            }
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(verbatim: matches.isEmpty ? L("No steps") : L("\(matchIndex % matches.count + 1) of \(matches.count)"))
                    .textStyle(.footnote)
                    .foregroundColor(theme.text.tertiary)
                    .monospacedDigit()
                    .fixedSize()
            }
        }
    }

    private var zoomControls: some View {
        HStack(spacing: theme.space.s2) {
            SettingsIconButton("minus.magnifyingglass", help: L("Zoom Out (−)"), size: .compact) {
                setZoom(zoom / Self.zoomStep)
            }
            Text(verbatim: "\(Int((effectiveZoom * 100).rounded()))%")
                .textStyle(.footnote, weight: 500)
                .foregroundColor(theme.text.secondary)
                .monospacedDigit()
                .frame(minWidth: Self.zoomReadoutWidth)
            SettingsIconButton("plus.magnifyingglass", help: L("Zoom In (+)"), size: .compact) {
                setZoom(zoom * Self.zoomStep)
            }
            SettingsIconButton("arrow.up.left.and.down.right.magnifyingglass", help: L("Fit to Window (0)"), size: .compact) {
                fit()
            }
        }
    }

    /// ⌘= / ⌘− / ⌘0 belong to the app's text size, so the canvas zooms on the
    /// bare keys while it has focus.
    private func zoomKey(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
        switch press.characters {
        case "+", "=": setZoom(zoom * Self.zoomStep)
        case "-", "_": setZoom(zoom / Self.zoomStep)
        case "0": fit()
        default: return .ignored
        }
        return .handled
    }

    // MARK: - Canvas

    private func canvasArea(
        _ snapshot: WorkflowFlowSnapshot, rows: [[String]], selected: String?, matches: [String],
        badges: [String: [WorkflowStepBadge]], reach: WorkflowFlowStory.Reach
    ) -> some View {
        let z = effectiveZoom
        let model = canvasModel(
            snapshot, rows: rows, selected: selected, matches: matches, badges: badges, reach: reach)
        // The form the shown run waits on, as on its run page.
        let dialog = snapshot.run.flatMap { run in dialogs.presentable.first { $0.runID == run.id } }
        return ZStack(alignment: .bottomTrailing) {
            ScrollView([.horizontal, .vertical]) {
                WorkflowFlowCanvas(
                    model: model, frames: $frames, expandedMaps: $expandedMaps, openEdge: $openEdge,
                    onSelect: { select($0, snapshot) },
                    onOpenNested: { openNested($0, snapshot) }
                )
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                    content = size
                    if refitsPills {
                        refitsPills = false
                        DispatchQueue.main.async { fitPills() }
                    }
                    fitIfReady()
                }
                .scaleEffect(z, anchor: .topLeading)
                .frame(width: content.width * z, height: content.height * z, alignment: .topLeading)
                .frame(minWidth: viewport.width, minHeight: viewport.height)
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGRect.self) { $0.visibleRect } action: { _, rect in visible = rect }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                viewport = size
                fitIfReady()
            }
            .background { WorkflowCanvasGrid() }
            .simultaneousGesture(magnify)

            if !fitsInView {
                WorkflowFlowMinimap(
                    frames: frames, content: content, visible: visibleOnCanvas,
                    statuses: Dictionary(
                        (snapshot.run?.nodes ?? []).map { ($0.nodeID, $0.status) }, uniquingKeysWith: { a, _ in a }),
                    selected: selected,
                    onMove: { center(on: $0, animated: false) }
                )
                .padding(theme.space.s16)
                .transition(.opacity)
            }
        }
        .focusable()
        .focused($canvasFocused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
            move(press.key, snapshot: snapshot, rows: rows, selected: selected)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "fF"), phases: .down) { press in
            guard !press.modifiers.contains(.command) else { return .ignored }
            focusMode.toggle()
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "+=-_0"), phases: [.down, .repeat], action: zoomKey)
        .onAppear { canvasFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: L("Workflow steps")))
        // Outside the canvas's focus and key handling, so typing in the
        // form never moves, zooms, or refocuses the canvas.
        .overlay(alignment: .bottomLeading) {
            ZStack(alignment: .bottomLeading) {
                if let dialog {
                    WorkflowFlowDialogCard(dialog: dialog, maxHeight: viewport.height - theme.space.s32)
                        .padding(theme.space.s16)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(reduceMotion ? nil : theme.motion.standard, value: dialog?.id)
        }
    }

    private func canvasModel(
        _ snapshot: WorkflowFlowSnapshot, rows: [[String]], selected: String?, matches: [String],
        badges: [String: [WorkflowStepBadge]], reach: WorkflowFlowStory.Reach
    ) -> WorkflowFlowCanvas.Model {
        let def = snapshot.definition
        var model = WorkflowFlowCanvas.Model(
            definition: def, rows: rows, run: snapshot.run,
            compact: effectiveZoom < WorkflowFlowLayout.compactBelowZoom, selected: selected)
        model.highlighted = snapshot.highlighted
        model.notTaken = WorkflowFlowLayout.notTaken(def, run: snapshot.run)
        model.badges = badges
        model.thumbnails = snapshot.thumbnails
        model.given = WorkflowFlowStory.given(def, run: snapshot.run)
        model.gotten = WorkflowFlowStory.gotten(def, run: snapshot.run)
        model.endNote = WorkflowFlowStory.endNote(def, run: snapshot.run)
        for node in def.nodes where snapshot.nestedWorkflow(node) != nil {
            model.openable.insert(node.id)
        }
        let all = Set(def.nodes.map(\.id))
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            model.dimmed = all.subtracting(matches)
            model.searchHit = matches.isEmpty ? nil : matches[matchIndex % matches.count]
        } else if showsReach, !reach.steps.isEmpty {
            model.dimmed = all.subtracting(reach.steps)
        } else if focusMode, let selected {
            model.dimmed = all.subtracting(WorkflowFlowLayout.focus(on: selected, in: def))
        }
        return model
    }

    private func inspector(_ snapshot: WorkflowFlowSnapshot, node: WorkflowNode, badges: [String: [WorkflowStepBadge]])
        -> some View
    {
        WorkflowFlowInspector(
            snapshot: snapshot, node: node, badges: badges[node.id] ?? [],
            modelName: snapshot.model(for: node), canOpenNested: snapshot.nestedWorkflow(node) != nil,
            onEdit: { id in
                if let draft = snapshot.draft { editing = EditTarget(draftID: draft.id, nodeID: id) }
            },
            onAsk: onAsk.map { ask in
                { text in
                    dismiss()
                    ask(text)
                }
            },
            onOpenNested: { openNested(node.id, snapshot) },
            onSelect: { id in
                select(id, snapshot)
                reveal(id)
            },
            onClose: { select(nil, snapshot) }
        )
    }

    // MARK: - Selection

    private func selection(_ snapshot: WorkflowFlowSnapshot) -> String? {
        if case .draft = source, let draft = snapshot.draft { return draft.selectedNodeID }
        return localSelection
    }

    /// A draft's selection lives in its store, so the Architect's sidebar
    /// follows along.
    private func select(_ id: String?, _ snapshot: WorkflowFlowSnapshot) {
        openEdge = nil
        canvasFocused = true
        if case .draft = source, let draft = snapshot.draft {
            drafts.select(nodeID: id, in: draft.id)
        } else {
            localSelection = id
        }
    }

    private func move(_ key: KeyEquivalent, snapshot: WorkflowFlowSnapshot, rows: [[String]], selected: String?) {
        guard let current = selected else {
            if let first = rows.first?.first {
                select(first, snapshot)
                reveal(first)
            }
            return
        }
        let direction: WorkflowFlowLayout.Direction
        switch key {
        case .upArrow: direction = .up
        case .downArrow: direction = .down
        case .leftArrow: direction = .left
        default: direction = .right
        }
        guard let next = WorkflowFlowLayout.neighbor(of: current, direction, rows: rows, def: snapshot.definition)
        else { return }
        select(next, snapshot)
        reveal(next)
    }

    private func step(through matches: [String], by delta: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = ((matchIndex + delta) % matches.count + matches.count) % matches.count
        reveal(matches[matchIndex])
    }

    private func openNested(_ id: String, _ snapshot: WorkflowFlowSnapshot) {
        guard let node = snapshot.definition.node(id), let next = snapshot.nestedSource(node) else { return }
        trail.append(next)
    }

    private func close() {
        if trail.isEmpty {
            dismiss()
        } else {
            trail.removeLast()
        }
    }

    // MARK: - Zoom and scroll

    /// Where the zoomed canvas sits in the scroll content: centered while
    /// it is smaller than the view.
    private func inset(_ z: CGFloat) -> CGPoint {
        CGPoint(
            x: max(0, (viewport.width - content.width * z) / 2),
            y: max(0, (viewport.height - content.height * z) / 2))
    }

    private func toCanvas(_ point: CGPoint, zoom z: CGFloat) -> CGPoint {
        let o = inset(z)
        return CGPoint(x: (point.x - o.x) / z, y: (point.y - o.y) / z)
    }

    private func fromCanvas(_ point: CGPoint, zoom z: CGFloat) -> CGPoint {
        let o = inset(z)
        return CGPoint(x: o.x + point.x * z, y: o.y + point.y * z)
    }

    private var visibleOnCanvas: CGRect {
        let z = effectiveZoom
        let origin = toCanvas(visible.origin, zoom: z)
        return CGRect(origin: origin, size: CGSize(width: visible.width / z, height: visible.height / z))
    }

    private var fitsInView: Bool {
        content.width * effectiveZoom <= viewport.width + 1 && content.height * effectiveZoom <= viewport.height + 1
    }

    /// The scroll offset that puts `canvasPoint` at `screenPoint` in the view.
    private func offset(placing canvasPoint: CGPoint, at screenPoint: CGPoint, zoom z: CGFloat) -> CGPoint {
        let p = fromCanvas(canvasPoint, zoom: z)
        let maxX = max(0, content.width * z + inset(z).x * 2 - viewport.width)
        let maxY = max(0, content.height * z + inset(z).y * 2 - viewport.height)
        return CGPoint(
            x: min(maxX, max(0, p.x - screenPoint.x)),
            y: min(maxY, max(0, p.y - screenPoint.y)))
    }

    /// Zooms keeping the canvas point under `anchor` (a point in the view,
    /// the view's center by default) where it is.
    private func setZoom(_ target: CGFloat, anchor: CGPoint? = nil) {
        let screen = anchor ?? CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let canvasPoint = toCanvas(
            CGPoint(x: visible.minX + screen.x, y: visible.minY + screen.y), zoom: effectiveZoom)
        let next = WorkflowFlowLayout.clampZoom(target)
        zoom = next
        let offset = offset(placing: canvasPoint, at: screen, zoom: next)
        DispatchQueue.main.async { position.scrollTo(point: offset) }
    }

    /// Opens on full cards: a flow too long for the window starts at its
    /// first step, and the minimap and zoom show the rest.
    private func fitIfReady() {
        guard needsFit, content.width > 0, content.height > 0, viewport.width > 0, viewport.height > 0 else { return }
        needsFit = false
        DispatchQueue.main.async { fit(readable: true, animated: false) }
    }

    private func fit(readable: Bool = false, animated: Bool = true) {
        var target = WorkflowFlowLayout.fitZoom(content: content, viewport: viewport)
        if readable {
            target = max(target, WorkflowFlowLayout.compactBelowZoom)
        } else if target < WorkflowFlowLayout.compactBelowZoom, effectiveZoom >= WorkflowFlowLayout.compactBelowZoom {
            refitsPills = true
        }
        apply(zoom: target, animated: animated)
    }

    /// Fits the pills, staying below the zoom where they turn back into cards.
    private func fitPills() {
        let target = WorkflowFlowLayout.fitZoom(content: content, viewport: viewport)
        apply(zoom: min(target, WorkflowFlowLayout.compactBelowZoom - 0.01))
    }

    private func apply(zoom target: CGFloat, animated: Bool = true) {
        let scaled = CGSize(width: content.width * target, height: content.height * target)
        let offset = CGPoint(x: 0, y: max(0, (scaled.height - viewport.height) / 2))
        withAnimation(reduceMotion || !animated ? nil : theme.motion.standard) {
            zoom = target
            position.scrollTo(point: offset)
        }
    }

    private func center(on canvasPoint: CGPoint, animated: Bool) {
        let screen = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let offset = offset(placing: canvasPoint, at: screen, zoom: effectiveZoom)
        withAnimation(animated && !reduceMotion ? theme.motion.standard : nil) {
            position.scrollTo(point: offset)
        }
    }

    /// Scrolls a step into view when it is off screen.
    private func reveal(_ id: String) {
        guard let frame = frames[id] else { return }
        let z = effectiveZoom
        let origin = fromCanvas(frame.origin, zoom: z)
        let onScreen = CGRect(origin: origin, size: CGSize(width: frame.width * z, height: frame.height * z))
        guard !visible.contains(onScreen) else { return }
        center(on: CGPoint(x: frame.midX, y: frame.midY), animated: true)
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchAnchor == nil {
                    let screen = value.startLocation
                    pinchAnchor = (
                        toCanvas(CGPoint(x: visible.minX + screen.x, y: visible.minY + screen.y), zoom: effectiveZoom),
                        screen
                    )
                }
                pinch = value.magnification
                if let anchor = pinchAnchor {
                    let offset = offset(placing: anchor.canvas, at: anchor.screen, zoom: effectiveZoom)
                    DispatchQueue.main.async { position.scrollTo(point: offset) }
                }
            }
            .onEnded { value in
                zoom = WorkflowFlowLayout.clampZoom(zoom * value.magnification)
                pinch = 1
                pinchAnchor = nil
            }
    }
}

// MARK: - Waiting form

/// The form a run waits on, floating over the canvas so the full view can
/// answer it without going back to the run page. Grows with its fields up
/// to `maxHeight`, then scrolls.
struct WorkflowFlowDialogCard: View {
    let dialog: PendingDialog
    let maxHeight: CGFloat

    @State private var contentHeight: CGFloat = 0
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: WorkflowFlowInspector.width, height: min(contentHeight, max(maxHeight, 0)))
        .settingsChrome(.overlay, radius: theme.radius.large)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            HStack(alignment: .firstTextBaseline, spacing: theme.space.s8) {
                Image(systemName: "text.badge.checkmark")
                    .glyphSize(.caption, weight: .semibold)
                    .foregroundStyle(theme.statusInk(.warning))
                    .accessibilityHidden(true)
                Text(verbatim: dialog.title)
                    .textStyle(.label, weight: 600)
                    .foregroundStyle(theme.text.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: theme.space.s8)
                StatusChip(L("Waiting for you"), tone: .warning, showsDot: true)
            }
            if !dialog.message.isEmpty {
                Text(verbatim: dialog.message)
                    .textStyle(.body)
                    .foregroundStyle(theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            WorkflowDialogForm(dialog: dialog).id(dialog.id)
        }
        .padding(theme.space.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Presentation

extension View {
    /// Presents the full view as a large sheet sized on its own, so closing
    /// it leaves the window's size alone.
    func workflowFlowViewerPresentation() -> some View {
        frame(
            minWidth: WorkflowFlowViewer.minimumSize.width,
            idealWidth: WorkflowFlowViewer.idealSize.width,
            maxWidth: .infinity,
            minHeight: WorkflowFlowViewer.minimumSize.height,
            idealHeight: WorkflowFlowViewer.idealSize.height,
            maxHeight: .infinity
        )
        .presentationSizing(.fitted)
    }
}

/// The button that opens the full view, the same everywhere.
struct WorkflowFlowViewerButton: View {
    let source: WorkflowFlowSource
    var onAsk: ((String) -> Void)?

    @State private var isPresented = false

    var body: some View {
        SettingsIconButton("arrow.up.left.and.arrow.down.right", help: L("Open Full View"), size: .compact) {
            isPresented = true
        }
        .sheet(isPresented: $isPresented) {
            WorkflowFlowViewer(root: source, onAsk: onAsk)
                .workflowFlowViewerPresentation()
        }
    }
}
