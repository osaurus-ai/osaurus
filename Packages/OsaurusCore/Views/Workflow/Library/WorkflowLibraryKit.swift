//
//  WorkflowLibraryKit.swift
//  osaurus
//
//  The parts every Workflows screen shares, so runs, drafts, and saved
//  workflows read as one product: one row, one section heading, one way
//  to show how far a run has got, and one way to say who started it.
//

import Combine
import SwiftUI

// MARK: - Run presentation

/// How a run reads wherever the Workflows window lists it.
@MainActor
enum WorkflowRunPresentation {
    /// A run that just ended stays in Running Now this long, showing how it
    /// ended, before it settles into its workflow's history.
    static let lingerInterval: TimeInterval = 8
    /// Runs an expanded workflow row shows.
    static let recentPerWorkflow = 5

    /// Running Now: runs going this launch (tests left out), plus ones that
    /// ended moments ago. Waiting on you first, then running, then ended;
    /// newest first within each.
    static func activity(_ runs: some Sequence<WorkflowRun>, now: Date = Date()) -> [WorkflowRun] {
        runs.filter { !$0.isTest && (!$0.status.isTerminal || isLingering($0, now: now)) }
            .sorted { lhs, rhs in
                let (l, r) = (rank(lhs.status), rank(rhs.status))
                return l != r ? l < r : lhs.startedAt > rhs.startedAt
            }
    }

    static func isLingering(_ run: WorkflowRun, now: Date = Date()) -> Bool {
        guard run.status.isTerminal, let finished = run.finishedAt else { return false }
        return now.timeIntervalSince(finished) < lingerInterval
    }

    private static func rank(_ status: WorkflowRunStatus) -> Int {
        switch status {
        case .awaitingUser: return 0
        case .running: return 1
        default: return 2
        }
    }

    static func finishedSteps(_ run: WorkflowRun) -> Int {
        run.nodes.filter { [.done, .pinned, .skipped].contains($0.status) }.count
    }

    /// 0…1: finished steps, plus how far the running step reports it has got.
    static func fraction(_ run: WorkflowRun) -> Double {
        guard !run.nodes.isEmpty else { return run.status == .completed ? 1 : 0 }
        if run.status == .completed { return 1 }
        let partial = currentNode(run)?.progress?.fraction ?? 0
        return min(1, (Double(finishedSteps(run)) + partial) / Double(run.nodes.count))
    }

    /// The step the run is on: the one waiting on someone, else the one working.
    static func currentNode(_ run: WorkflowRun) -> NodeRun? {
        run.nodes.first { $0.status == .awaitingUser } ?? run.nodes.first { $0.status == .running }
    }

    /// "Step 2 of 4 · Summarize" while it works; how it ended after.
    static func progressLine(_ run: WorkflowRun, definition: WorkflowDefinition?) -> String {
        switch run.status {
        case .running:
            let total = run.nodes.count
            let index = min(total, finishedSteps(run) + 1)
            let step = currentNode(run).flatMap { definition?.node($0.nodeID)?.name }
            let position = total == 0 ? L("Starting…") : L("Step \(index) of \(total)")
            if let detail = currentNode(run)?.progress?.detail, !detail.isEmpty {
                return "\(position) · \(detail)"
            }
            return step.map { "\(position) · \($0)" } ?? position
        case .awaitingUser:
            let step = currentNode(run).flatMap { definition?.node($0.nodeID)?.name }
            return step.map { L("Waiting for your answer at \($0)") } ?? WorkflowRunTabView.statusText(.awaitingUser)
        default:
            return WorkflowRunHistoryModel.outcome(run, definition: definition)
        }
    }

    /// The glyph beside who started a run: a bolt for automations.
    static func startedByIcon(_ caller: WorkflowCaller) -> String? {
        switch caller.kind {
        case .event: return "bolt.fill"
        case .agent, .orchestrator: return "sparkles"
        case .workflow: return "flowchart"
        default: return nil
        }
    }

