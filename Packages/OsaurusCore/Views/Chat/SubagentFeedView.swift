//
//  SubagentFeedView.swift
//  OsaurusCore — Subagent framework
//
//  The unified inline legibility surface for ANY nested sub-agent run
//  (spawn, image, computer_use). Mounted in the expanded
//  sub-agent tool-call row (via NSHostingView) and bound to the run's
//  `SubagentFeed`, it streams each lifecycle / progress / activity event as
//  the sub-agent works, with a Stop control that trips the run's interrupt
//  token via `SubagentInterruptCenter`.
//
//  Generalized from the old Computer Use activity list so the four
//  sub-agent paths render one consistent surface. The per-action
//  confirmation overlay stays computer-use specific (it depends on the
//  ComputerUse gate) and is hosted separately.
//

import Combine
import SwiftUI

/// Bridges a Combine-backed `SubagentFeed` into SwiftUI observation.
@MainActor
final class SubagentFeedObserver: ObservableObject {
    @Published private(set) var events: [SubagentActivityEvent] = []
    @Published private(set) var status: SubagentRunStatus = .running

    let toolCallId: String
    let kindId: String
    let title: String

    private var cancellables: Set<AnyCancellable> = []

    init(feed: SubagentFeed) {
        self.toolCallId = feed.toolCallId
        self.kindId = feed.kindId
        self.title = feed.title
        self.events = feed.currentEvents()
        self.status = feed.currentStatus()
        feed.eventsPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.events = $0 }
            .store(in: &cancellables)
        feed.statusPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.status = $0 }
            .store(in: &cancellables)
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

/// Live activity feed for one sub-agent run.
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
                        ForEach(observer.events) { event in
                            eventRow(event).id(event.id)
                        }
                    }
                    .padding(10)
                }
                .onChange(of: observer.events.count) { _, _ in
                    if let last = observer.events.last {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
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
