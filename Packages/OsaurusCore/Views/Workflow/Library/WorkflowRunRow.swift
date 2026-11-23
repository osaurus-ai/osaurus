//
//  WorkflowRunRow.swift
//  osaurus
//
//  The two lists every Workflows page shares. `WorkflowRunRow` is one run
//  anywhere runs are listed (a workflow's Recent Runs, Running Now on Home,
//  Activity): how it stands, a title, one plain line, and when. Rows sit in
//  `WorkflowRowList`, divided by hairlines on one card. `WorkflowStepList`
//  is what a workflow does, one numbered step per row.
//

import SwiftUI

struct WorkflowRunRow<Trailing: View>: View {
    enum Time: Equatable {
        /// "5 min. ago".
        case relative(Date)
        /// "8:00 AM", under a day heading.
        case clock(Date)
        /// Seconds since it started, ticking.
        case elapsed(since: Date)
        case none
    }

    @Environment(\.theme) private var theme
    let status: WorkflowRunStatus
    /// Already localized.
    let title: String
    /// Already localized.
    let line: String
    var lineIsProblem = false
    var time: Time = .none
    /// Opening shows more in place (a down chevron) rather than a page.
    var expands = false
    let onOpen: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: theme.space.s12) {
            WorkflowRunStatusIcon(status: status, size: 12)
                .frame(width: theme.space.s16, height: theme.space.s16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text(verbatim: title)
                    .textStyle(.body, weight: 500)
                    .foregroundStyle(theme.text.primary)
                    .lineLimit(1)
                Text(verbatim: line)
                    .font(SettingsFont.footnote)
                    .foregroundStyle(lineIsProblem ? theme.statusInk(.error) : theme.text.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            timeLabel
            trailing()
            Image(systemName: expands ? "chevron.down" : "chevron.right")
                .glyphSize(.tiny, weight: .semibold)
                .foregroundStyle(theme.text.tertiary)
                .opacity(isHovered || expands ? 1 : 0)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, theme.space.s16)
        .padding(.vertical, theme.space.s12)
        .background { if isHovered { theme.surface.hover } }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering in withAnimation(theme.motion.quick) { isHovered = hovering } }
        .pointingHandCursor()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "\(title), \(line)"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: expands ? Text("What happened", bundle: .module) : Text("Open the run", bundle: .module), onOpen)
    }

    @ViewBuilder
    private var timeLabel: some View {
        switch time {
        case .relative(let date):
            timeText(WorkflowRunPresentation.relativeTime(date))
        case .clock(let date):
            timeText(AutomationSentence.Style.current.time(date))
        case .elapsed(let start):
            TimelineView(.periodic(from: start, by: 1)) { context in
                timeText(WorkflowRunWords.stopwatch(context.date.timeIntervalSince(start)))
            }
            .accessibilityLabel(Text("Elapsed time", bundle: .module))
        case .none:
            EmptyView()
        }
    }

    private func timeText(_ text: String) -> some View {
        Text(verbatim: text)
            .font(SettingsFont.footnote)
            .monospacedDigit()
            .foregroundStyle(theme.text.tertiary)
            .lineLimit(1)
            .fixedSize()
    }
}

extension WorkflowRunRow where Trailing == EmptyView {
    init(
        status: WorkflowRunStatus, title: String, line: String, lineIsProblem: Bool = false, time: Time = .none,
        expands: Bool = false, onOpen: @escaping () -> Void
    ) {
        self.init(
            status: status, title: title, line: line, lineIsProblem: lineIsProblem, time: time, expands: expands,
            onOpen: onOpen, trailing: { EmptyView() })
    }
}

/// Rows on one card, divided by hairlines.
struct WorkflowRowList<Item: Identifiable, Row: View>: View {
    @Environment(\.theme) private var theme
    let items: [Item]
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        VStack(spacing: theme.space.s0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    ThemeHairlineDivider(color: theme.border.subtle)
                        .padding(.horizontal, theme.space.s16)
                }
                row(item)
            }
        }
        .workflowCardContents()
    }
}

/// What a workflow does: each step's number and name, in run order, then
/// any facts about the whole of it (what it gives back, where it runs) on
/// the same card.
struct WorkflowStepList: View {
    struct Fact: Identifiable, Equatable {
        let icon: String
        /// Already localized.
        let text: String
        var id: String { text }
    }

    @Environment(\.theme) private var theme
    let steps: [WorkflowSummary.Step]
    var facts: [Fact] = []

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                if index > 0 {
                    ThemeHairlineDivider(color: theme.border.subtle)
                        .padding(.leading, theme.space.s16 + theme.space.s20 + theme.space.s12)
                }
                HStack(alignment: .center, spacing: theme.space.s12) {
                    Text(verbatim: "\(index + 1)")
                        .textStyle(.caption, weight: 600)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .foregroundStyle(theme.text.secondary)
                        .frame(width: theme.space.s20, height: theme.space.s20)
                        .background(Circle().fill(theme.surface.subtle))
                        .overlay(Circle().strokeBorder(theme.border.subtle))
                        .accessibilityHidden(true)
                    Text(verbatim: step.name)
                        .textStyle(.body)
                        .foregroundStyle(theme.text.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, theme.space.s16)
                .padding(.vertical, theme.space.s10)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(verbatim: L("Step \(index + 1): \(step.name)")))
            }
            if !facts.isEmpty {
                if !steps.isEmpty { ThemeHairlineDivider(color: theme.border.subtle) }
                VStack(alignment: .leading, spacing: theme.space.s6) {
                    ForEach(facts) { fact in
                        HStack(alignment: .firstTextBaseline, spacing: theme.space.s12) {
                            Image(systemName: fact.icon)
                                .glyphSize(.footnote, weight: .medium)
                                .foregroundStyle(theme.text.tertiary)
                                .frame(width: theme.space.s20)
                                .accessibilityHidden(true)
                            Text(verbatim: fact.text)
                                .font(SettingsFont.footnote)
                                .foregroundStyle(theme.text.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, theme.space.s16)
                .padding(.vertical, theme.space.s12)
                .background(theme.surface.subtle)
            }
        }
        .workflowCardContents()
    }
}

extension View {
    /// A card whose rows paint their own fills (a hovered row, a footer
    /// band): the rows sit inside the card's border, clipped to its corners,
    /// since the card draws its border beneath them.
    func workflowCardContents() -> some View {
        modifier(WorkflowCardContents())
    }
}

private struct WorkflowCardContents: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        let border = theme.stroke.default
        content
            .clipShape(RoundedRectangle(cornerRadius: max(0, theme.radius.large - border), style: .continuous))
            .padding(border)
            .settingsChrome(.card)
    }
}
