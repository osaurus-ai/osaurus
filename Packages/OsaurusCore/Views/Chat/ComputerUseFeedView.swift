//
//  ComputerUseFeedView.swift
//  OsaurusCore — Computer Use
//
//  The inline legibility surface for a Computer Use run. Mounted in the
//  expanded `computer_use` tool-call row (via NSHostingView) and bound to
//  the run's `ComputerUseFeed`, it streams every perceive / propose / gate
//  / act / verify step as the agent works, with a Stop control that trips
//  the run's interrupt token. Also hosts the bottom-pinned confirmation
//  card the loop awaits when the gate asks for approval.
//

import Combine
import SwiftUI

/// Bridges a Combine-backed `ComputerUseFeed` into SwiftUI observation.
@MainActor
final class ComputerUseFeedObserver: ObservableObject {
    @Published private(set) var events: [FeedEvent] = []
    @Published private(set) var status: FeedStatus = .running

    let toolCallId: String
    let goal: String

    private var cancellables: Set<AnyCancellable> = []

    init(feed: ComputerUseFeed) {
        self.toolCallId = feed.toolCallId
        self.goal = feed.goal
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
        // Trip the interrupt token AND resolve any pending prompts. The loop only
        // polls the token between iterations, so while it's suspended on a confirm
        // (or consent) card the token alone wouldn't unblock it — denying the
        // pending prompts lets the loop advance one step and then see the token.
        ComputerUseInterruptCenter.shared.interrupt(toolCallId)
        ComputerUsePromptQueue.shared.cancelAll(forToolCallId: toolCallId)
    }
}

/// Live activity feed for one Computer Use run.
struct ComputerUseFeedView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @StateObject private var observer: ComputerUseFeedObserver

    private var theme: ThemeProtocol { themeManager.currentTheme }

    init(feed: ComputerUseFeed) {
        _observer = StateObject(wrappedValue: ComputerUseFeedObserver(feed: feed))
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

    private var header: some View {
        HStack(spacing: 8) {
            statusIndicator
            VStack(alignment: .leading, spacing: 1) {
                Text("Computer Use", bundle: .module)
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
        case .running: return observer.goal
        case .finished(_, let summary): return summary
        }
    }

    private func eventRow(_ event: FeedEvent) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: event.iconName)
                .font(.system(size: 11))
                .foregroundColor(color(for: event))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
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
            }
            Spacer(minLength: 0)
        }
    }

    private func color(for event: FeedEvent) -> Color {
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

// MARK: - Confirmation overlay

/// Bottom-pinned prompt card driven by `ComputerUsePromptQueue`. Shows the
/// first pending gated action (confirm) or cloud-vision consent request and
/// resolves the loop's awaiting continuation.
struct ComputerUseConfirmOverlay: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var queue = ComputerUsePromptQueue.shared
    /// Expand the full typed payload (>1 line) for the current confirm card.
    @State private var payloadExpanded = false
    /// When set, Approve also auto-approves similar actions in this app for the run.
    @State private var approveRemaining = false

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        ZStack {
            if let request = queue.pending.first {
                bottomCard { confirmCard(for: request) }
            } else if let consent = queue.pendingConsent.first {
                bottomCard { consentCard(for: consent) }
            }
        }
        .onChange(of: queue.pending.first?.id) { _, _ in
            payloadExpanded = false
            approveRemaining = false
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: queue.pending.first?.id)
        .animation(
            .spring(response: 0.3, dampingFraction: 0.85),
            value: queue.pendingConsent.first?.id
        )
    }

    @ViewBuilder
    private func bottomCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack {
            Spacer()
            content()
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Confirm card

    private func confirmCard(for request: ConfirmRequest) -> some View {
        let preview = request.preview
        return cardChrome {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(theme.warningColor)
                    Text("Confirm action", bundle: .module)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Spacer()
                    effectBadge(preview.effect)
                }

                // Structured fields, so the user sees exactly app / action /
                // target / payload rather than one truncated line.
                VStack(alignment: .leading, spacing: 6) {
                    field(label: L("Action"), value: preview.actionLabel, prominent: true)
                    if let app = preview.appName, !app.isEmpty {
                        field(label: L("App"), value: app)
                    }
                    if let target = preview.targetLabel, !target.isEmpty {
                        field(label: L("Target"), value: target)
                    }
                    if let typed = preview.typedText, !typed.isEmpty {
                        typedTextField(typed)
                    }
                }

                if let note = preview.note, !note.isEmpty {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let app = preview.appName, !app.isEmpty {
                    Toggle(isOn: $approveRemaining) {
                        Text(
                            String(
                                format: L("Don't ask again for similar actions in %@ this run"),
                                app
                            )
                        )
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                    }
                    .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                }

                HStack(spacing: 10) {
                    Spacer()
                    secondaryButton(L("Decline")) {
                        queue.resolve(id: request.id, approved: false)
                    }
                    primaryButton(L("Approve")) {
                        if approveRemaining {
                            queue.resolveApprovingRest(id: request.id)
                        } else {
                            queue.resolve(id: request.id, approved: true)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func field(label: String, value: String, prominent: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
                .frame(width: 52, alignment: .leading)
            Text(value)
                .font(.system(size: prominent ? 13 : 12, weight: prominent ? .medium : .regular))
                .foregroundColor(prominent ? theme.primaryText : theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func typedTextField(_ text: String) -> some View {
        let isLong = text.count > 40
        let shown = (isLong && !payloadExpanded) ? String(text.prefix(40)) + "…" : text
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Text", bundle: .module)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
                    .frame(width: 52, alignment: .leading)
                Text(shown)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if isLong {
                Button(action: { payloadExpanded.toggle() }) {
                    Text(payloadExpanded ? L("Show less") : L("Show full text"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.accentColor)
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.leading, 60)
            }
        }
    }

    // MARK: Consent card

    private func consentCard(for request: CloudVisionConsentRequest) -> some View {
        cardChrome {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "eye.trianglebadge.exclamationmark")
                        .font(.system(size: 16))
                        .foregroundColor(theme.accentColor)
                    Text("Use Cloud vision?", bundle: .module)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Spacer()
                }
                Text(
                    "A screenshot would help here, but this agent uses a cloud model. Osaurus masks sensitive text on-device first, then sends the redacted image. Screenshots need Screen Recording permission.",
                    bundle: .module
                )
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Spacer()
                    secondaryButton(L("Not now")) {
                        queue.resolveConsent(id: request.id, choice: .deny)
                    }
                    secondaryButton(L("Allow once")) {
                        queue.resolveConsent(id: request.id, choice: .allowOnce)
                    }
                    primaryButton(L("Always allow")) {
                        queue.resolveConsent(id: request.id, choice: .allowAlways)
                    }
                }
            }
        }
    }

    // MARK: Shared chrome

    @ViewBuilder
    private func cardChrome<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(theme.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14).stroke(theme.cardBorder, lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.2), radius: 16, y: 6)
            )
            .frame(maxWidth: 420)
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.tertiaryBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8).stroke(theme.inputBorder, lineWidth: 1)
                        )
                )
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(theme.accentColor))
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func effectBadge(_ effect: EffectClass) -> some View {
        Text(effect.displayLabel.uppercased())
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(theme.warningColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(theme.warningColor.opacity(0.12)))
    }
}
