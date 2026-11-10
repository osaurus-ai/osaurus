//
//  WorkflowRunView.swift
//  osaurus
//
//  One run, step by step: each step's status, retries, and duration, its
//  progress while it works, and on expand its model, files, input,
//  output, error, logs, requests, and tool calls; the final output is
//  laid out by the workflow's output schema. The one step list of the
//  workflow tab, the Architect's tests, and a workflow's past runs.
//

import AppKit
import SwiftUI

struct WorkflowRunView: View {
    enum Header {
        /// Status, start time, duration, and the Insights link.
        case full
        /// Start time, duration, and Insights, under a title that already
        /// says the status.
        case timing
        /// None: the host shows status and `WorkflowRunTiming` itself.
        case none
    }

    let run: WorkflowRun
    var definition: WorkflowDefinition?
    /// Off where the run's result is shown beside it.
    var showsOutput = true
    var header: Header = .full
    /// Steps open when the view appears, such as the one a run failed at.
    var initiallyOpen: Set<String> = []
    /// Shown on a failed run as "Fix with the Architect". Nil where the
    /// surrounding card already offers it.
    var onFix: (() -> Void)?
    /// Shown on a failed run as "Retry from Failed Step", where it can be.
    var onRetry: (() -> Void)?

    @State private var expanded: Set<String> = []
    @State private var rawShown: Set<String> = []
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            headerRow
            if let error = run.error {
                errorCallout(error)
            } else if let fixAction {
                WorkflowFixButton(action: fixAction)
            }
            stepList
            if showsOutput, let output = run.output {
                if let fields = definition.flatMap({ WorkflowOutputLayout.fields(output, schema: $0.outputSchema) }) {
                    outputFields(fields, raw: output)
                } else {
                    jsonBlock(title: "Output", value: output)
                }
            }
        }
        .onAppear { expanded.formUnion(initiallyOpen) }
    }

    private func outputFields(_ fields: [WorkflowOutputLayout.Field], raw: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Output", bundle: .module)
                    .textStyle(.footnote, weight: 600)
                    .foregroundColor(theme.text.tertiary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(raw.prettyJSONString, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .glyphSize(10)
                        .foregroundColor(theme.text.tertiary)
                }
                .buttonStyle(.plain)
                .localizedHelp("Copy JSON")
            }
            ForEach(fields) { field in
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.label)
                        .textStyle(.caption, weight: 500)
                        .foregroundColor(theme.text.secondary)
                    Text(field.text)
                        .textStyle(field.isStructured ? .code : .bodySmall)
                        .foregroundColor(theme.text.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(theme.space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(.inset)
    }

    private var fixAction: (() -> Void)? { run.status == .failed ? onFix : nil }
    private var retryAction: (() -> Void)? { run.status == .failed ? onRetry : nil }

    @ViewBuilder
    private var headerRow: some View {
        switch header {
        case .full:
            HStack(spacing: theme.space.s8) {
                StatusChip(WorkflowRunTabView.statusText(run.status), tint: color(run.status))
                if run.isTest { StatusChip(L("Test"), tone: .neutral) }
                Spacer()
                WorkflowRunTiming(run: run)
            }
        case .timing:
            HStack(spacing: theme.space.s8) {
                Spacer(minLength: theme.space.s8)
                WorkflowRunTiming(run: run)
                    .fixedSize()
            }
        case .none:
            EmptyView()
        }
    }

    /// Why the run stopped, under the name of the step it stopped at, with
    /// the failure's hint and, where offered, Retry from Failed Step and
    /// Fix with the Architect.
    @ViewBuilder
    private func errorCallout(_ error: WorkflowRunError) -> some View {
        let step = error.nodeID.flatMap { id in definition?.node(id)?.name }
        let failed = run.status == .failed
        let icon = failed ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
        let title = step.map { L("Stopped at \($0)") } ?? WorkflowRunTabView.statusText(run.status)
        let message = [error.reason, run.primaryFailure?.hint].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let tone: ThemeStatusKind = failed ? .error : .warning
        if fixAction != nil || retryAction != nil {
            SettingsCallout(icon: icon, title: title, message: message, tone: tone) {
                if let retryAction {
                    Button(action: retryAction) {
                        Label {
                            Text("Retry from Failed Step", bundle: .module)
                        } icon: {
                            Image(systemName: "arrow.uturn.forward")
                        }
                    }
                    .buttonStyle(.settings(.secondary, size: .compact))
                    .localizedHelp("Runs the failed step and everything after it again, keeping the steps that finished.")
                }
                if let fixAction { WorkflowFixButton(action: fixAction) }
            }
            .textSelection(.enabled)
        } else {
            SettingsCallout(icon: icon, title: title, message: message, tone: tone)
                .textSelection(.enabled)
        }
    }

    /// The steps in the order they run, those not reached yet as waiting,
    /// then any the definition no longer has. Without a definition, the
    /// run's own order.
    static func rows(_ run: WorkflowRun, definition: WorkflowDefinition?) -> [NodeRun] {
        guard let definition else { return run.nodes }
        let steps = WorkflowSummary.steps(definition)
        let known = Set(steps.map(\.id))
        return steps.map { run.node($0.id) ?? NodeRun(nodeID: $0.id) }
            + run.nodes.filter { !known.contains($0.nodeID) }
    }

    static func stateText(_ status: NodeRunStatus?) -> String {
        switch status {
        case nil, .pending?: return L("waiting")
        case .running?: return L("working…")
        case .awaitingUser?: return L("waiting for you")
        case .done?, .pinned?: return L("done")
        case .skipped?: return L("skipped")
        case .failed?: return L("failed")
        }
    }

    /// "Retried ×2" on a step that took three attempts; nil on the first.
    static func retryText(_ node: NodeRun) -> String? {
        node.attempts > 1 ? L("Retried ×\(node.attempts - 1)") : nil
    }

    /// The files a step made, that can be shown.
    private func media(_ node: NodeRun) -> [WorkflowArtifact] {
        WorkflowMediaGalleryModel.items(run.artifacts.filter { $0.nodeID == node.nodeID })
    }

    private func hasDetails(_ node: NodeRun) -> Bool {
        node.model != nil || node.error != nil || node.attempts > 1 || !Self.isEmpty(node.input)
            || !Self.isEmpty(node.output) || !node.logs.isEmpty || !node.fetches.isEmpty
            || !node.toolCalls.isEmpty || !node.toolCallRecords.isEmpty || node.inputTokens != nil
            || !media(node).isEmpty
    }

    /// Nothing worth a block: absent, null, `{}` or `[]`.
    static func isEmpty(_ value: JSONValue?) -> Bool {
        switch value {
        case nil, .null?: return true
        case .object(let o)?: return o.isEmpty
        case .array(let a)?: return a.isEmpty
        default: return false
        }
    }

    /// The steps as one list, divided rather than boxed one by one.
    private var stepList: some View {
        let rows = Self.rows(run, definition: definition)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, node in
                if index > 0 { Divider() }
                nodeRow(node)
            }
        }
        .settingsChrome(.inset)
    }

    /// The word under a step's name, where its icon doesn't already say
    /// it: nil once it's done, and for a reused step, whose chip does.
    static func stateNote(_ node: NodeRun) -> String? {
        if node.reusedFrom != nil { return nil }
        switch node.status {
        case .done, .pinned: return nil
        default: return stateText(node.status)
        }
    }

    private func nodeRow(_ node: NodeRun) -> some View {
        let isOpen = expanded.contains(node.nodeID)
        let expandable = hasDetails(node)
        let note = Self.stateNote(node)
        let retried = Self.retryText(node)
        return VStack(alignment: .leading, spacing: theme.space.s6) {
            Button {
                guard expandable else { return }
                if isOpen { expanded.remove(node.nodeID) } else { expanded.insert(node.nodeID) }
            } label: {
                HStack(alignment: .top, spacing: theme.space.s8) {
                    WorkflowStepStatusIcon(status: node.status)
                        .frame(width: theme.space.s16)
                    VStack(alignment: .leading, spacing: theme.space.s4) {
                        Text(verbatim: definition?.node(node.nodeID)?.name ?? node.nodeID)
                            .foregroundColor(node.status == .skipped ? theme.text.tertiary : theme.text.primary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if note != nil || node.reusedFrom != nil || retried != nil {
                            FlowLayout(spacing: theme.space.s4) {
                                if let note {
                                    Text(verbatim: note)
                                        .textStyle(.caption)
                                        .foregroundColor(
                                            node.status == .failed
                                                ? theme.statusInk.error : theme.text.tertiary)
                                }
                                if node.reusedFrom != nil {
                                    StatusChip(
                                        L("Reused"), tone: .neutral, icon: "arrow.uturn.backward",
                                        help: L(
                                            "Not run again: the result of this step in the previous test, unchanged since."
                                        ))
                                }
                                if let retried {
                                    StatusChip(
                                        retried, tone: .warning, icon: "arrow.clockwise",
                                        help: L(
                                            "It took \(node.attempts) tries. Open the step to see why the earlier ones failed."
                                        ))
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let ms = node.durationMs {
                        Text(Self.duration(Double(ms) / 1000))
                            .font(SettingsFont.footnote)
                            .monospacedDigit()
                            .foregroundColor(theme.text.tertiary)
                            .fixedSize()
                    }
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .glyphSize(9, weight: .semibold)
                        .foregroundColor(theme.text.tertiary)
                        .frame(height: theme.space.s16)
                        .opacity(expandable ? 1 : 0)
                        .accessibilityHidden(!expandable)
                }
                .textStyle(.bodySmall)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(expandable ? Text(isOpen ? "Hides the step's details" : "Shows the step's details", bundle: .module) : Text(verbatim: ""))

            Group {
                if !isOpen, node.status == .failed, let error = node.error, !error.isEmpty {
                    Text(verbatim: error)
                        .font(SettingsFont.footnote)
                        .foregroundColor(theme.statusInk.error)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let agent = Self.agentStep(node, definition: definition) {
                    agentStepLine(agent, node: node)
                } else if node.status == .running, let progress = node.progress {
                    WorkflowNodeProgressLine(progress: progress)
                }
                if node.status == .running, let streamed = node.streamed, !streamed.isEmpty {
                    Text(verbatim: String(streamed.suffix(600)))
                        .font(SettingsFont.monoSmall)
                        .foregroundColor(theme.text.secondary)
                        .lineLimit(6)
                        .truncationMode(.head)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(Text("Model output so far", bundle: .module))
                }
                if isOpen { details(node) }
            }
            .padding(.leading, theme.space.s24)
        }
        .padding(.horizontal, theme.space.s8)
        .padding(.vertical, theme.space.s6)
    }

    /// What an agent step's row says beyond its status.
    struct AgentStep: Equatable {
        var agent: String
        var isShared: Bool
        var sessionID: UUID?
        var needsInput: Bool
        var timeout: TimeInterval
    }

    static func agentStep(_ node: NodeRun, definition: WorkflowDefinition?) -> AgentStep? {
        guard let step = definition?.node(node.nodeID), case .agent(let spec)? = step.kind else { return nil }
        let output = node.output?.objectValue
        return AgentStep(
            agent: output?["agent"]?.stringValue ?? spec.agent, isShared: spec.workspace != nil,
            sessionID: output?["session_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
            needsInput: output?["needs_input"] == .bool(true), timeout: step.timeout)
    }

    /// "Asking Research · 1m 4s of 10m 0s" while the step works.
    static func askingText(_ step: AgentStep, node: NodeRun, now: Date) -> String? {
        guard node.status == .running else { return nil }
        let asking = step.isShared ? L("Asking \(step.agent) on a teammate's Mac") : L("Asking \(step.agent)")
        guard let started = node.startedAt else { return asking }
        return "\(asking) · " + L("\(clock(now.timeIntervalSince(started))) of \(clock(step.timeout))")
    }

    /// "4s", "1m 4s": whole seconds, for a clock that ticks.
    static func clock(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds))
        return whole < 60 ? "\(whole)s" : "\(whole / 60)m \(whole % 60)s"
    }

    @ViewBuilder
    private func agentStepLine(_ step: AgentStep, node: NodeRun) -> some View {
        if node.status == .running {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let text = Self.askingText(step, node: node, now: context.date) {
                    Text(verbatim: text)
                        .font(SettingsFont.footnote)
                        .monospacedDigit()
                        .foregroundColor(theme.text.tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if step.needsInput || step.sessionID != nil {
            FlowLayout(spacing: theme.space.s8) {
                if step.needsInput {
                    Text(verbatim: L("\(step.agent) needs more information"))
                        .font(SettingsFont.footnote)
                        .foregroundColor(theme.statusInk.warning)
                }
                if let sessionID = step.sessionID {
                    Button {
                        TaskControl.openChat(sessionID, agentId: nil)
                    } label: {
                        Text("Open Conversation", bundle: .module)
                            .font(SettingsFont.footnote)
                            .foregroundColor(theme.text.link)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
            }
        }
    }

    private func details(_ node: NodeRun) -> some View {
        let files = media(node)
        let showsRaw = files.isEmpty || rawShown.contains(node.nodeID)
        return VStack(alignment: .leading, spacing: theme.space.s8) {
            if node.model != nil || node.attempts > 1 || node.inputTokens != nil {
                VStack(alignment: .leading, spacing: theme.space.s2) {
                    if let model = node.model { detailLine("Model", model) }
                    if node.attempts > 1 { detailLine("Attempts", "\(node.attempts)") }
                    if let tokens = node.inputTokens.map({ L("\($0) in / \(node.outputTokens ?? 0) out") }) {
                        detailLine("Tokens", tokens)
                    }
                }
            }
            if let error = node.error {
                Text(error)
                    .textStyle(.caption)
                    .foregroundColor(theme.statusInk.error)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !files.isEmpty { WorkflowMediaGallery(files: files) }
            if showsRaw {
                if !Self.isEmpty(node.input), let input = node.input { jsonBlock(title: "Input", value: input) }
                if !Self.isEmpty(node.output), let output = node.output { jsonBlock(title: "Output", value: output) }
            }
            if !node.logs.isEmpty { listBlock(title: "Log", items: node.logs) }
            if !node.fetches.isEmpty { listBlock(title: "Requests", items: node.fetches) }
            if !node.toolCallRecords.isEmpty {
                toolCallsBlock(node.toolCallRecords)
            } else if !node.toolCalls.isEmpty {
                listBlock(title: "Tool calls", items: node.toolCalls)
            }
            if !files.isEmpty, !Self.isEmpty(node.input) || !Self.isEmpty(node.output) {
                Button {
                    if showsRaw { rawShown.remove(node.nodeID) } else { rawShown.insert(node.nodeID) }
                } label: {
                    Text(showsRaw ? "Hide input and output" : "Show input and output", bundle: .module)
                        .textStyle(.caption)
                        .foregroundColor(theme.text.link)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
        }
    }

    private func detailLine(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.space.s6) {
            Text(label, bundle: .module)
                .foregroundColor(theme.text.tertiary)
            Text(verbatim: value)
                .foregroundColor(theme.text.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .textStyle(.caption)
    }

    private func jsonBlock(title: LocalizedStringKey, value: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title, bundle: .module)
                    .textStyle(.footnote, weight: 600)
                    .foregroundColor(theme.text.tertiary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value.prettyJSONString, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .glyphSize(10)
                        .foregroundColor(theme.text.tertiary)
                }
                .buttonStyle(.plain)
                .localizedHelp("Copy")
            }
            WorkflowJSONText(text: value.prettyJSONString, maxHeight: 220)
        }
    }

    private func listBlock(title: LocalizedStringKey, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title, bundle: .module)
                .textStyle(.footnote, weight: 600)
                .foregroundColor(theme.text.tertiary)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text(item)
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(theme.text.secondary)
                    .textSelection(.enabled)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func toolCallsBlock(_ records: [WorkflowToolCallRecord]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tool calls", bundle: .module)
                .textStyle(.footnote, weight: 600)
                .foregroundColor(theme.text.tertiary)
            ForEach(Array(records.enumerated()), id: \.offset) { _, record in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: record.isError ? "xmark.circle" : "checkmark.circle")
                            .glyphSize(10)
                            .foregroundColor(
                                record.isError ? theme.statusInk.error : theme.statusInk.success
                            )
                        Text(record.name)
                            .font(SettingsFont.monoSmall)
                            .foregroundColor(theme.text.primary)
                        Spacer()
                        if let ms = record.durationMs {
                            Text(Self.duration(Double(ms) / 1000))
                                .textStyle(.footnote)
                                .foregroundColor(theme.text.tertiary)
                        }
                    }
                    toolText(record.arguments, color: theme.text.secondary)
                    if let result = record.resultPreview, !result.isEmpty {
                        toolText(result, color: record.isError ? theme.statusInk.error : theme.text.tertiary)
                    }
                }
                .padding(theme.space.s6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .settingsChrome(.code)
            }
        }
    }

    private func toolText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(SettingsFont.monoSmall)
            .foregroundColor(color)
            .textSelection(.enabled)
            .lineLimit(6)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func color(_ status: WorkflowRunStatus) -> Color {
        WorkflowRunStyle.color(status, theme: theme)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return "\(Int(seconds * 1000)) ms" }
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        return "\(Int(seconds) / 60)m \(Int(seconds) % 60)s"
    }
}

/// When a run started, how long it took, and its Insights link.
struct WorkflowRunTiming: View {
    let run: WorkflowRun

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.space.s8) {
            Text(run.startedAt, style: .time)
            if let finished = run.finishedAt {
                Text(verbatim: WorkflowRunView.duration(finished.timeIntervalSince(run.startedAt)))
            }
            WorkflowInsightsLink(runID: run.id, refresh: run.finishedAt)
        }
        .textStyle(.caption)
        .foregroundColor(theme.text.tertiary)
    }
}

/// A run's output laid out by the workflow's output schema: one labeled
/// field per property, required properties first.
enum WorkflowOutputLayout {
    struct Field: Identifiable, Equatable {
        let key: String
        let label: String
        let text: String
        /// Nested objects, shown as JSON.
        let isStructured: Bool
        var id: String { key }
    }

    /// Nil when the output is not an object or the schema names no
    /// properties; the caller shows the raw JSON instead.
    static func fields(_ output: JSONValue, schema: JSONValue) -> [Field]? {
        guard case .object(let values) = output,
            case .object(let root) = schema,
            case .object(let properties)? = root["properties"], !properties.isEmpty
        else { return nil }
        var required: [String] = []
        if case .array(let list)? = root["required"] {
            required = list.compactMap { if case .string(let s) = $0 { s } else { nil } }
        }
        required = unique(required)
        let rest = properties.keys.filter { !required.contains($0) }.sorted()
        let extra = values.keys.filter { properties[$0] == nil }.sorted()
        return (required + rest + extra).compactMap { key in
            guard let value = values[key] else { return nil }
            var title: String?
            if case .object(let property)? = properties[key], case .string(let t)? = property["title"] {
                title = t
            }
            let (text, structured) = render(value)
            return Field(key: key, label: title ?? humanize(key), text: text, isStructured: structured)
        }
    }

    /// Output field labels in display order, before any run.
    static func labels(schema: JSONValue) -> [String] {
        guard case .object(let root) = schema, case .object(let properties)? = root["properties"] else { return [] }
        var required: [String] = []
        if case .array(let list)? = root["required"] {
            required = list.compactMap { if case .string(let s) = $0, properties[s] != nil { s } else { nil } }
        }
        required = unique(required)
        let rest = properties.keys.filter { !required.contains($0) }.sorted()
        return (required + rest).map { key in
            if case .object(let property)? = properties[key], case .string(let t)? = property["title"] { return t }
            return humanize(key)
        }
    }

    /// A schema can list a required key twice; fields are identified by key.
    private static func unique(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
    }

    static func humanize(_ key: String) -> String {
        let spaced = key.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    private static func render(_ value: JSONValue) -> (String, Bool) {
        switch value {
        case .string(let s): return (s, false)
        case .number(let n):
            return (n.rounded() == n && abs(n) < 1e15 ? String(Int64(n)) : String(n), false)
        case .bool(let b): return (b ? L("Yes") : L("No"), false)
        case .null: return ("—", false)
        case .array(let items) where items.allSatisfy(isScalar):
            return (items.map { "• " + render($0).0 }.joined(separator: "\n"), false)
        case .array, .object: return (value.prettyJSONString, true)
        }
    }

    private static func isScalar(_ value: JSONValue) -> Bool {
        switch value {
        case .array, .object: return false
        default: return true
        }
    }
}

/// Pretty-printed JSON wrapped to the width it has, at its natural height
/// up to `maxHeight` and scrolling down past that. The height is measured,
/// with the line count as the first guess: a bare `ScrollView` with only a
/// height cap let long values draw over the rows below.
struct WorkflowJSONText: View {
    let text: String
    var maxHeight: CGFloat

    @State private var measured: CGFloat = 0
    @Environment(\.theme) private var theme

    private var height: CGFloat {
        guard measured == 0 else { return min(maxHeight, measured) }
        let lines = text.reduce(into: 1) { count, character in
            if character.isNewline { count += 1 }
        }
        let lineHeight = NSLayoutManager().defaultLineHeight(for: theme.nsFont(.footnote, family: .code))
        return min(maxHeight, ceil(CGFloat(lines) * lineHeight))
    }

    var body: some View {
        let overflows = measured > maxHeight
        ScrollView(.vertical, showsIndicators: overflows) {
            Text(verbatim: text)
                .font(SettingsFont.monoSmall)
                .foregroundColor(theme.text.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: WorkflowJSONHeightKey.self, value: geo.size.height)
                    })
        }
        .scrollDisabled(!overflows)
        .frame(height: height)
        .clipped()
        .onPreferenceChange(WorkflowJSONHeightKey.self) { measured = $0 }
    }
}

private struct WorkflowJSONHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Opens Insights on a run's log row. Hidden until the run has one.
struct WorkflowInsightsLink: View {
    let runID: UUID
    /// Changes when the run may have written its row.
    var refresh: Date?

    @State private var available = false
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if available {
                Button {
                    if InsightsService.shared.focus(workflowRunId: runID) {
                        AppDelegate.shared?.showManagementWindow(initialTab: .insights)
                    }
                } label: {
                    Image(systemName: "chart.bar.doc.horizontal")
                        .glyphSize(11)
                        .foregroundColor(theme.text.tertiary)
                }
                .buttonStyle(.plain)
                .localizedHelp("View in Insights")
            }
        }
        .task(id: refresh) {
            available = InsightsService.shared.hasLog(workflowRunId: runID)
        }
    }
}

/// "Fix with the Architect" on a failed run.
struct WorkflowFixButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text("Fix with the Architect", bundle: .module)
            } icon: {
                Image(systemName: "wrench.and.screwdriver")
            }
        }
        .buttonStyle(.settings(.secondary, size: .compact))
        .localizedHelp("Opens the workflow in an Architect chat that reads this run, fixes the failed step, and re-tests it.")
        .settingsLandingAnchor("workflows.runFix")
    }
}
