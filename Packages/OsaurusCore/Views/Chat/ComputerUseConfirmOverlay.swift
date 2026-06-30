//
//  ComputerUseConfirmOverlay.swift
//  OsaurusCore — Computer Use
//
//  The bottom-pinned confirmation card the Computer Use loop awaits when its
//  per-action gate asks for approval (or cloud-vision consent). This is the
//  one piece of the Computer Use legibility surface that stays computer-use
//  specific — the streaming activity list is now the shared `SubagentFeedView`
//  bound by `SubagentFeedRegistry`, since `computer_use` runs on the shared
//  `SubagentSession` host like every other subagent.
//

import Combine
import SwiftUI

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

                if let script = preview.scriptBody, !script.isEmpty {
                    scriptField(script)
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

    /// The generated AppleScript shown on the confirm card, in a scrollable
    /// monospaced block so the user reads exactly what will run before
    /// approving. Bounded in height so a long script doesn't push the buttons
    /// off-screen.
    @ViewBuilder
    private func scriptField(_ script: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Script", bundle: .module)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
            ScrollView {
                Text(script)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
            }
            .frame(maxHeight: 160)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.tertiaryBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8).stroke(theme.inputBorder, lineWidth: 1)
                    )
            )
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
