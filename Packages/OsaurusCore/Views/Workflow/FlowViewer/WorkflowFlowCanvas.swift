//
//  WorkflowFlowCanvas.swift
//  osaurus
//
//  The full view's graph, left to right: what you give, a column per stage
//  with steps stacked where they run in parallel, then what you get. Lines
//  run from one step's out port to the next one's in port, and once a step
//  has run a chip on its line says what it made. While a run is going the
//  lines into working steps move, working steps pulse, finished ones settle
//  with a check, and branches it passed by fade. Zoomed out, steps are pills.
//

import AppKit
import SwiftUI

/// A line the person clicked, and where on the canvas.
struct WorkflowFlowEdgeTap: Equatable, Identifiable {
    let index: Int
    let point: CGPoint
    var id: Int { index }
}

struct WorkflowFlowCanvas: View {
    /// Everything the canvas draws, worked out by the viewer.
    struct Model {
        var definition: WorkflowDefinition
        var rows: [[String]]
        var run: WorkflowRun?
        var compact: Bool
        var selected: String?
        var highlighted: Set<String> = []
        /// Out of focus or not matching the search.
        var dimmed: Set<String> = []
        var notTaken: Set<String> = []
        var searchHit: String?
        var badges: [String: [WorkflowStepBadge]] = [:]
        var thumbnails: [String: String] = [:]
        /// `workflow` steps whose workflow this Mac has.
        var openable: Set<String> = []
        var given: [WorkflowFlowStory.Entry] = []
        var gotten: [WorkflowFlowStory.Entry] = []
        var endNote: String?
    }

    static let space = "workflowFlowCanvas"
    /// Frame keys for the cards before the first step and after the last.
    static let giveID = "workflowFlow.give"
    static let getID = "workflowFlow.get"
    /// Room between columns for the lines and the chips on them.
    static let stageGap: CGFloat = 120
    static let compactStageGap: CGFloat = 64

    let model: Model
    @Binding var frames: [String: CGRect]
    @Binding var expandedMaps: Set<String>
    @Binding var openEdge: WorkflowFlowEdgeTap?
    var onSelect: (String?) -> Void
    var onOpenNested: (String) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Off for the first layout: the canvas is intrinsically sized, so a
    /// spring there resizes the sheet while it is still appearing.
    @State private var animatesRows = false

    var body: some View {
        let parents = WorkflowFlowLayout.parentMap(model.definition)
        let children = WorkflowFlowLayout.childMap(model.definition)
        let labelLift = theme.space.s12
        HStack(alignment: .center, spacing: model.compact ? Self.compactStageGap : Self.stageGap) {
            bookend(.give)
            ForEach(Array(model.rows.enumerated()), id: \.offset) { _, stage in
                VStack(alignment: .leading, spacing: model.compact ? theme.space.s12 : theme.space.s16) {
                    ForEach(stage, id: \.self) { id in
                        if let node = model.definition.node(id) { card(node) }
                    }
                }
                .overlay(alignment: .top) {
                    parallelLabel(stage.count)
                        .alignmentGuide(.top) { $0[.bottom] + labelLift }
                }
            }
            bookend(.get)
        }
        .fixedSize()
        .padding(theme.space.s64)
        .onPreferenceChange(WorkflowFlowFramesKey.self) { frames = $0 }
        .background { lineLayer(parents: parents, children: children) }
        .coordinateSpace(name: Self.space)
        .animation(reduceMotion || !animatesRows ? nil : theme.motion.springAnimation, value: model.rows)
        .onAppear { DispatchQueue.main.async { animatesRows = true } }
    }

    // MARK: - Stages