    /// "Just now", "5 min. ago", "Yesterday".
    static func relativeTime(_ date: Date, now: Date = Date()) -> String {
        if abs(now.timeIntervalSince(date)) < 45 { return L("just now") }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .named
        return formatter
    }()

    /// The last run in a few words: "Done · 2 hr. ago", "Running".
    static func lastRunSummary(_ run: WorkflowRun, now: Date = Date()) -> String {
        guard run.status.isTerminal else { return shortStatus(run.status) }
        return "\(shortStatus(run.status)) · \(relativeTime(run.finishedAt ?? run.startedAt, now: now))"
    }

    static func shortStatus(_ status: WorkflowRunStatus) -> String {
        switch status {
        case .running: return L("Running")
        case .awaitingUser: return L("Waiting on you")
        case .completed: return L("Done")
        case .failed: return L("Failed")
        case .cancelled: return L("Stopped")
        case .needsSetup: return L("Needs setup")
        }
    }

    static func tone(_ status: WorkflowRunStatus) -> StatusChip.Tone {
        switch status {
        case .running: return .info
        case .awaitingUser, .needsSetup: return .warning
        case .completed: return .success
        case .failed: return .error
        case .cancelled: return .neutral
        }
    }

    /// Each workflow's runs, newest first.
    static func runsByWorkflow(_ runs: [WorkflowRun]) -> [UUID: [WorkflowRun]] {
        Dictionary(grouping: runs.filter { !$0.isTest }, by: \.workflowID)
            .mapValues { $0.sorted { $0.startedAt > $1.startedAt } }
    }

    /// True when Run has to ask for something first: a required field with
    /// no default value.
    static func needsInput(_ definition: WorkflowDefinition) -> Bool {
        WorkflowFormFields.fields(fromInputSchema: definition.inputSchema)
            .contains { $0.required && $0.defaultValue == nil }
    }
}

/// What the Workflows home shows of runs outside an open row: each
/// workflow's last run and the run it has going, and how many runs wait
/// on an answer. The run store publishes on every step of every run; this
/// publishes only when one of these changes.
@MainActor
final class WorkflowRunGlances: ObservableObject {
    static let shared = WorkflowRunGlances()

    struct RunGlance: Equatable, Sendable {
        let id: UUID
        let status: WorkflowRunStatus
        let ended: Date?

        init(_ run: WorkflowRun) {
            id = run.id
            status = run.status
            ended = run.finishedAt
        }
    }

    struct Glance: Equatable, Sendable {
        var lastRun: RunGlance?
        var liveRunID: UUID?
    }

    @Published private(set) var byWorkflow: [UUID: Glance] = [:]
    @Published private(set) var waitingCount = 0
    private var subscription: AnyCancellable?

    init(store: WorkflowRunStore = .shared) {
        // `$live` fires before the store changes, with the new value.
        subscription = store.$live.combineLatest(store.$recentPersisted)
            .sink { [weak self] live, persisted in self?.update(live: live, persisted: persisted ?? []) }
    }

    /// The same runs as `WorkflowRunStore.recentRuns`: tests left out, a
    /// run this launch knows live over its record.
    private func update(live: [UUID: WorkflowRun], persisted: [WorkflowRun]) {
        var latest: [UUID: WorkflowRun] = [:]
        var going: [UUID: WorkflowRun] = [:]
        func consider(_ run: WorkflowRun) {
            guard !run.isTest else { return }
            if latest[run.workflowID].map({ run.startedAt > $0.startedAt }) ?? true { latest[run.workflowID] = run }
            if !run.status.isTerminal, going[run.workflowID].map({ run.startedAt > $0.startedAt }) ?? true {
                going[run.workflowID] = run
            }
        }
        for run in persisted where live[run.id] == nil { consider(run) }
        live.values.forEach(consider)
        var glances: [UUID: Glance] = [:]
        for (workflowID, run) in latest {
            glances[workflowID] = Glance(lastRun: RunGlance(run), liveRunID: going[workflowID]?.id)
        }
        let waiting = live.values.filter { !$0.isTest && $0.status == .awaitingUser }.count
        if glances != byWorkflow { byWorkflow = glances }
        if waiting != waitingCount { waitingCount = waiting }
    }
}

