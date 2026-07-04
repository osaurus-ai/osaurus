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
    /// Wall-clock the run finished at, captured the moment status flips to
    /// `.finished`, so the header timer freezes on a stable final duration.
    @Published private(set) var finishedAt: Date?

    let toolCallId: String
    let kindId: String
    let title: String
    /// When the run started — the anchor for the live elapsed timer.
    let startedAt: Date

    private var cancellables: Set<AnyCancellable> = []

    init(feed: SubagentFeed) {
        self.toolCallId = feed.toolCallId
        self.kindId = feed.kindId
        self.title = feed.title
        self.startedAt = feed.startedAt
        let initialEvents = feed.currentEvents()
        let initialStatus = feed.currentStatus()
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

/// Live activity feed for one subagent run.
struct SubagentFeedView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @StateObject private var observer: SubagentFeedObserver

    private var theme: ThemeProtocol { themeManager.currentTheme }

    init(feed: SubagentFeed) {
        _observer = StateObject(wrappedValue: SubagentFeedObserver(feed: feed))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(theme.cardBorder)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if observer.truncatedEventCount > 0 {
                            truncationRow(observer.truncatedEventCount)
                        }
                        ForEach(observer.events) { event in
                            eventRow(event).id(event.id)
                        }
                    }
                    .padding(10)
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
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    /// Human label for the run header, sourced from the kind's capability
    /// descriptor (SSOT) so the feed header and the collapsed tool chip agree.
    private var kindLabel: String {
        SubagentCapabilityRegistry.displayLabel(forKindId: observer.kindId) ?? "Subagent"
    }

    private var header: some View {
        HStack(spacing: 8) {
            statusIndicator
            VStack(alignment: .leading, spacing: 1) {
                Text(kindLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(headerSubtitle)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
            }
            Spacer()
            elapsedLabel
            if observer.isRunning {
                Button(action: { observer.stop() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.fill").font(.system(size: 9))
                        Text("Stop", bundle: .module).font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(theme.errorColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(theme.errorColor.opacity(0.12))
                    )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
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
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(theme.tertiaryText)
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
            ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
        case .finished(let success, _):
            Image(systemName: success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 13))
                .foregroundColor(success ? theme.successColor : theme.warningColor)
        }
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
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "ellipsis")
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .frame(width: 16)
            Text("\(count) earlier steps", bundle: .module)
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)
            Spacer(minLength: 0)
        }
    }

    private func eventRow(_ event: SubagentActivityEvent) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: event.iconName)
                .font(.system(size: 11))
                .foregroundColor(color(for: event))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = event.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if event.kind == .progress, let fraction = event.fraction {
                    ProgressView(value: max(0, min(1, fraction)))
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 160)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func color(for event: SubagentActivityEvent) -> Color {
        if let success = event.success {
            return success ? theme.successColor : theme.warningColor
        }
        switch event.kind {
        case .blocked, .denied, .error: return theme.errorColor
        case .confirmRequested: return theme.warningColor
        case .confirmed: return theme.successColor
        default: return theme.accentColor
        }
    }
}