    /// Over a column whose steps run side by side.
    @ViewBuilder
    private func parallelLabel(_ count: Int) -> some View {
        if count > 1 {
            HStack(spacing: theme.space.s4) {
                Image(systemName: "arrow.triangle.branch")
                    .glyphSize(.micro, weight: .semibold)
                Text(verbatim: L("These \(count) run at the same time"))
                    .textStyle(.footnote, weight: 500)
                    .lineLimit(1)
            }
            .foregroundStyle(theme.text.tertiary)
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: L("\(count) steps run at the same time")))
        }
    }

    private func card(_ node: WorkflowNode) -> some View {
        WorkflowFlowStepCard(
            node: node,
            record: model.run?.node(node.id),
            compact: model.compact,
            isSelected: model.selected == node.id,
            isHighlighted: model.highlighted.contains(node.id),
            isSearchHit: model.searchHit == node.id,
            isNotTaken: model.notTaken.contains(node.id),
            isDimmed: model.dimmed.contains(node.id),
            badges: model.badges[node.id] ?? [],
            thumbnail: model.thumbnails[node.id],
            canOpenNested: model.openable.contains(node.id),
            isMapOpen: Binding(
                get: { expandedMaps.contains(node.id) },
                set: { open in
                    if open { expandedMaps.insert(node.id) } else { expandedMaps.remove(node.id) }
                }),
            onSelect: { onSelect(model.selected == node.id ? nil : node.id) },
            onOpenNested: { onOpenNested(node.id) }
        )
        .background(framed(node.id))
    }

    private func bookend(_ side: WorkflowFlowBookend.Side) -> some View {
        WorkflowFlowBookend(
            side: side,
            entries: side == .give ? model.given : model.gotten,
            note: side == .give ? nil : model.endNote,
            filled: model.run != nil,
            compact: model.compact
        )
        .background(framed(side == .give ? Self.giveID : Self.getID))
    }

    private func framed(_ id: String) -> some View {
        GeometryReader { geo in
            Color.clear.preference(key: WorkflowFlowFramesKey.self, value: [id: geo.frame(in: .named(Self.space))])
        }
    }

    // MARK: - Lines

    private var isAnimating: Bool {
        guard !reduceMotion, let run = model.run, !run.status.isTerminal else { return false }
        return run.nodes.contains { $0.status == .running || $0.status == .awaitingUser }
    }

    /// The steps nothing leads into, and those that lead nowhere.
    private func ends(parents: [String: [String]], children: [String: [String]]) -> (first: [String], last: [String])
    {
        let ids = model.rows.flatMap { $0 }
        return (ids.filter { parents[$0] == nil }, ids.filter { children[$0] == nil })
    }

    private func lineLayer(parents: [String: [String]], children: [String: [String]]) -> some View {
        let ends = ends(parents: parents, children: children)
        return ZStack(alignment: .topLeading) {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isAnimating)) { context in
                Canvas { graphics, _ in
                    draw(in: graphics, ends: ends, time: context.date.timeIntervalSinceReferenceDate)
                }
            }
            if !model.compact {
                ForEach(Array(model.definition.edges.enumerated()), id: \.offset) { _, edge in
                    if let condition = edge.when, let to = frames[edge.to], frames[edge.from] != nil {
                        conditionLabel(condition)
                            .opacity(lineOpacity(edge.from, edge.to))
                            .frame(width: theme.space.s0, height: theme.space.s0, alignment: .topTrailing)
                            .position(x: to.minX - Self.portInset - theme.space.s6, y: to.midY + theme.space.s4)
                    }
                }
                ForEach(model.rows.flatMap { $0 }, id: \.self) { id in
                    if let frame = frames[id] { dataChip(id, frame: frame) }
                }
            }
            Color.clear
                .frame(width: theme.space.s2, height: theme.space.s2)
                .popover(item: $openEdge, arrowEdge: .bottom) { tap in
                    WorkflowFlowEdgeDetail(definition: model.definition, run: model.run, index: tap.index)
                }
                .position(openEdge?.point ?? .zero)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .named(Self.space)) { location in
            if let hit = WorkflowFlowLayout.hitEdge(
                at: location, edges: model.definition.edges, frames: frames, inset: Self.portInset)
            {
                openEdge = WorkflowFlowEdgeTap(index: hit, point: location)
            } else {
                onSelect(nil)
            }
        }
    }

    private static let chipWidth: CGFloat = 100
    private static let labelWidth: CGFloat = 96
    /// Lines meet a step at the outer edge of its port.
    private static let portInset = WorkflowFlowStepCard.portSize / 2

    private func conditionLabel(_ condition: WorkflowCondition) -> some View {
        Text(verbatim: L("If \(WorkflowSummary.condition(condition))"))
            .textStyle(.micro, weight: 500)
            .foregroundColor(theme.text.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: Self.labelWidth)
            .fixedSize()
            .padding(.horizontal, theme.space.s6)
            .padding(.vertical, theme.space.s2)
            .settingsChrome(.subtle)
            .help(L("Only if \(WorkflowSummary.condition(condition))"))
    }

    /// What a finished step made, sitting on its line just past its out port.
    @ViewBuilder
    private func dataChip(_ id: String, frame: CGRect) -> some View {
        let record = model.run?.node(id)
        let finished = record?.status == .done || record?.status == .pinned
        let thumbnail = model.thumbnails[id]
        if finished, let peek = thumbnail == nil ? WorkflowFlowStory.peek(record?.output) : "" {
            Button {
                onSelect(id)
            } label: {
                Group {
                    if let thumbnail {
                        WorkflowMediaThumbnail(path: thumbnail, side: theme.space.s32)
                    } else {
                        Text(verbatim: peek)
                            .textStyle(.micro, weight: 500)
                            .foregroundColor(theme.text.primary)
                            .lineLimit(1)
                            .frame(maxWidth: Self.chipWidth, alignment: .leading)
                            .fixedSize()
                            .padding(.horizontal, theme.space.s6)
                            .padding(.vertical, theme.space.s2)
                            .settingsChrome(.subtle)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(L("What this step made. Click to see all of it."))
            .opacity(model.dimmed.contains(id) ? 0.15 : 1)
            .frame(width: theme.space.s0, height: theme.space.s0, alignment: .bottomLeading)
            .position(x: frame.maxX + Self.portInset + theme.space.s6, y: frame.midY - theme.space.s4)
            .transition(.opacity)
        }
    }

    private func lineOpacity(_ from: String, _ to: String) -> Double {
        if model.dimmed.contains(from) || model.dimmed.contains(to) { return 0.15 }
        if model.notTaken.contains(from) || model.notTaken.contains(to) { return 0.25 }
        return 1
    }

    private func draw(in graphics: GraphicsContext, ends: (first: [String], last: [String]), time: TimeInterval) {
        let (info, success, warning) = (theme.statusInk(.info), theme.statusInk(.success), theme.statusInk(.warning))
        let types = WorkflowFlowStyle.edgeTypes(model.definition)
        let dashPhase = -CGFloat((time * 24).truncatingRemainder(dividingBy: 11))

        func status(_ id: String) -> NodeRunStatus? { model.run?.node(id)?.status }
        func isDone(_ s: NodeRunStatus?) -> Bool { s == .done || s == .pinned }
        func isWorking(_ s: NodeRunStatus?) -> Bool { s == .running || s == .awaitingUser }

        func stroke(
            _ from: CGRect, _ to: CGRect, color: Color, active: Bool, dashed: Bool, bold: Bool, opacity: Double
        ) {
            let line = WorkflowFlowLayout.curve(from: from, to: to, inset: Self.portInset)
            var path = Path()
            path.move(to: line.start)
            path.addCurve(to: line.end, control1: line.control1, control2: line.control2)
            var dash: [CGFloat] = dashed ? [3, 3] : []
            var phase: CGFloat = 0
            if active, !reduceMotion {
                dash = [6, 5]
                phase = dashPhase
            }
            var layer = graphics
            layer.opacity = opacity
            layer.stroke(
                path, with: .color(color),
                style: StrokeStyle(
                    lineWidth: theme.stroke.default * (active || bold ? 2 : 1.5), lineCap: .round, dash: dash,
                    dashPhase: phase))
        }

        for edge in model.definition.edges {
            guard let from = frames[edge.from], let to = frames[edge.to] else { continue }
            let fromStatus = status(edge.from), toStatus = status(edge.to)
            let active = isDone(fromStatus) && isWorking(toStatus)
            let passed = isDone(fromStatus) && toStatus != nil && toStatus != .pending && toStatus != .skipped
            let type = types["\(edge.from)→\(edge.to)"]
            stroke(
                from, to, color: active ? info : passed ? success : edgeColor(type), active: active,
                dashed: edge.when != nil, bold: type != nil, opacity: lineOpacity(edge.from, edge.to))
        }

        if let give = frames[Self.giveID] {
            for id in ends.first {
                guard let to = frames[id] else { continue }
                let s = status(id)
                let color = isWorking(s) ? info : s != nil && s != .pending ? success : theme.text.tertiary
                stroke(
                    give, to, color: color, active: isWorking(s), dashed: false, bold: false,
                    opacity: lineOpacity(id, id))
            }
        }
        if let get = frames[Self.getID] {
            let finished = model.run?.status == .completed
            for id in ends.last {
                guard let from = frames[id] else { continue }
                let color = finished && isDone(status(id)) ? success : theme.text.tertiary
                stroke(
                    from, get, color: color, active: false, dashed: false, bold: false, opacity: lineOpacity(id, id))
            }
        }

        guard let run = model.run else { return }
        for record in run.nodes where isWorking(record.status) {
            guard let frame = frames[record.nodeID] else { continue }
            let wave = reduceMotion ? 0.5 : (sin(time * 2 * .pi / 1.6) + 1) / 2
            var layer = graphics
            layer.opacity = 0.2 + 0.55 * wave
            let outset = theme.space.s4
            let ring = Path(
                roundedRect: frame.insetBy(dx: -outset, dy: -outset), cornerRadius: theme.radius.large + outset,
                style: .continuous)
            layer.stroke(
                ring, with: .color(record.status == .awaitingUser ? warning : info),
                lineWidth: theme.stroke.focus)
        }
    }

    private func edgeColor(_ type: BindingTypeResolver.ValueType?) -> Color {
        switch type {
        case .image?: return theme.text.link
        case .video?: return theme.status.warning.foreground
        default: return theme.text.tertiary
        }
    }
}

struct WorkflowFlowFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - You give, you get

/// The cards at either end of the flow: what the person fills in, and what
/// the workflow hands back. Before a run they name the fields; after one
/// they show the values.
struct WorkflowFlowBookend: View {
    enum Side { case give, get }

    let side: Side
    let entries: [WorkflowFlowStory.Entry]
    let note: String?
    /// A run is shown, so entries carry values.
    let filled: Bool
    let compact: Bool

    static let width: CGFloat = 200
    private static let shownLimit = 6

    @Environment(\.theme) private var theme

    private var title: String { side == .give ? L("You give") : L("You get") }
    private var icon: String { side == .give ? "square.and.pencil" : "gift" }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.radius.large, style: .continuous)
        VStack(alignment: .leading, spacing: theme.space.s8) {
            HStack(spacing: theme.space.s8) {
                Image(systemName: icon)
                    .glyphSize(compact ? .footnote : .label, weight: .semibold)
                    .foregroundColor(theme.text.secondary)
                    .frame(width: compact ? theme.space.s24 : theme.space.s32, height: compact ? theme.space.s24 : theme.space.s32)
                    .settingsChrome(.inset, radius: compact ? theme.radius.small : theme.radius.medium)
                Text(verbatim: title)
                    .textStyle(compact ? .caption : .label, weight: 600)
                    .foregroundColor(theme.text.primary)
            }
            if !compact { details }
        }
        .padding(compact ? theme.space.s8 : theme.space.s12)
        .frame(width: compact ? WorkflowFlowStepCard.compactWidth : Self.width, alignment: .leading)
        .background(shape.fill(theme.surface.subtle))
        .overlay(shape.strokeBorder(theme.border.default, lineWidth: theme.stroke.default))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var details: some View {
        if entries.isEmpty {
            Text(verbatim: note ?? (side == .give ? L("Nothing to fill in") : L("Whatever its last step makes")))
                .textStyle(.caption)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else if filled, entries.contains(where: { !$0.text.isEmpty }) {
            VStack(alignment: .leading, spacing: theme.space.s6) {
                ForEach(entries.prefix(Self.shownLimit)) { entry in
                    VStack(alignment: .leading, spacing: theme.space.s0) {
                        if !entry.label.isEmpty {
                            Text(verbatim: entry.label)
                                .textStyle(.micro, weight: 500)
                                .foregroundColor(theme.text.tertiary)
                        }
                        Text(verbatim: entry.text)
                            .textStyle(.caption)
                            .foregroundColor(theme.text.primary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                more
            }
            noteText
        } else {
            FlowLayout(spacing: theme.space.s4) {
                ForEach(entries.prefix(Self.shownLimit)) { entry in StatusChip(entry.label) }
            }
            more
            noteText
        }
    }

    @ViewBuilder
    private var more: some View {
        if entries.count > Self.shownLimit {
            Text(verbatim: L("and \(entries.count - Self.shownLimit) more"))
                .textStyle(.micro)
                .foregroundColor(theme.text.tertiary)
        }
    }

    @ViewBuilder
    private var noteText: some View {
        if let note {
            Text(verbatim: note)
                .textStyle(.caption)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Step card

/// One step on the canvas: a pill when zoomed out, else a card that says
/// in a line what the step does (or what went wrong), how its run is going,
/// and what it can reach. Lines enter at the port on its left and leave
/// from the port on its right.
struct WorkflowFlowStepCard: View {
    let node: WorkflowNode
    let record: NodeRun?
    let compact: Bool
    let isSelected: Bool
    let isHighlighted: Bool
    let isSearchHit: Bool
    let isNotTaken: Bool
    let isDimmed: Bool
    let badges: [WorkflowStepBadge]
    let thumbnail: String?
    let canOpenNested: Bool
    @Binding var isMapOpen: Bool
    var onSelect: () -> Void
    var onOpenNested: () -> Void

    static let width: CGFloat = 228
    static let compactWidth: CGFloat = 168
    static let previewHeight: CGFloat = 120
    static let portSize: CGFloat = 10

    /// The kinds of reach a card names; the rest are in the step's details.
    private static let cardKinds: Set<WorkflowStepBadge.Kind> = [
        .yourMac, .network, .cloudModel, .secrets, .files, .shell, .browser, .mac,
    ]

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isBypassed: Bool { node.mode == .bypass }
    private var isPlaceholder: Bool { node.kind == nil }
    private var status: NodeRunStatus? { record?.status }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.radius.large, style: .continuous)
        tappable(
            Group {
                if compact { pill } else { full }
            }
            .frame(width: compact ? Self.compactWidth : Self.width, alignment: .leading)
            .background(shape.fill(fillColor).themeElevation(theme.elevation.raised))
            .background(alignment: .topLeading) {
                if isMap, !compact { stack(shape) }
            }
            .overlay {
                shape.strokeBorder(
                    borderColor,
                    style: StrokeStyle(
                        lineWidth: isSelected || isSearchHit ? theme.stroke.focus : theme.stroke.default,
                        dash: isPlaceholder || isBypassed ? [4, 3] : []))
            }
            .contentShape(shape)
            .overlay(alignment: .leading) { port(inPortColor).offset(x: -Self.portSize / 2) }
            .overlay(alignment: .trailing) { port(outPortColor).offset(x: Self.portSize / 2) }
        )
        .opacity(isDimmed ? 0.25 : isNotTaken ? 0.4 : isBypassed ? 0.6 : 1)
        .animation(reduceMotion ? nil : theme.motion.springAnimation, value: status)
        .animation(reduceMotion ? nil : theme.motion.quick, value: isDimmed)
        .pointingHandCursor()
        .help(line.text)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: accessibilityText))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onSelect() }
    }

    @ViewBuilder
    private func tappable<V: View>(_ view: V) -> some View {
        if canOpenNested {
            view.gesture(
                TapGesture(count: 2).onEnded { onOpenNested() }
                    .exclusively(before: TapGesture().onEnded { onSelect() }))
        } else {
            view.onTapGesture(perform: onSelect)
        }
    }

    private var accessibilityText: String {
        var parts = [node.name, line.text]
        if let status { parts.append(Self.statusWord(status)) }
        return parts.joined(separator: ", ")
    }

    static func statusWord(_ status: NodeRunStatus) -> String {
        switch status {
        case .pending: return L("waiting to start")
        case .running: return L("working")
        case .awaitingUser: return L("waiting for you")
        case .done: return L("done")
        case .pinned: return L("reused from an earlier run")
        case .failed: return L("failed")
        case .skipped: return L("skipped")
        }
    }

    /// What the card says under the name: what the step does, or why it
    /// didn't.
    var line: (text: String, isError: Bool) {
        if isBypassed { return (L("Turned off, so runs skip it"), false) }
        if status == .failed, let error = record?.error?.trimmingCharacters(in: .whitespacesAndNewlines),
            !error.isEmpty
        {
            return (error, true)
        }
        if status == .skipped || isNotTaken { return (L("Not needed this time"), false) }
        if let intent = node.intent?.trimmingCharacters(in: .whitespacesAndNewlines), !intent.isEmpty {
            return (intent, false)
        }
        if case .map(let spec) = node.kind { return (WorkflowSummary.kind(spec.body(parentID: node.id)), false) }
        return (WorkflowSummary.kind(node), false)
    }

    // MARK: Pill

    private var pill: some View {
        HStack(spacing: theme.space.s8) {
            glyph(side: theme.space.s24)
            Text(verbatim: node.name)
                .textStyle(.caption, weight: 600)
                .foregroundColor(isBypassed ? theme.text.tertiary : theme.text.primary)
                .strikethrough(isBypassed)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let status { WorkflowStepStatusIcon(status: status).glyphSize(.micro).accessibilityHidden(true) }
        }
        .padding(.horizontal, theme.space.s8)
        .padding(.vertical, theme.space.s6)
    }

    // MARK: Card

    private var full: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            HStack(alignment: .top, spacing: theme.space.s8) {
                glyph(side: theme.space.s32)
                VStack(alignment: .leading, spacing: theme.space.s2) {
                    Text(verbatim: node.name)
                        .textStyle(.label, weight: 600)
                        .foregroundColor(isBypassed ? theme.text.tertiary : theme.text.primary)
                        .strikethrough(isBypassed)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    let line = line
                    Text(verbatim: line.text)
                        .textStyle(.caption)
                        .foregroundColor(line.isError ? theme.statusInk(.error) : theme.text.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if let status {
                    WorkflowStepStatusIcon(status: status)
                        .glyphSize(.caption)
                        .id(status)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityHidden(true)
                }
            }
            live
            if case .map(let spec) = node.kind { mapSection(spec) }
            if case .workflow(let spec) = node.kind { nestedRow(spec) }
            footer
        }
        .padding(theme.space.s12)
    }

    /// What the step reaches, as small icons, and how long it took.
    @ViewBuilder
    private var footer: some View {
        let reach = badges.filter { Self.cardKinds.contains($0.kind) && $0.tone != .neutral }
        let took = record.flatMap { record -> String? in
            guard record.status != .running, let ms = record.durationMs else { return nil }
            return WorkflowRunView.duration(Double(ms) / 1000)
        }
        if !reach.isEmpty || took != nil {
            HStack(spacing: theme.space.s6) {
                ForEach(reach) { badge in
                    Image(systemName: badge.systemImage)
                        .glyphSize(.micro, weight: .semibold)
                        .foregroundColor(badge.tone == .risky ? theme.statusInk(.error) : theme.statusInk(.warning))
                        .help(badge.detail.map { "\(badge.label): \($0)" } ?? badge.label)
                        .accessibilityLabel(Text(verbatim: badge.label))
                }
                Spacer(minLength: 0)
                if let took {
                    Text(verbatim: took)
                        .textStyle(.micro, weight: 500)
                        .foregroundColor(theme.text.tertiary)
                        .monospacedDigit()
                }
            }
        }
    }

    @ViewBuilder
    private func glyph(side: CGFloat) -> some View {
        if let preview = livePreview, compact {
            Image(nsImage: preview).resizable().scaledToFill()
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: theme.radius.small, style: .continuous))
        } else if let thumbnail, livePreview == nil {
            WorkflowMediaThumbnail(path: thumbnail, side: side)
        } else {
            let tint = isPlaceholder || isBypassed ? theme.text.tertiary : Self.accent(node, theme: theme)
            Image(systemName: WorkflowFlowStyle.icon(node))
                .glyphSize(compact ? .footnote : .body, weight: .semibold)
                .foregroundColor(tint)
                .frame(width: side, height: side)
                .settingsChrome(.tinted(tint), radius: compact ? theme.radius.small : theme.radius.medium)
                .accessibilityHidden(true)
        }
    }

    /// A calm tint per family of step, so the kinds read at a glance: AI,
    /// code, the web and tools, fan-out, other workflows, people, media.
    static func accent(_ node: WorkflowNode, theme: any ThemeProtocol) -> Color {
        let ink: DataInk
        switch node.kind {
        case .inference?, .agent?: ink = .purple
        case .code?, .state?: ink = .blue
        case .http?, .tool?: ink = .orange
        case .map?: ink = .teal
        case .workflow?: ink = .pink
        case .dialog?, .reply?: ink = .indigo
        case .media?: ink = .cyan
        case .wait?, nil: ink = .gray
        }
        return theme.dataInk(ink)
    }

    private func port(_ color: Color) -> some View {
        Circle()
            .fill(theme.surface.raised)
            .overlay(Circle().strokeBorder(color, lineWidth: theme.stroke.focus))
            .frame(width: Self.portSize, height: Self.portSize)
            .accessibilityHidden(true)
    }

    // MARK: Live

    private var livePreview: NSImage? {
        guard status == .running, let data = record?.progress?.previewPNG else { return nil }
        return NSImage(data: data)
    }

    /// The last two lines a model step has streamed so far.
    private var ticker: String? {
        guard status == .running, let streamed = record?.streamed else { return nil }
        let lines = streamed.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.suffix(2).joined(separator: "\n")
    }

    @ViewBuilder
    private var live: some View {
        if status == .awaitingUser {
            StatusChip(L("Waiting for you"), tone: .warning, showsDot: true)
        }
        if let preview = livePreview {
            Image(nsImage: preview)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: Self.previewHeight)
                .clipShape(RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous))
                .transition(.opacity)
        }
        if status == .running, let progress = record?.progress, !isMap {
            VStack(alignment: .leading, spacing: theme.space.s4) {
                if let fraction = progress.fraction {
                    SettingsProgressBar(value: fraction)
                }
                if !progress.detail.isEmpty {
                    Text(verbatim: progress.detail)
                        .textStyle(.footnote)
                        .foregroundColor(theme.text.secondary)
                        .lineLimit(1)
                }
            }
        }
        if let ticker {
            Text(verbatim: ticker)
                .textStyle(.footnote)
                .foregroundColor(theme.text.secondary)
                .lineLimit(2)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(theme.space.s6)
                .settingsChrome(.inset)
                .accessibilityLabel(Text(verbatim: L("Writing: \(ticker)")))
        }
    }

    // MARK: Fan-out

    private var isMap: Bool {
        if case .map = node.kind { return true }
        return false
    }

    private func stack(_ shape: RoundedRectangle) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach([theme.space.s8, theme.space.s4], id: \.self) { offset in
                shape.fill(stackFill)
                    .overlay(shape.strokeBorder(theme.border.default, lineWidth: theme.stroke.default))
                    .offset(x: offset, y: offset)
            }
        }
        .accessibilityHidden(true)
    }

    private func mapSection(_ spec: MapSpec) -> some View {
        let items = WorkflowFlowStory.mapItems(record)
        let body = spec.body(parentID: node.id)
        let concurrency = spec.effectiveConcurrency(body: body)
        return VStack(alignment: .leading, spacing: theme.space.s6) {
            HStack(spacing: theme.space.s6) {
                Image(systemName: "square.stack.3d.down.right")
                    .glyphSize(.micro, weight: .semibold)
                Text(
                    verbatim: concurrency == 1
                        ? L("Repeats for each item, one at a time")
                        : L("Repeats for each item, \(concurrency) at a time")
                )
                .textStyle(.footnote, weight: 500)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if items != nil {
                    SettingsIconButton(
                        isMapOpen ? "chevron.up" : "chevron.down",
                        help: isMapOpen ? L("Hide Items") : L("Show Items"), size: .extraSmall
                    ) { isMapOpen.toggle() }
                }
            }
            .foregroundColor(theme.text.secondary)
            if let items {
                Text(verbatim: Self.mapSummary(items, running: record?.mapItems != nil))
                    .textStyle(.footnote)
                    .foregroundColor(theme.text.tertiary)
                if isMapOpen { WorkflowMapItemsGrid(items: items) }
            }
        }
    }

    /// "12 of 40 done · 4 working · 1 failed" while it runs, "40 items ·
    /// 1 failed" once it has.
    static func mapSummary(_ items: WorkflowFlowStory.MapItems, running: Bool) -> String {
        var parts: [String] = []
        if running {
            parts.append(L("\(items.done) of \(items.states.count) done"))
            if items.running > 0 { parts.append(L("\(items.running) working")) }
        } else {
            parts.append(items.states.count == 1 ? L("1 item") : L("\(items.states.count) items"))
        }
        if items.failed > 0 { parts.append(L("\(items.failed) failed")) }
        return parts.joined(separator: " · ")
    }

    private func nestedRow(_ spec: SubworkflowSpec) -> some View {
        HStack(spacing: theme.space.s6) {
            Image(systemName: "flowchart")
                .glyphSize(.micro, weight: .semibold)
                .foregroundColor(theme.text.secondary)
            Text(verbatim: spec.workflow)
                .textStyle(.footnote, weight: 500)
                .foregroundColor(theme.text.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            SettingsButton(
                .tertiary, "Open", size: .compact,
                help: canOpenNested ? L("Show this workflow's steps") : L("This Mac doesn't have this workflow.")
            ) { onOpenNested() }
            .disabled(!canOpenNested)
        }
    }

    // MARK: Colors

    private var fillColor: Color { isSelected ? theme.surface.selected : theme.surface.raised }
    private var stackFill: Color { theme.surface.subtle }

    /// How the step's run went, as a color: nil before it starts and when
    /// it was skipped.
    private var statusColor: Color? {
        switch status {
        case .running?: return theme.statusInk(.info)
        case .awaitingUser?: return theme.statusInk(.warning)
        case .done?, .pinned?: return theme.statusInk(.success)
        case .failed?: return theme.statusInk(.error)
        case .pending?, .skipped?, nil: return nil
        }
    }

    private var borderColor: Color {
        if isSearchHit { return theme.border.focus }
        if isSelected { return theme.action.primary.default.background }
        return statusColor ?? (isHighlighted ? theme.border.strong : theme.border.default)
    }

    /// Lit once something has come in.
    private var inPortColor: Color { statusColor ?? theme.border.strong }

    /// Lit once the step has passed something on, or failed.
    private var outPortColor: Color {
        switch status {
        case .done?, .pinned?, .failed?: return statusColor ?? theme.border.strong
        default: return theme.border.strong
        }
    }
}

