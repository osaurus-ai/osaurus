//
//  SubagentFeedView.swift
//  OsaurusCore — Subagent framework
//
//  The unified inline legibility surface for ANY nested subagent run
//  (spawn, image, computer_use). Mounted in the expanded
//  subagent tool-call row (via NSHostingView) and bound to the run's
//  `SubagentFeed`, it streams each lifecycle / progress / activity event as
//  the subagent works, with a Stop control that trips the run's interrupt
//  token via `SubagentInterruptCenter`.
//
//  Generalized from the old Computer Use activity list so the four
//  subagent paths render one consistent surface. The per-action
//  confirmation overlay stays computer-use specific (it depends on the
//  ComputerUse gate) and is hosted separately.
//

import Combine
import SwiftUI

/// Bridges a Combine-backed `SubagentFeed` into SwiftUI observation.
///
/// The bridge is deliberately lossy in two ways, both hang guards: the
/// event stream is throttled (a chatty run can emit many events per
/// second, and every published snapshot invalidates the whole `ForEach`),
/// and only a bounded tail of the history is exposed to the view — the
/// feed itself is unbounded, and laying out thousands of rows in the
/// pane's `LazyVStack` (each one a glass card the auto-scroll forces to
/// materialize) is a multi-second main-thread layout pass.
@MainActor
final class SubagentFeedObserver: ObservableObject {
    /// Upper bound on rows handed to the view. Old events beyond the tail
    /// are dropped from RENDERING only; `SubagentFeed` keeps the full log.
    static let maxRenderedEvents = 200

    /// Interval snapshots are coalesced to before touching SwiftUI.
    static let publishInterval: TimeInterval = 0.1

    @Published private(set) var events: [SubagentActivityEvent] = []
    /// How many older events were trimmed from `events`, so the view can
    /// say "N earlier steps" instead of silently starting mid-run.
    @Published private(set) var truncatedEventCount = 0
    @Published private(set) var status: SubagentRunStatus = .running
    /// The delegated child's persisted chat session id, once the true-
    /// delegation dispatcher created it. Drives the card's "Open Chat"
    /// affordance. Refreshed on event ticks — `setDelegatedSessionId`
    /// republishes the event snapshot exactly so late subscribers see it.
    @Published private(set) var delegatedSessionId: UUID?
    /// Wall-clock the run finished at, captured the moment status flips to
    /// `.finished`, so the header timer freezes on a stable final duration.
    @Published private(set) var finishedAt: Date?

    let toolCallId: String
    let kindId: String
    let title: String
    /// When the run started — the anchor for the live elapsed timer.
    let startedAt: Date

    private var cancellables: Set<AnyCancellable> = []
    private let feed: SubagentFeed

    init(feed: SubagentFeed) {
        self.feed = feed
        self.toolCallId = feed.toolCallId
        self.kindId = feed.kindId
        self.title = feed.title
        self.startedAt = feed.startedAt
        let initialEvents = feed.currentEvents()
        let initialStatus = feed.currentStatus()
        self.delegatedSessionId = feed.delegatedSessionId.flatMap(UUID.init(uuidString:))
        self.apply(initialEvents)
        self.status = initialStatus
        if case .finished = initialStatus {
            // Mounted after the run already finished (grace-tail replay):
            // approximate the finish time from the last emitted event so the
            // frozen timer is sane rather than "now − startedAt".
            self.finishedAt = initialEvents.last?.timestamp ?? feed.startedAt
        }
        feed.eventsPublisher
            .throttle(
                for: .seconds(Self.publishInterval),
                scheduler: RunLoop.main,
                latest: true
            )
            .sink { [weak self] in self?.apply($0) }
            .store(in: &cancellables)
        feed.statusPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self else { return }
                self.status = status
                if case .finished = status, self.finishedAt == nil {
                    self.finishedAt = Date()
                }
            }
            .store(in: &cancellables)
    }

    /// Window a full-history snapshot down to the rendered tail.
    private func apply(_ snapshot: [SubagentActivityEvent]) {
        let overflow = snapshot.count - Self.maxRenderedEvents
        if overflow > 0 {
            truncatedEventCount = overflow
            events = Array(snapshot.suffix(Self.maxRenderedEvents))
        } else {
            truncatedEventCount = 0
            events = snapshot
        }
        if delegatedSessionId == nil,
            let id = feed.delegatedSessionId.flatMap(UUID.init(uuidString:))
        {
            delegatedSessionId = id
        }
    }

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    func stop() {
        // Trip the interrupt token AND resolve any pending computer-use prompts
        // (no-op for kinds without a gate). The loop polls the token between
        // boundaries; resolving prompts lets a suspended computer-use loop
        // advance one step and then see the token.
        SubagentInterruptCenter.shared.interrupt(toolCallId)
        ComputerUsePromptQueue.shared.cancelAll(forToolCallId: toolCallId)
    }
}

