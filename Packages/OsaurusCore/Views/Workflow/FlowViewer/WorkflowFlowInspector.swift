//
//  WorkflowFlowInspector.swift
//  osaurus
//
//  The full view's right pane for the selected step, in plain words: what
//  it does, what went wrong and what to do about it, what it got and what
//  it made, where its data goes, and where the flow goes next. Model,
//  tokens, tools, and raw data wait under More Details. For an Architect
//  draft it also offers the actions the Steps list does.
//

import SwiftUI

struct WorkflowFlowInspector: View {
    let snapshot: WorkflowFlowSnapshot
    let node: WorkflowNode
    let badges: [WorkflowStepBadge]
    let modelName: String?
    let canOpenNested: Bool
    var onEdit: (String) -> Void
    var onAsk: ((String) -> Void)?
    var onOpenNested: () -> Void
    var onSelect: (String) -> Void
    var onClose: () -> Void

    static let width: CGFloat = 340
    private static let valueHeight: CGFloat = 240

    @State private var showsMore = false
    @Environment(\.theme) private var theme

    private var record: NodeRun? { snapshot.record(node.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(theme.space.s16)
            ThemeHairlineDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: theme.space.s24) {
                    about
                    if let record { problem(record) }
                    if let record { values(record) }
                    privacy
                    next
                    if case .workflow(let spec) = node.kind { nested(spec) }
                    more
                    if let draft = snapshot.draft {
                        DraftStepDetail(draft: draft, node: node, onEdit: onEdit, onAsk: onAsk)
                    }
                }
                .padding(theme.space.s16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: node.id) { showsMore = false }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: theme.space.s8) {
            let tint = WorkflowFlowStepCard.accent(node)
            Image(systemName: WorkflowFlowStyle.icon(node))
                .glyphSize(14, weight: .semibold)
                .foregroundColor(tint)
                .frame(width: theme.space.s32, height: theme.space.s32)
                .settingsChrome(.tinted(tint), radius: theme.radius.medium)
            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text(verbatim: node.name)
                    .textStyle(.label, weight: 600)
                    .foregroundColor(theme.text.primary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: theme.space.s4) {
                    if let status = record?.status {
                        WorkflowStepStatusIcon(status: status).glyphSize(10)
                    }
                    Text(verbatim: statusLine)
                        .textStyle(.footnote)
                        .foregroundColor(theme.text.tertiary)
                }
            }
            Spacer(minLength: 0)
            SettingsIconButton("xmark", help: L("Close"), size: .compact, action: onClose)
        }
    }

    /// "Done in 2.4 s", "Working…", "Not run yet".
    private var statusLine: String {
        guard let record else { return snapshot.run == nil ? L("Not run yet") : L("Waiting to start") }
        let took = record.durationMs.map { WorkflowRunView.duration(Double($0) / 1000) }
        switch record.status {
        case .done: return took.map { L("Done in \($0)") } ?? L("Done")
        case .pinned: return L("Reused from an earlier run")
        case .failed: return took.map { L("Failed after \($0)") } ?? L("Failed")
        case .running: return L("Working…")
        case .awaitingUser: return L("Waiting for you")
        case .pending: return L("Waiting to start")
        case .skipped: return L("Not needed this time")
        }
    }

    // MARK: - About

    @ViewBuilder
    private var about: some View {
        let text = DraftStepDetail.description(node) ?? WorkflowSummary.kind(node)
        VStack(alignment: .leading, spacing: theme.space.s8) {
            Text(verbatim: text)
                .textStyle(.body)
                .foregroundColor(theme.text.primary)
                .fixedSize(horizontal: false, vertical: true)
            if node.mode == .bypass {
                StatusChip(L("Turned off, so runs skip it"), tone: .neutral, icon: "forward")
            }
        }
    }

    // MARK: - Problem

    @ViewBuilder
    private func problem(_ record: NodeRun) -> some View {
        if let error = record.error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            section(L("What went wrong")) {
                Text(verbatim: error)
                    .textStyle(.caption)
                    .foregroundColor(theme.statusInk.error)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(theme.space.s8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .settingsChrome(.status(.error))
            }
            if let hint = record.failure?.hint, !hint.isEmpty {
                section(L("What you can do")) {
                    Text(verbatim: hint)
                        .textStyle(.caption)
                        .foregroundColor(theme.text.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Values

    @ViewBuilder
    private func values(_ record: NodeRun) -> some View {
        if let input = record.input, Self.hasContent(input) {
            section(L("What it got")) { WorkflowFlowValueView(value: input, maxHeight: Self.valueHeight) }
        }
        if let output = record.output, Self.hasContent(output) {
            section(L("What it made")) { WorkflowFlowValueView(value: output, maxHeight: Self.valueHeight) }
        }
    }

    private static func hasContent(_ value: JSONValue) -> Bool {
        switch value {
        case .null: return false
        case .object(let fields): return !fields.isEmpty
        case .array(let items): return !items.isEmpty
        case .string(let text): return !text.isEmpty
        default: return true
        }
    }

    // MARK: - Privacy

    /// The step's model badge, then what it reaches, in the badges' own words.
    private var privacy: some View {
        let marks =
            badges.filter { WorkflowFlowStory.modelKinds.contains($0.kind) }
            + badges.filter { WorkflowFlowStory.privacyKinds.contains($0.kind) }
        return section(L("Where your data goes")) {
            if marks.isEmpty {
                mark("lock", theme.statusInk.success, L("Stays on this Mac"), detail: nil)
            } else {
                ForEach(marks) { badge in
                    mark(badge.systemImage, color(badge.tone), badge.label, detail: badge.detail)
                }
            }
        }
    }

    private func color(_ tone: WorkflowStepBadge.Tone) -> Color {
        switch tone {
        case .risky: return theme.statusInk.error
        case .caution: return theme.statusInk.warning
        case .neutral: return theme.text.secondary
        }
    }

    private func mark(_ icon: String, _ color: Color, _ title: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.space.s8) {
            Image(systemName: icon)
                .glyphSize(11, weight: .semibold)
                .foregroundColor(color)
                .frame(width: theme.space.s16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text(verbatim: title)
                    .textStyle(.caption)
                    .foregroundColor(theme.text.primary)
                if let detail, !detail.isEmpty, detail != title {
                    Text(verbatim: detail)
                        .textStyle(.footnote)
                        .foregroundColor(theme.text.tertiary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Next

    @ViewBuilder
    private var next: some View {
        let edges = snapshot.definition.edges.filter { $0.from == node.id }
        if !edges.isEmpty {
            section(L("Then")) {
                ForEach(Array(edges.enumerated()), id: \.offset) { _, edge in
                    Button {
                        onSelect(edge.to)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: theme.space.s6) {
                            Image(systemName: "arrow.turn.down.right")
                                .glyphSize(10)
                                .foregroundColor(theme.text.tertiary)
                            Text(verbatim: Self.branch(edge, in: snapshot.definition))
                                .textStyle(.caption)
                                .foregroundColor(theme.text.link)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
            }
        }
    }

    /// "Summarize", "If status is done → Summarize", "If it fails → Retry".
    static func branch(_ edge: WorkflowEdge, in definition: WorkflowDefinition) -> String {
        let target = definition.node(edge.to)?.name ?? edge.to
        if let condition = edge.when { return L("If \(WorkflowSummary.condition(condition)) → \(target)") }
        switch edge.on {
        case .success: return target
        case .error: return L("If it fails → \(target)")
        case .always: return L("Always → \(target)")
        }
    }

    // MARK: - Nested

    private func nested(_ spec: SubworkflowSpec) -> some View {
        section(L("Runs the workflow")) {
            HStack(spacing: theme.space.s8) {
                Text(verbatim: spec.workflow)
                    .textStyle(.caption, weight: 600)
                    .foregroundColor(theme.text.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                SettingsButton(
                    .secondary, "Open", size: .compact,
                    help: canOpenNested ? L("Show this workflow's steps") : L("This Mac doesn't have this workflow.")
                ) { onOpenNested() }
                .disabled(!canOpenNested)
            }
        }
    }

    // MARK: - More details

    @ViewBuilder
    private var more: some View {
        let facts = facts
        let calls = record?.toolCallRecords ?? []
        let others = badges.filter {
            !WorkflowFlowStory.modelKinds.contains($0.kind) && !WorkflowFlowStory.privacyKinds.contains($0.kind)
        }
        VStack(alignment: .leading, spacing: theme.space.s8) {
            Button {
                showsMore.toggle()
            } label: {
                HStack(spacing: theme.space.s4) {
                    Image(systemName: showsMore ? "chevron.down" : "chevron.right")
                        .glyphSize(9, weight: .semibold)
                    Text(verbatim: L("More Details"))
                        .textStyle(.footnote, weight: 500)
                }
                .foregroundColor(theme.text.tertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            if showsMore {
                ForEach(Array(facts.enumerated()), id: \.offset) { _, row in fact(row.0, row.1) }
                if !others.isEmpty { WorkflowStepBadgesView(badges: others) }
                if !calls.isEmpty {
                    label(L("Tools it used"))
                    ForEach(Array(calls.enumerated()), id: \.offset) { _, call in
                        HStack(spacing: theme.space.s6) {
                            Image(systemName: call.isError ? "xmark.circle" : "wrench.and.screwdriver")
                                .glyphSize(10)
                                .foregroundColor(call.isError ? theme.statusInk.error : theme.text.tertiary)
                            Text(verbatim: call.name)
                                .textStyle(.code)
                                .foregroundColor(theme.text.primary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if let ms = call.durationMs {
                                Text(verbatim: WorkflowRunView.duration(Double(ms) / 1000))
                                    .textStyle(.footnote)
                                    .foregroundColor(theme.text.tertiary)
                            }
                        }
                    }
                }
            }
        }
    }

    private var facts: [(String, String)] {
        var out: [(String, String)] = [(L("Kind"), WorkflowSummary.kind(node))]
        if let model = record?.model, !model.isEmpty {
            out.append((L("Model"), WorkflowModelChoices.runsOn(model)))
        } else if let modelName {
            out.append((L("Model"), modelName))
        }
        if let record {
            if record.attempts > 1 { out.append((L("Attempts"), "\(record.attempts)")) }
            let input = record.inputTokens ?? 0
            let output = record.outputTokens ?? 0
            if input + output > 0 {
                out.append(
                    (L("Tokens"), L("\(WorkflowStepRisk.compact(input)) in · \(WorkflowStepRisk.compact(output)) out")))
            }
        }
        out.append((L("Step ID"), node.id))
        return out
    }

    // MARK: - Pieces

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            label(title)
            content()
        }
    }

    private func label(_ text: String) -> some View {
        Text(verbatim: text)
            .textStyle(.footnote, weight: 500)
            .foregroundColor(theme.text.tertiary)
    }

    private func fact(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.space.s8) {
            Text(verbatim: title)
                .textStyle(.caption)
                .foregroundColor(theme.text.tertiary)
            Spacer(minLength: theme.space.s8)
            Text(verbatim: value)
                .textStyle(.caption)
                .foregroundColor(theme.text.primary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