// MARK: - Map items

/// A map step's items as dots, colored by how each went. Clicking one
/// shows its result or its error.
struct WorkflowMapItemsGrid: View {
    let items: WorkflowFlowStory.MapItems

    @State private var open: Int?
    @Environment(\.theme) private var theme

    private static let dot: CGFloat = 10
    private static let gap: CGFloat = 4

    var body: some View {
        let shown = min(items.states.count, WorkflowFlowStory.mapItemLimit)
        VStack(alignment: .leading, spacing: theme.space.s6) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: Self.dot, maximum: Self.dot), spacing: Self.gap)],
                alignment: .leading, spacing: Self.gap
            ) {
                ForEach(0..<shown, id: \.self) { index in
                    Button {
                        open = open == index ? nil : index
                    } label: {
                        Circle()
                            .fill(color(items.states[index]))
                            .overlay {
                                if open == index {
                                    Circle().strokeBorder(theme.border.focus, lineWidth: theme.stroke.focus)
                                }
                            }
                            .frame(width: Self.dot, height: Self.dot)
                    }
                    .buttonStyle(.plain)
                    .help(L("Item \(index + 1)"))
                    .accessibilityLabel(Text(verbatim: L("Item \(index + 1), \(word(items.states[index]))")))
                }
            }
            if items.states.count > shown {
                Text(verbatim: L("and \(items.states.count - shown) more"))
                    .textStyle(.micro)
                    .foregroundColor(theme.text.tertiary)
            }
            if let open, items.states.indices.contains(open) { detail(open) }
        }
    }

    private func detail(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s4) {
            HStack {
                Text(verbatim: L("Item \(index + 1)"))
                    .textStyle(.caption, weight: 600)
                    .foregroundColor(theme.text.primary)
                Text(verbatim: word(items.states[index]))
                    .textStyle(.caption)
                    .foregroundColor(theme.text.tertiary)
                Spacer(minLength: 0)
                SettingsIconButton("xmark", help: L("Close"), size: .extraSmall) { open = nil }
            }
            if let error = items.errors[index] {
                Text(verbatim: error)
                    .textStyle(.footnote)
                    .foregroundColor(theme.statusInk(.error))
                    .fixedSize(horizontal: false, vertical: true)
            } else if items.results.indices.contains(index) {
                WorkflowFlowValueView(value: items.results[index], maxHeight: Self.detailHeight)
            }
        }
        .padding(theme.space.s8)
        .settingsChrome(.inset)
    }

    private static let detailHeight: CGFloat = 160

    private func word(_ state: MapItemState) -> String {
        switch state {
        case .pending: return L("not started")
        case .running: return L("working")
        case .done: return L("done")
        case .failed: return L("failed")
        }
    }

    private func color(_ state: MapItemState) -> Color {
        switch state {
        case .pending: return theme.border.default
        case .running: return theme.statusInk(.info)
        case .done: return theme.statusInk(.success)
        case .failed: return theme.statusInk(.error)
        }
    }
}