// MARK: - Layout

enum WorkflowLibraryLayout {
    /// The reading column of every Workflows page.
    static let columnWidth: CGFloat = 640

    /// Space between the title bar and the top of every Workflows page.
    static func pageTopInset(_ theme: any ThemeProtocol) -> CGFloat { theme.space.s48 }
}

extension View {
    /// The card surface in the Architect's draft.
    func workflowCanvasCard() -> some View { settingsChrome(.canvas) }
}

// MARK: - Making a workflow

/// Making a workflow, in order: the Architect makes it, you try it, you
/// share it. The preview and the Architect's details show where a draft
/// stands.
enum WorkflowMakeStage: Int, CaseIterable, Comparable, Identifiable {
    case make, tryIt, share

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .make: return L("Build")
        case .tryIt: return L("Run")
        case .share: return L("Share")
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension DraftStatus {
    /// The stage a draft is at: making until it has valid steps that can
    /// run, trying until it is saved. Saved drafts are at Share; see
    /// `ArchitectPreviewPhase.stage`.
    var stage: WorkflowMakeStage {
        switch kind {
        case .drafting, .needsSetup: return .make
        case .ready, .testing, .testFailed, .tested: return .tryIt
        }
    }
}

/// Build → Run → Share, the current stage marked. Compact shows
/// only the current stage's name. `isActive` pulses the current marker
/// while something is happening that the person is waiting on.
struct WorkflowStageStepper: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let stage: WorkflowMakeStage
    var compact = false
    var isActive = false
    /// Every stage checked: the workflow is made, tried, and shared.
    var isComplete = false

    @State private var pulse = false