/// Supplies the app theme to the feed hosted outside SwiftUI in a chat row.
struct HostedSubagentFeedView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let feed: SubagentFeed

    var body: some View {
        SubagentFeedView(feed: feed)
            .environment(\.theme, themeManager.currentTheme)
    }
}

/// Live activity feed for one subagent run.
struct SubagentFeedView: View {
    @Environment(\.theme) private var baseTheme
    @StateObject private var observer: SubagentFeedObserver
    @State private var expandedEvents: Set<UUID> = []

    private var theme: ThemeProtocol { baseTheme.catalogFamily(35, authoritative: true) }

    init(feed: SubagentFeed) {
        _observer = StateObject(wrappedValue: SubagentFeedObserver(feed: feed))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(theme.border.subtle).frame(height: AgentProgressInspectionStyle.metric("borderWidth", ThemeStrokes.hairline(forBackingScale: NSScreen.main?.backingScaleFactor ?? 2), theme))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.35.elements.layout.subagentFeedView.body.verticalGap", inheriting: AgentProgressInspectionStyle.metric("gap", 6, theme))) {
                        if observer.truncatedEventCount > 0 {
                            truncationRow(observer.truncatedEventCount)
                        }
                        ForEach(observer.events) { event in
                            eventRow(event).id(event.id)
                        }
                    }.catalogLayoutTarget("component.library.35.elements.layout.subagentFeedView.body.verticalGap")
                    .padding(.horizontal, theme.catalogLayoutMetric("component.library.35.elements.layout.subagentFeedView.body.padding.horizontal", inheriting: AgentProgressInspectionStyle.metric("padding", 10, theme))).padding(.vertical, theme.catalogLayoutMetric("component.library.35.elements.layout.subagentFeedView.body.padding.vertical", inheriting: AgentProgressInspectionStyle.metric("padding", 10, theme))).catalogLayoutTarget("component.library.35.elements.layout.subagentFeedView.body.padding.horizontal").catalogLayoutTarget("component.library.35.elements.layout.subagentFeedView.body.padding.vertical")
                }
                // Follow the tail WITHOUT animation: an animated scroll runs
                // inside a SwiftUI transaction, forcing the lazy stack to lay
                // out every row between here and the target on the main
                // thread — with a long feed that's a visible hang, and a new
                // event can land every publish tick.
                .onChange(of: observer.events.count) { _, _ in
                    if let last = observer.events.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(minHeight: AgentProgressInspectionStyle.metric("height", 0, theme))
        .environment(\.theme, theme)
        .background(
            RoundedRectangle(cornerRadius: theme.radius.medium)
                #if OSAURUS_DESIGN_SYSTEM
                .fill(AgentContentSurfaceAssignments.color(35, "subagentFeed", theme))
                .nativeCatalogTarget([AgentContentSurfaceAssignments.key(35, "subagentFeed")], "Subagent activity feed")
                #else
                .fill(theme.surface.raised)
                #endif
                .overlay(
                    RoundedRectangle(cornerRadius: theme.radius.medium)
                        .stroke(theme.border.subtle, lineWidth: theme.stroke.default)
                )
        )
    }

    /// Human label for the run header, sourced from the kind's capability
    /// descriptor (SSOT) so the feed header and the collapsed tool chip agree.
    private var kindLabel: String {
        if observer.kindId == WorkflowCallFeed.kindId { return L("Workflow") }
        return SubagentCapabilityRegistry.displayLabel(forKindId: observer.kindId) ?? "Subagent"
    }

    private var header: some View {
        HStack(spacing: theme.catalogLayoutMetric("component.library.35.elements.layout.subagentFeedView.header.horizontalGap", inheriting: AgentProgressInspectionStyle.metric("gap", 8, theme))) {
            statusIndicator
            VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.35.elements.layout.subagentFeedView.header.verticalGap", inheriting: AgentProgressInspectionStyle.metric("gap", 1, theme))) {
                Text(kindLabel)
                    .agentProgressText(.heading, fallback: .footnote, weight: 600, theme: theme)
                    .foregroundColor(theme.text.primary)
                // A failed run's reason is the one thing the user needs from
                // this header, so it gets warning color and room to wrap
                // instead of a single truncated grey line.
                Text(headerSubtitle)
                    .agentProgressText(.caption, fallback: .micro, theme: theme)
                    .foregroundColor(runFailed ? theme.status.warning.foreground : theme.text.tertiary)
                    .lineLimit(runFailed ? 3 : 1)
                    .textSelection(.enabled)
                    .help(headerSubtitle)
            }.catalogLayoutTarget("component.library.35.elements.layout.subagentFeedView.header.verticalGap")
            Spacer()
            elapsedLabel
            if let sessionId = observer.delegatedSessionId {
                Button(action: { Self.openDelegatedChat(sessionId) }) {
                    HStack(spacing: theme.catalogLayoutMetric("component.library.35.elements.layout.subagentFeedView.header.horizontalGap2", inheriting: AgentProgressInspectionStyle.metric("gap", 4, theme))) {
                        Image(systemName: "bubble.left.and.text.bubble.right")
                            .glyphSize(9)
                        Text("Open Chat", bundle: .module)
                            .agentProgressText(.label, fallback: .footnote, weight: 500, theme: theme)
                    }.catalogLayoutTarget("component.library.35.elements.layout.subagentFeedView.header.horizontalGap2")
                    .foregroundColor(theme.status.info.foreground)
                    .padding(.horizontal, theme.catalogLayoutMetric("component.library.35.elements.layout.subagentFeedView.header.paddingX", inheriting: AgentProgressInspectionStyle.metric("padding", 8, theme))).catalogLayoutTarget("component.library.35.elements.layout.subagentFeedView.header.paddingX")
                    .padding(.vertical, theme.catalogLayoutMetric("component.library.35.elements.layout.subagentFeedView.header.paddingY", inheriting: AgentProgressInspectionStyle.metric("padding", 4, theme))).catalogLayoutTarget("component.library.35.elements.layout.subagentFeedView.header.paddingY")
                    .background(
                        Capsule().fill(theme.status.info.background)
                    )
                }
                .buttonStyle(PlainButtonStyle())
                .help(Text("Open the delegated agent's chat session", bundle: .module))
            }
            if observer.isRunning {
                Button(action: { observer.stop() }) {
                    HStack(spacing: theme.catalogLayoutMetric("component.library.35.elements.layout.subagentFeedView.header.horizontalGap3", inheriting: AgentProgressInspectionStyle.metric("gap", 4, theme))) {
                        Image(systemName: "stop.fill").glyphSize(9)
                        Text("Stop", bundle: .module).agentProgressText(.label, fallback: .footnote, weight: 500, theme: theme)
                    }.catalogLayoutTarget("component.library.35.elements.layout.subagentFeedView.header.horizontalGap3")
                    .foregroundColor(theme.status.error.foreground)
                    .padding(.horizontal, theme.catalogLayoutMetric("component.library.35.elements.layout.subagentFeedView.header.paddingX2", inheriting: AgentProgressInspectionStyle.metric("padding", 8, theme))).catalogLayoutTarget("component.library.35.elements.layout.subagentFeedView.header.paddingX2")
                    .padding(.vertical, theme.catalogLayoutMetric("component.library.35.elements.layout.subagentFeedView.header.paddingY2", inheriting: AgentProgressInspectionStyle.metric("padding", 4, theme))).catalogLayoutTarget("component.library.35.elements.layout.subagentFeedView.header.paddingY2")
                    .background(
                        Capsule().fill(theme.status.error.background)
                    )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }.catalogLayoutTarget("component.library.35.elements.layout.subagentFeedView.header.horizontalGap")
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.35.elements.layout.subagentFeedView.header.paddingX3", inheriting: AgentProgressInspectionStyle.metric("padding", 10, theme))).catalogLayoutTarget("component.library.35.elements.layout.subagentFeedView.header.paddingX3")
        .padding(.vertical, theme.catalogLayoutMetric("component.library.35.elements.layout.subagentFeedView.header.paddingY3", inheriting: AgentProgressInspectionStyle.metric("padding", 8, theme))).catalogLayoutTarget("component.library.35.elements.layout.subagentFeedView.header.paddingY3")
    }

    /// Wall-clock readout for the run. While running it ticks ~10x/sec via a
    /// `TimelineView` scoped to just this label (so only it re-renders, not the
    /// whole feed); once finished it freezes at the observed finish time.
    @ViewBuilder
    private var elapsedLabel: some View {
        if observer.isRunning {
            TimelineView(.periodic(from: observer.startedAt, by: 0.1)) { context in
                elapsedText(context.date.timeIntervalSince(observer.startedAt))
            }
        } else if let finishedAt = observer.finishedAt {
            elapsedText(finishedAt.timeIntervalSince(observer.startedAt))
        }
    }

    private func elapsedText(_ elapsed: TimeInterval) -> some View {
        Text(Self.formatElapsed(elapsed))
            .agentProgressText(.code, fallback: .micro, weight: 500, family: .code, theme: theme)
            .foregroundColor(theme.text.tertiary)
    }

    private static func formatElapsed(_ t: TimeInterval) -> String {
        let clamped = max(0, t)
        if clamped < 60 { return String(format: "%.1fs", clamped) }
        return String(format: "%dm %02ds", Int(clamped) / 60, Int(clamped) % 60)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch observer.status {
        case .running:
            ProgressView().tint(theme.status.info.foreground)
                #if OSAURUS_DESIGN_SYSTEM
                .controlSize(.large)
                #endif
                .assignedProgressIndicator(tintOverride: theme.status.info.foreground)
                .scaleEffect(0.5).frame(width: 14, height: 14)
        case .finished(let success, _):
            Image(systemName: success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .glyphSize(13)
                .foregroundColor(success ? theme.status.success.foreground : theme.status.warning.foreground)
        }
    }

    private var runFailed: Bool {
        if case .finished(false, _) = observer.status { return true }
        return false
    }

    private var headerSubtitle: String {
        switch observer.status {
        case .running: return observer.title
        case .finished(_, let summary): return summary.isEmpty ? observer.title : summary
        }
    }

    /// Placeholder for history trimmed by the observer's render window, so a
    /// long run doesn't silently appear to start mid-flight.
    private func truncationRow(_ count: Int) -> some View {
        HStack(alignment: .top, spacing: theme.catalogLayoutMetric("component.library.35.elements.layout.subagentFeedView.truncationRow.horizontalGap", inheriting: AgentProgressInspectionStyle.metric("gap", 8, theme))) {
            Image(systemName: "ellipsis")
                .glyphSize(11)
                .foregroundColor(theme.text.tertiary)
                .frame(width: 16)
            Text(count == 1 ? L("1 earlier step") : L("\(count) earlier steps"))
                .agentProgressText(.caption, fallback: .micro, theme: theme)
                .foregroundColor(theme.text.tertiary)
            Spacer(minLength: 0)
        }.catalogLayoutTarget("component.library.35.elements.layout.subagentFeedView.truncationRow.horizontalGap")
    }

    private func eventRow(_ event: SubagentActivityEvent) -> some View {
        HStack(alignment: .top, spacing: theme.catalogLayoutMetric("component.library.35.elements.layout.subagentFeedView.eventRow.horizontalGap", inheriting: AgentProgressInspectionStyle.metric("gap", 8, theme))) {
            Image(systemName: event.iconName)
                .glyphSize(11)
                .foregroundColor(color(for: event))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.35.elements.layout.subagentFeedView.eventRow.verticalGap", inheriting: AgentProgressInspectionStyle.metric("gap", 2, theme))) {
                Text(event.title)
                    .agentProgressText(.body, fallback: .footnote, theme: theme)
                    .foregroundColor(theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = event.detail, !detail.isEmpty {
                    Text(detail)
                        .agentProgressText(.caption, fallback: .micro, theme: theme)
                        .foregroundColor(theme.text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let text = event.expandableText, !text.isEmpty, expandedEvents.contains(event.id) {
                    Text(text)
                        .agentProgressText(.caption, fallback: .micro, theme: theme)
                        .foregroundColor(theme.text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if event.kind == .progress, let fraction = event.fraction {
                    ProgressView(value: max(0, min(1, fraction)))
                        .progressViewStyle(.linear)
                        .tint(theme.status.info.foreground)
                        .frame(maxWidth: 160)
                }
            }.catalogLayoutTarget("component.library.35.elements.layout.subagentFeedView.eventRow.verticalGap")
            Spacer(minLength: 0)
            if let text = event.expandableText, !text.isEmpty {
                Image(systemName: expandedEvents.contains(event.id) ? "chevron.down" : "chevron.right")
                    .glyphSize(9)
                    .foregroundColor(theme.text.tertiary)
            }
        }.catalogLayoutTarget("component.library.35.elements.layout.subagentFeedView.eventRow.horizontalGap")
        .contentShape(Rectangle())
        .onTapGesture {
            guard let text = event.expandableText, !text.isEmpty else { return }
            if expandedEvents.contains(event.id) {
                expandedEvents.remove(event.id)
            } else {
                expandedEvents.insert(event.id)
            }
        }
    }

    /// Open the delegated child's chat session: attach to the live
    /// background task mid-run (same window-binding path as the Activity section's
    /// Open Chat), else focus an already-open window, else hydrate the
    /// persisted session from the store.
    @MainActor
    static func openDelegatedChat(_ sessionId: UUID) {
        let manager = BackgroundTaskManager.shared
        if let live = manager.liveTask(forSessionId: sessionId) {
            manager.openTaskWindow(live.id)
            return
        }
        // Dispatched runs align task id and session id, and openTaskWindow
        // also rehydrates a retained (dehydrated) terminal tab.
        if manager.isBackgroundTask(sessionId) {
            manager.openTaskWindow(sessionId)
            return
        }
        if let existing = ChatWindowManager.shared.findWindow(bySessionId: sessionId) {
            ChatWindowManager.shared.showWindow(id: existing.id)
            return
        }
        if let sessionData = ChatSessionStore.load(id: sessionId) {
            ChatWindowManager.shared.createWindow(
                agentId: sessionData.agentId,
                sessionData: sessionData
            )
        }
    }

    private func color(for event: SubagentActivityEvent) -> Color {
        if let success = event.success {
            return success ? theme.status.success.foreground : theme.status.warning.foreground
        }
        switch event.kind {
        case .blocked, .denied, .error: return theme.status.error.foreground
        case .confirmRequested: return theme.status.warning.foreground
        case .confirmed: return theme.status.success.foreground
        case .reasoning: return theme.text.tertiary
        case .response: return theme.text.primary
        default: return theme.status.info.foreground
        }
    }
}