// MARK: - Values

/// A step's input or output as a person reads it: text as text, a list as
/// its first few entries, an object as labelled fields. The raw data is a
/// click away.
struct WorkflowFlowValueView: View {
    let value: JSONValue
    var maxHeight: CGFloat = 280

    @State private var showsRaw = false
    @Environment(\.theme) private var theme

    private static let listLimit = 5

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            if showsRaw {
                WorkflowJSONText(text: value.prettyJSONString, maxHeight: maxHeight)
            } else {
                readable
            }
            if isStructured {
                Button(showsRaw ? L("Show as Text") : L("Show Raw Data")) { showsRaw.toggle() }
                    .buttonStyle(.link)
                    .textStyle(.footnote)
            }
        }
    }

    private var isStructured: Bool {
        switch value {
        case .array, .object: return true
        default: return false
        }
    }

    @ViewBuilder
    private var readable: some View {
        switch value {
        case .object(let fields):
            VStack(alignment: .leading, spacing: theme.space.s6) {
                ForEach(fields.keys.sorted(), id: \.self) { key in
                    VStack(alignment: .leading, spacing: theme.space.s0) {
                        Text(verbatim: WorkflowFormFields.humanized(key))
                            .textStyle(.micro, weight: 500)
                            .foregroundColor(theme.text.tertiary)
                        text(WorkflowFlowStory.peek(fields[key], limit: 400) ?? "—")
                    }
                }
            }
        case .array(let items):
            VStack(alignment: .leading, spacing: theme.space.s4) {
                Text(verbatim: items.count == 1 ? L("1 item") : L("\(items.count) items"))
                    .textStyle(.micro, weight: 500)
                    .foregroundColor(theme.text.tertiary)
                ForEach(Array(items.prefix(Self.listLimit).enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: theme.space.s6) {
                        Text(verbatim: "•").foregroundColor(theme.text.tertiary)
                        text(WorkflowSummary.preview(item, limit: 160))
                    }
                }
                if items.count > Self.listLimit {
                    Text(verbatim: L("and \(items.count - Self.listLimit) more"))
                        .textStyle(.micro)
                        .foregroundColor(theme.text.tertiary)
                }
            }
        case .string(let string):
            ScrollView {
                text(string).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: maxHeight)
            .fixedSize(horizontal: false, vertical: true)
        default:
            text(WorkflowSummary.preview(value))
        }
    }

    private func text(_ string: String) -> some View {
        Text(verbatim: string)
            .textStyle(.caption)
            .foregroundColor(theme.text.primary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Line detail

/// What went along one line in the shown run, and when the line is taken.
struct WorkflowFlowEdgeDetail: View {
    let definition: WorkflowDefinition
    let run: WorkflowRun?
    let index: Int

    @Environment(\.theme) private var theme

    private static let width: CGFloat = 340
    private static let dataHeight: CGFloat = 260

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            if definition.edges.indices.contains(index) {
                let edge = definition.edges[index]
                let from = definition.node(edge.from)?.name ?? edge.from
                let to = definition.node(edge.to)?.name ?? edge.to
                Text(verbatim: L("From \(from) to \(to)"))
                    .textStyle(.label, weight: 600)
                    .foregroundColor(theme.text.primary)
                if let condition = edge.when {
                    row(L("Only if"), WorkflowSummary.condition(condition))
                }
                if edge.on != .success { row(L("Goes on"), Self.trigger(edge.on)) }
                if let output = run?.node(edge.from)?.output {
                    Text(verbatim: L("What it passed on"))
                        .textStyle(.footnote, weight: 500)
                        .foregroundColor(theme.text.tertiary)
                    WorkflowFlowValueView(value: output, maxHeight: Self.dataHeight)
                } else {
                    Text(verbatim: run == nil ? L("Run it to see what goes along this line.") : L("Nothing has gone along this line yet."))
                        .textStyle(.caption)
                        .foregroundColor(theme.text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(theme.space.s16)
        .frame(width: Self.width, alignment: .leading)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.space.s8) {
            Text(verbatim: title)
                .textStyle(.footnote, weight: 500)
                .foregroundColor(theme.text.tertiary)
            Text(verbatim: value)
                .textStyle(.caption)
                .foregroundColor(theme.text.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func trigger(_ trigger: WorkflowEdge.Trigger) -> String {
        switch trigger {
        case .success: return L("When the step finishes")
        case .error: return L("When the step fails")
        case .always: return L("When the step ends, however it went")
        }
    }
}