    var body: some View {
        HStack(spacing: compact ? theme.space.s4 : theme.space.s6) {
            ForEach(WorkflowMakeStage.allCases) { item in
                if item != .make {
                    ZStack(alignment: .leading) {
                        Rectangle().fill(theme.border.default)
                        Rectangle()
                            .fill(theme.statusInk(.success))
                            .frame(width: item <= stage ? nil : 0)
                    }
                    .frame(width: compact ? theme.space.s6 : theme.space.s24, height: theme.stroke.default)
                    .clipped()
                }
                HStack(spacing: theme.space.s4) {
                    marker(item)
                    if !compact || item == stage {
                        Text(verbatim: item.title)
                            .textStyle(.caption, weight: item == stage ? 600 : 400)
                            .foregroundStyle(item == stage ? theme.text.primary : theme.text.tertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : theme.motion.standard, value: stage)
        .animation(reduceMotion ? nil : theme.motion.standard, value: isComplete)
        .onAppear { updatePulse() }
        .onChange(of: isActive) { _, _ in updatePulse() }
        .accessibilityElement()
        .accessibilityLabel(Text("Progress", bundle: .module))
        .accessibilityValue(
            Text(verbatim: L("Step \(stage.rawValue + 1) of \(WorkflowMakeStage.allCases.count): \(stage.title)")))
    }

    private func updatePulse() {
        guard isActive, !reduceMotion else {
            pulse = false
            return
        }
        withAnimation(theme.motion.loop(.easeInOut, duration: 0.9, autoreverses: true)) { pulse = true }
    }

    @ViewBuilder
    private func marker(_ item: WorkflowMakeStage) -> some View {
        if item < stage || (isComplete && item == stage) {
            Image(systemName: "checkmark.circle.fill")
                .glyphSize(.micro, weight: .semibold)
                .foregroundStyle(theme.statusInk(.success))
                .transition(.scale.combined(with: .opacity))
        } else if item == stage {
            Image(systemName: "circle.inset.filled")
                .glyphSize(.micro, weight: .semibold)
                .foregroundStyle(theme.statusInk(.info))
                .opacity(pulse ? 0.45 : 1)
                .scaleEffect(pulse ? 0.85 : 1)
        } else {
            Image(systemName: "circle")
                .glyphSize(.micro)
                .foregroundStyle(theme.text.tertiary)
        }
    }
}

// MARK: - Section heading

/// The one section heading on the Workflows canvas: a quiet label with an
/// optional count and a trailing link.
struct WorkflowSectionHeader<Trailing: View>: View {
    @Environment(\.theme) private var theme
    /// Already localized.
    let title: String
    var count: Int? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.space.s8) {
            Text(verbatim: title)
                .textStyle(.caption, weight: 500)
                .foregroundStyle(theme.text.tertiary)
                .accessibilityAddTraits(.isHeader)
            if let count {
                Text(verbatim: "\(count)")
                    .textStyle(.caption)
                    .monospacedDigit()
                    .foregroundStyle(theme.text.tertiary)
            }
            Spacer(minLength: theme.space.s8)
            trailing()
        }
    }
}

extension WorkflowSectionHeader where Trailing == EmptyView {
    init(title: String, count: Int? = nil) {
        self.init(title: title, count: count, trailing: { EmptyView() })
    }
}

// MARK: - Page tabs

/// Tabs within one half of the Workflows window: titles over a hairline,
/// the chosen one underlined (the inspector's sub-tabs at page scale), and
/// room on the right for the tab's own controls, like its search field.
struct WorkflowPageTab<Value: Hashable>: Identifiable {
    let value: Value
    /// Already localized.
    let title: String
    var count: Int? = nil
    var id: Value { value }
}

struct WorkflowPageTabBar<Value: Hashable, Trailing: View>: View {
    @Environment(\.theme) private var theme
    @Binding var selection: Value
    let tabs: [WorkflowPageTab<Value>]
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .bottom, spacing: theme.space.s24) {
            ForEach(tabs) { tab in
                WorkflowPageTabButton(title: tab.title, count: tab.count, isSelected: selection == tab.value) {
                    selection = tab.value
                }
                .anchorPreference(key: SelectedPageTabBounds.self, value: .bounds) {
                    selection == tab.value ? $0 : nil
                }
            }
            Spacer(minLength: theme.space.s12)
        }
        // Over the row, not in it: a tab's controls never move the titles.
        .overlay(alignment: .bottomTrailing) {
            trailing()
                .padding(.bottom, theme.space.s8)
        }
        .overlay(alignment: .bottom) {
            ThemeHairlineDivider()
        }
        // One underline that slides between tabs, drawn over the hairline.
        .overlayPreferenceValue(SelectedPageTabBounds.self) { anchor in
            GeometryReader { proxy in
                if let anchor {
                    let bounds = proxy[anchor]
                    Rectangle()
                        .fill(theme.action.primary.default.background)
                        .frame(width: bounds.width, height: theme.stroke.focus)
                        .offset(x: bounds.minX, y: bounds.maxY - theme.stroke.focus)
                }
            }
            .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
    }
}

extension WorkflowPageTabBar where Trailing == EmptyView {
    init(selection: Binding<Value>, tabs: [WorkflowPageTab<Value>]) {
        self.init(selection: selection, tabs: tabs, trailing: { EmptyView() })
    }
}

private struct SelectedPageTabBounds: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

private struct WorkflowPageTabButton: View {
    @Environment(\.theme) private var theme
    let title: String
    let count: Int?
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            // One weight for every state, so choosing a tab never shifts
            // the others.
            HStack(alignment: .firstTextBaseline, spacing: theme.space.s6) {
                Text(verbatim: title)
                    .textStyle(.body, weight: 500)
                    .foregroundStyle(isSelected || isHovering ? theme.text.primary : theme.text.secondary)
                if let count {
                    Text(verbatim: "\(count)")
                        .textStyle(.footnote, weight: 500)
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? theme.text.secondary : theme.text.tertiary)
                }
            }
            .padding(.top, theme.space.s4)
            .padding(.bottom, theme.space.s12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { isHovering = $0 }
        .animation(theme.motion.quick, value: isHovering)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Page header

/// A workflow's page and its runs' pages: the name as large as Home's
/// title with the page's actions beside it, one line about it, any chips,
/// then how it stands now. Everything shares the sections' left edge.
struct WorkflowPageHeader<Chips: View, Actions: View, Status: View>: View {
    @Environment(\.theme) private var theme
    /// Verbatim.
    let title: String
    var subtitle: String?
    @ViewBuilder var chips: () -> Chips
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var status: () -> Status

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s6) {
            HStack(alignment: .center, spacing: theme.space.s12) {
                Text(verbatim: title)
                    .textStyle(.title)
                    .foregroundStyle(theme.text.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .layoutPriority(1)
                Spacer(minLength: theme.space.s12)
                HStack(spacing: theme.space.s8) { actions() }
                    .fixedSize()
            }
            if let subtitle, !subtitle.isEmpty {
                Text(verbatim: subtitle)
                    .font(SettingsFont.rowDescription)
                    .foregroundStyle(theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if Chips.self != EmptyView.self {
                HStack(spacing: theme.space.s6) { chips() }
                    .padding(.top, theme.space.s2)
            }
            status()
                .padding(.top, theme.space.s6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Card grid

enum WorkflowCardGridColumns {
    static func count(_ count: Int, fit: Int) -> Int {
        let fit = max(1, fit)
        guard count > fit else { return max(1, count) }
        guard fit > 1 else { return 1 }
        if let even = (2...fit).reversed().first(where: { count % $0 == 0 }) { return even }
        if count <= 3 { return 1 }
        return (2...fit).reversed().max { count % $0 < count % $1 } ?? fit
    }
}

/// Cards in even rows: as many columns as fit, then the count that leaves
/// no short last row (4 cards make 2 by 2, 6 make 3 by 2, 3 that don't
/// fit in one row stack). When a short row can't be avoided, its cards
/// keep the column width, centered.
struct WorkflowCardGrid<Item: Identifiable, Card: View>: View {
    @Environment(\.theme) private var theme
    let items: [Item]
    /// Nil: wide enough for a card's name on one line at the current text size.
    var minimumCardWidth: CGFloat? = nil
    var maximumColumns = 3
    @ViewBuilder var card: (Item) -> Card

    @State private var width: CGFloat = 0

    private var fit: Int {
        guard width > 0 else { return maximumColumns }
        let minimum = minimumCardWidth ?? theme.pointSize(.body) * 12
        return min(maximumColumns, max(1, Int((width + theme.space.s12) / (minimum + theme.space.s12))))
    }

    var body: some View {
        let perRow = WorkflowCardGridColumns.count(items.count, fit: fit)
        let rows = stride(from: 0, to: items.count, by: perRow).map { Array(items[$0..<min($0 + perRow, items.count)]) }
        let cardWidth = max(0, (width - theme.space.s12 * CGFloat(perRow - 1)) / CGFloat(perRow))
        VStack(alignment: .center, spacing: theme.space.s12) {
            ForEach(rows.indices, id: \.self) { index in
                let row = rows[index]
                HStack(alignment: .top, spacing: theme.space.s12) {
                    ForEach(row) { item in
                        if row.count < perRow, width > 0 {
                            card(item).frame(width: cardWidth, alignment: .topLeading).frame(maxHeight: .infinity, alignment: .top)
                        } else {
                            card(item).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// A quiet text link beside a section heading or under a list.
struct WorkflowTextLink: View {
    @Environment(\.theme) private var theme
    /// Already localized.
    let title: String
    var icon: String? = nil
    let action: () -> Void

    var body: some View {
        SettingsButton(.tertiary, title, icon: icon, size: .extraSmall, verbatim: true, action: action)
    }
}

// MARK: - Progress

/// How far a run has got: a thin bar in the run's status color.
struct WorkflowRunProgressBar: View {
    @Environment(\.theme) private var theme
    let run: WorkflowRun

    var body: some View {
        SettingsProgressBar(
            value: WorkflowRunPresentation.fraction(run),
            tint: WorkflowRunStyle.color(run.status, theme: theme))
            .accessibilityLabel(Text("Progress", bundle: .module))
    }
}

/// Seconds since a run started, ticking while it goes.
struct WorkflowRunElapsed: View {
    @Environment(\.theme) private var theme
    let run: WorkflowRun

    var body: some View {
        TimelineView(.periodic(from: run.startedAt, by: 1)) { context in
            let end = run.finishedAt ?? context.date
            Text(verbatim: WorkflowRunWords.stopwatch(end.timeIntervalSince(run.startedAt)))
                .textStyle(.caption)
                .monospacedDigit()
                .foregroundStyle(theme.text.tertiary)
        }
        .accessibilityLabel(Text("Elapsed time", bundle: .module))
    }
}

/// Who started a run, with a bolt for automations.
struct WorkflowStartedByLabel: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var agents = AgentManager.shared
    let caller: WorkflowCaller

    var body: some View {
        HStack(spacing: theme.space.s4) {
            if let icon = WorkflowRunPresentation.startedByIcon(caller) {
                Image(systemName: icon)
                    .glyphSize(.tiny, weight: .semibold)
                    .foregroundStyle(caller.kind == .event ? theme.statusInk(.warning) : theme.text.tertiary)
                    .accessibilityHidden(true)
            }
            Text(verbatim: WorkflowRunHistoryModel.startedBy(caller) { agents.agent(for: $0)?.displayName })
                .textStyle(.caption)
                .foregroundStyle(theme.text.tertiary)
                .lineLimit(1)
        }
    }
}

// MARK: - Rows

/// The one row of the Workflows window. Every list (runs, workflows,
/// drafts, created) uses it: an optional status glyph, the title with a
/// secondary line beside it, trailing facts, one primary action, and ⋯.
/// A row with `expanded` content opens in place below a hairline.
struct WorkflowHomepageRow<Leading: View, Meta: View, Accessory: View, Actions: View, Expanded: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    let summary: String
    var isDraft = false
    var isExpandable = false
    var isExpanded = false
    /// Keyboard selection in the list.
    var isSelected = false
    let onOpen: () -> Void
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let meta: () -> Meta
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let actions: () -> Actions
    @ViewBuilder let expanded: () -> Expanded
    var keyboard = WorkflowRowKeyboard()

    @State private var isHovered = false

    init(
        title: String, summary: String, isDraft: Bool = false, isExpandable: Bool = false, isExpanded: Bool = false,
        isSelected: Bool = false, onOpen: @escaping () -> Void,
        @ViewBuilder leading: @escaping () -> Leading, @ViewBuilder meta: @escaping () -> Meta,
        @ViewBuilder accessory: @escaping () -> Accessory, @ViewBuilder actions: @escaping () -> Actions,
        @ViewBuilder expanded: @escaping () -> Expanded
    ) {
        self.title = title
        self.summary = summary
        self.isDraft = isDraft
        self.isExpandable = isExpandable
        self.isExpanded = isExpanded
        self.isSelected = isSelected
        self.onOpen = onOpen
        self.leading = leading
        self.meta = meta
        self.accessory = accessory
        self.actions = actions
        self.expanded = expanded
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
        VStack(alignment: .leading, spacing: theme.space.s0) {
            header
            if isExpanded {
                ThemeHairlineDivider()
                    .padding(.horizontal, theme.space.s16)
                    .accessibilityHidden(true)
                expanded()
                    .padding(.horizontal, theme.space.s16)
                    .padding(.vertical, theme.space.s12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background {
            shape.fill(theme.surface.canvas)
            shape.fill(isSelected ? theme.surface.selected : isHovered ? theme.surface.hover : .clear)
        }
        .overlay(
            shape.strokeBorder(isExpanded || (isSelected && !theme.isDark) ? theme.border.strong : theme.border.default, lineWidth: theme.stroke.default)
                .allowsHitTesting(false)
        )
        .clipShape(shape)
        .contentShape(shape)
        .textSelection(.disabled)
        .onHover { hovering in withAnimation(theme.motion.quick) { isHovered = hovering } }
        .overlayPreferenceValue(WorkflowRowActionBounds.self) { anchors in
            GeometryReader { geometry in
                WorkflowRowCursorRegions(pointerRects: anchors.map { geometry[$0] })
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .assignedContextMenu(menuItems: actions)
    }

    private var titleText: some View {
        Text(verbatim: title).textStyle(.body)
            .foregroundStyle(isDraft ? theme.text.secondary : theme.text.primary)
            .lineLimit(1)
    }

    private var header: some View {
        HStack(spacing: theme.space.s12) {
            Button(action: onOpen) {
                HStack(spacing: theme.space.s8) {
                    if isExpandable {
                        Image(systemName: "chevron.right")
                            .glyphSize(.tiny, weight: .semibold)
                            .foregroundStyle(theme.text.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .accessibilityHidden(true)
                    }
                    leading()
                    // The summary goes before it shrinks to a letter or two.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: theme.space.s12) {
                            titleText.layoutPriority(1)
                            Text(verbatim: summary).textStyle(.caption).foregroundStyle(theme.text.tertiary)
                                .lineLimit(1).truncationMode(.tail)
                                .frame(
                                    minWidth: theme.space.s48 * 2, idealWidth: theme.space.s48 * 2, maxWidth: .infinity,
                                    alignment: .leading)
                        }
                        titleText
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .assignedBasePlainButtonStyle()
            .assignedBaseKeyboardButton(
                14, focusRequest: keyboard.focusRequest, onFocusRequestHandled: keyboard.onFocusHandled,
                action: onOpen)
            .onKeyPress(.return) {
                onOpen()
                return .handled
            }
            .onKeyPress(.downArrow) { move(1) }
            .onKeyPress(.upArrow) { move(-1) }
            .accessibilityLabel(Text(verbatim: summary.isEmpty ? title : "\(title), \(summary)"))
            .accessibilityValue(isExpandable ? Text(isExpanded ? "Expanded" : "Collapsed", bundle: .module) : Text(verbatim: ""))
            meta()
            accessory()
                .anchorPreference(key: WorkflowRowActionBounds.self, value: .bounds) { isDraft ? [] : [$0] }
            SettingsActionMenu(accessibilityLabel: L("Workflow actions"), content: actions) {
                Image(systemName: "ellipsis")
            }
            .buttonStyle(SettingsIconButtonStyle(size: .extraSmall, role: .tertiary))
            .fixedSize()
            .opacity(isHovered || isExpanded || isSelected ? 1 : 0.55)
            .anchorPreference(key: WorkflowRowActionBounds.self, value: .bounds) { [$0] }
            .help(L("Workflow actions"))
        }
        .padding(.vertical, theme.space.s12)
        .padding(.leading, theme.space.s16)
        .padding(.trailing, theme.space.s12)
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard let onMove = keyboard.onMove else { return .ignored }
        onMove(delta)
        return .handled
    }

    /// Arrow keys move between the rows of its list.
    func keyboard(_ keyboard: WorkflowRowKeyboard) -> Self {
        var copy = self
        copy.keyboard = keyboard
        return copy
    }
}

/// How a row joins its list's keyboard navigation: ↑/↓ ask the list to
/// focus a neighbour, which it does by raising that row's `focusRequest`.
struct WorkflowRowKeyboard {
    var focusRequest = 0
    var onMove: ((Int) -> Void)? = nil
    var onFocusHandled: () -> Void = {}
}

/// The row a list wants focused next, and a serial so asking twice for the
/// same row still moves focus.
struct WorkflowRowFocusRequest: Equatable {
    let id: UUID
    let serial: Int

    /// The keyboard wiring for row `id` in `ids`, in list order.
    static func keyboard(
        for id: UUID, in ids: [UUID], current: Binding<WorkflowRowFocusRequest?>
    ) -> WorkflowRowKeyboard {
        WorkflowRowKeyboard(
            focusRequest: current.wrappedValue?.id == id ? current.wrappedValue?.serial ?? 0 : 0,
            onMove: { delta in
                guard let next = neighbour(of: id, in: ids, delta: delta) else { return }
                current.wrappedValue = WorkflowRowFocusRequest(id: next, serial: (current.wrappedValue?.serial ?? 0) + 1)
            },
            onFocusHandled: { current.wrappedValue = nil })
    }

    static func neighbour(of id: UUID, in ids: [UUID], delta: Int) -> UUID? {
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + delta) else { return nil }
        return ids[index + delta]
    }
}

extension WorkflowHomepageRow where Leading == EmptyView, Meta == EmptyView, Expanded == EmptyView {
    init(
        title: String, summary: String, isDraft: Bool = false, onOpen: @escaping () -> Void,
        @ViewBuilder accessory: @escaping () -> Accessory, @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.init(
            title: title, summary: summary, isDraft: isDraft, onOpen: onOpen,
            leading: { EmptyView() }, meta: { EmptyView() }, accessory: accessory, actions: actions,
            expanded: { EmptyView() })
    }
}

extension WorkflowHomepageRow where Leading == EmptyView, Expanded == EmptyView {
    init(
        title: String, summary: String, isDraft: Bool = false, isSelected: Bool = false,
        onOpen: @escaping () -> Void,
        @ViewBuilder meta: @escaping () -> Meta,
        @ViewBuilder accessory: @escaping () -> Accessory, @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.init(
            title: title, summary: summary, isDraft: isDraft, isSelected: isSelected, onOpen: onOpen,
            leading: { EmptyView() }, meta: meta, accessory: accessory, actions: actions,
            expanded: { EmptyView() })
    }
}

/// A list row drawn again only when `key` changes. The Workflows lists
/// rebuild on every run update; `key` holds everything the row shows, so
/// rows that update leaves alone skip their work. Closures are left out of
/// `==`: they capture the same stores and state an older row already holds.
struct WorkflowRowSnapshot<Key: Equatable & Sendable, Content: View>: View, Equatable {
    let key: Key
    let content: () -> Content

    init(key: Key, @ViewBuilder content: @escaping () -> Content) {
        self.key = key
        self.content = content
    }

    var body: some View { content() }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
}

/// The parts of a `WorkflowHomepageRow` a card fills in around its own
/// menu.
struct WorkflowRowParts {
    /// Replaces the workflow's summary beside its name.
    var summary: String? = nil
    var isExpandable = false
    var isExpanded = false
    var isSelected = false
    var leading = AnyView(EmptyView())
    var meta = AnyView(EmptyView())
    var accessory = AnyView(EmptyView())
    var expanded = AnyView(EmptyView())
    var keyboard = WorkflowRowKeyboard()
}

/// One cursor owner for the row, avoiding nested push/pop hover callbacks and
/// inherited selectable-text cursor rectangles over the trailing actions.
private struct WorkflowRowActionBounds: PreferenceKey {
    static let defaultValue: [Anchor<CGRect>] = []
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

private struct WorkflowRowCursorRegions: NSViewRepresentable {
    let pointerRects: [CGRect]
    func makeNSView(context: Context) -> CursorView { CursorView() }
    func updateNSView(_ view: CursorView, context: Context) {
        guard view.pointerRects != pointerRects else { return }
        view.pointerRects = pointerRects
        view.window?.invalidateCursorRects(for: view)
    }
    final class CursorView: NSView {
        var pointerRects: [CGRect] = []
        private var tracking: NSTrackingArea?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .arrow)
            for rect in pointerRects {
                let clipped = rect.intersection(bounds)
                if !clipped.isEmpty { addCursorRect(clipped, cursor: .pointingHand) }
            }
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero,
                options: [.cursorUpdate, .mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                owner: self, userInfo: nil)
            addTrackingArea(area); tracking = area
        }
        private func updateCursor(_ event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            (pointerRects.contains { $0.contains(point) } ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
        override func cursorUpdate(with event: NSEvent) { updateCursor(event) }
        override func mouseEntered(with event: NSEvent) { updateCursor(event) }
        override func mouseMoved(with event: NSEvent) { updateCursor(event) }
        override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
    }
}
