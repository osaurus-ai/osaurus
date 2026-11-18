//
//  WorkflowStoryView.swift
//  osaurus
//
//  "How it works": a workflow's steps as numbered sentences in the
//  Architect's words. Steps glow in as the Architect adds or changes
//  them, and light up one after another as a try runs through them. Given
//  `onSelect`, a step opens in place to show its settings.
//

import SwiftUI

struct WorkflowStoryView: View {
    let definition: WorkflowDefinition
    /// The try to show on the steps, finished or not.
    var run: WorkflowRun?
    /// Steps the Architect's latest change touched.
    var changed: [String] = []
    /// Steps beyond this many collapse behind "and N more".
    var limit: Int?
    /// The open step.
    var selection: String?
    /// Opens (or, with nil, closes) a step. Without it the steps only read.
    var onSelect: ((String?) -> Void)?
    /// What an open step shows under its sentence.
    var detail: ((WorkflowNode) -> AnyView)?

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum StepState: Equatable { case idle, running, done, failed, skipped }

    /// How a step reads on `run`. Skipped steps never ran (the try stopped
    /// earlier, or their branch wasn't taken), so they don't read as done.
    static func state(_ nodeID: String, in run: WorkflowRun?) -> StepState {
        switch run?.node(nodeID)?.status {
        case .running?, .awaitingUser?: return .running
        case .done?, .pinned?: return .done
        case .skipped?: return .skipped
        case .failed?: return .failed
        case .pending?, nil: return .idle
        }
    }

    /// What a step does, in a sentence: the Architect's intent when it
    /// wrote one, else the step's name.
    static func sentence(_ node: WorkflowNode) -> String {
        DraftStepDetail.description(node) ?? node.name
    }

    var body: some View {
        let steps = WorkflowSummary.steps(definition)
        let shown = limit.map { Array(steps.prefix($0)) } ?? steps
        VStack(alignment: .leading, spacing: theme.space.s0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, step in
                if let node = definition.node(step.id) {
                    let state = Self.state(step.id, in: run)
                    row(node, number: index + 1, state: state, isLast: index == shown.count - 1 && shown.count == steps.count)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                }
            }
            if shown.count < steps.count {
                Text(verbatim: L("and \(steps.count - shown.count) more"))
                    .textStyle(.caption)
                    .foregroundStyle(theme.text.tertiary)
                    .padding(.leading, theme.space.s32)
            }
        }
        .animation(reduceMotion ? nil : theme.motion.springAnimation, value: steps.map(\.id))
        .animation(reduceMotion ? nil : theme.motion.standard, value: run?.nodes.map(\.status))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("How it works", bundle: .module))
    }

    private func row(_ node: WorkflowNode, number: Int, state: StepState, isLast: Bool) -> some View {
        let isChanged = changed.contains(node.id)
        let isOpen = onSelect != nil && selection == node.id
        return HStack(alignment: .top, spacing: theme.space.s12) {
            VStack(spacing: theme.space.s0) {
                marker(number: number, state: state)
                if !isLast {
                    connector(state: state)
                }
            }
            VStack(alignment: .leading, spacing: theme.space.s8) {
                heading(node, state: state, isOpen: isOpen)
                if isOpen, let detail {
                    detail(node)
                        .padding(theme.space.s12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .settingsChrome(.inset)
                        .transition(.opacity)
                }
            }
            .padding(.bottom, isLast ? theme.space.s0 : theme.space.s12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, theme.space.s4)
        .architectGlowIn(trigger: isChanged ? node : nil, radius: theme.radius.small)
        .accessibilityElement(children: onSelect == nil ? .combine : .contain)
        .accessibilityValue(Text(verbatim: Self.accessibilityState(state)))
    }

    @ViewBuilder
    private func heading(_ node: WorkflowNode, state: StepState, isOpen: Bool) -> some View {
        let label = HStack(alignment: .top, spacing: theme.space.s8) {
            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text(verbatim: node.name)
                    .textStyle(.label, weight: 500)
                    .foregroundStyle(
                        state == .skipped || (state == .idle && run != nil) ? theme.text.secondary : theme.text.primary)
                    .multilineTextAlignment(.leading)
                let sentence = Self.sentence(node)
                if sentence != node.name {
                    Text(verbatim: sentence)
                        .textStyle(.caption)
                        .foregroundStyle(theme.text.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(isOpen ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if onSelect != nil {
                Image(systemName: "chevron.right")
                    .glyphSize(.micro, weight: .semibold)
                    .foregroundStyle(theme.text.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .padding(.top, theme.space.s4)
                    .accessibilityHidden(true)
            }
        }
        if let onSelect {
            Button {
                withAnimation(reduceMotion ? nil : theme.motion.quick) { onSelect(isOpen ? nil : node.id) }
            } label: {
                label.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help(isOpen ? L("Close this step") : L("See this step's settings"))
            .accessibilityValue(Text(isOpen ? "Expanded" : "Collapsed", bundle: .module))
        } else {
            label
        }
    }

    static func accessibilityState(_ state: StepState) -> String {
        switch state {
        case .idle: return ""
        case .running: return L("Working")
        case .done: return L("Done")
        case .failed: return L("Didn't work")
        case .skipped: return L("Didn't run")
        }
    }

    @ViewBuilder
    private func marker(number: Int, state: StepState) -> some View {
        let size = theme.space.s20
        ZStack {
            switch state {
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .glyphSize(.medium, weight: .semibold)
                    .foregroundStyle(theme.statusInk(.success))
                    .transition(.scale.combined(with: .opacity))
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .glyphSize(.medium, weight: .semibold)
                    .foregroundStyle(theme.statusInk(.error))
                    .transition(.scale.combined(with: .opacity))
            case .running:
                SettingsSpinner(size: .mini)
            case .idle, .skipped:
                Text(verbatim: "\(number)")
                    .textStyle(.micro, weight: 600)
                    .foregroundStyle(state == .skipped ? theme.text.tertiary : theme.text.secondary)
                    .frame(width: size, height: size)
                    .overlay { Circle().strokeBorder(theme.border.default, lineWidth: theme.stroke.default) }
            }
        }
        .frame(width: size, height: size)
    }

    private func connector(state: StepState) -> some View {
        Rectangle()
            .fill(state == .done ? theme.statusInk(.success) : theme.border.default)
            .frame(width: theme.stroke.default)
            .overlay {
                if state == .running { ArchitectTravellingPulse() }
            }
            .frame(width: theme.space.s20)
            .frame(minHeight: theme.space.s12)
            .accessibilityHidden(true)
    }
}

/// A dot travelling down a connector while the step above it works. It
/// lays out over the line itself, so its center is the line's center.
private struct ArchitectTravellingPulse: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var travelled = false

    var body: some View {
        GeometryReader { geo in
            let dot = theme.space.s4
            Circle()
                .fill(theme.statusInk(.info))
                .frame(width: dot, height: dot)
                .position(
                    x: geo.size.width / 2,
                    y: travelled ? max(dot / 2, geo.size.height - dot / 2) : dot / 2)
                .opacity(reduceMotion ? 0 : (travelled ? 0.2 : 1))
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(theme.motion.loop(.easeInOut, duration: 1.1)) { travelled = true }
        }
    }
}
