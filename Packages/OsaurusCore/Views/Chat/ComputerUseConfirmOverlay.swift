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
    @Environment(\.theme) private var environmentTheme
    @ObservedObject private var queue = ComputerUsePromptQueue.shared
    /// Expand the full typed payload (>1 line) for the current confirm card.
    @State private var payloadExpanded = false
    /// When set, Approve also auto-approves similar actions in this app for the run.
    @State private var approveRemaining = false

    private var theme: ThemeProtocol { environmentTheme.catalogFamily(36) }

    var inspectionRequest: ConfirmRequest?
    var inspectionConsent: CloudVisionConsentRequest?
    var inspectionAction: ((String) -> Void)?
    private var isInspectionDisplay: Bool { inspectionAction != nil }

    var body: some View {
        ZStack {
            if let request = inspectionRequest { confirmCard(for: request) }
            else if let consent = inspectionConsent { consentCard(for: consent) }
            else { queuedCard }
        }
        .onChange(of: queue.pending.first?.id) { _, _ in
            payloadExpanded = false
            approveRemaining = false
        }
        // Tell the queue a surface exists that can render its cards. A run
        // whose confirm would otherwise park forever (chat window closed,
        // background dispatch) fails fast with a typed reason instead.
        .onAppear {
            if isInspectionDisplay { return }
            queue.registerPresenter()
        }
        .onDisappear {
            if isInspectionDisplay { return }
            queue.unregisterPresenter()
        }
        .animation(theme.motion.springAnimation, value: queue.pending.first?.id)
        .animation(
            theme.motion.springAnimation,
            value: queue.pendingConsent.first?.id
        )
    }

    @ViewBuilder
    private var queuedCard: some View {
        if let request = queue.pending.first {
            bottomCard { confirmCard(for: request) }
        } else if let consent = queue.pendingConsent.first {
            bottomCard { consentCard(for: consent) }
        }
    }

    @ViewBuilder
    private func bottomCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack {
            Spacer()
            content()
                .padding(.horizontal, theme.catalogLayoutMetric("component.library.36.elements.layout.computerUseConfirmOverlay.bottomCard.paddingX", inheriting: PromptInspectionStyle.metric("padding", theme.space.s16, theme))).catalogLayoutTarget("component.library.36.elements.layout.computerUseConfirmOverlay.bottomCard.paddingX")
                .padding(.bottom, theme.space.s16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Confirm card

    private func confirmCard(for request: ConfirmRequest) -> some View {
        let preview = request.preview
        return cardChrome {
            VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.36.elements.layout.computerUseConfirmOverlay.confirmCard.verticalGap", inheriting: PromptInspectionStyle.metric("gap", theme.space.s12, theme))) {
                HStack(spacing: theme.catalogLayoutMetric("component.library.36.elements.layout.computerUseConfirmOverlay.confirmCard.horizontalGap", inheriting: PromptInspectionStyle.metric("gap", theme.space.s8, theme))) {
                    Image(systemName: "questionmark.circle.fill")
                        .glyphSize(.medium)
                        .foregroundColor(theme.status.warning.foreground)
                    Text("Confirm action", bundle: .module)
                        .promptText(.heading, fallback: .label, weight: 600, theme: theme)
                        .foregroundColor(theme.text.primary)
                    Spacer()
                    effectBadge(preview.effect)
                }.catalogLayoutTarget("component.library.36.elements.layout.computerUseConfirmOverlay.confirmCard.horizontalGap")

                // Structured fields, so the user sees exactly app / action /
                // target / payload rather than one truncated line.
                VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.36.elements.layout.computerUseConfirmOverlay.confirmCard.verticalGap2", inheriting: PromptInspectionStyle.metric("gap", theme.space.s6, theme))) {
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
                }.catalogLayoutTarget("component.library.36.elements.layout.computerUseConfirmOverlay.confirmCard.verticalGap2")

                if let script = preview.scriptBody, !script.isEmpty {
                    scriptField(script)
                }

                if let note = preview.note, !note.isEmpty {
                    Text(note)
                        .promptText(.body, fallback: .footnote, theme: theme)
                        .foregroundColor(theme.text.tertiary)
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
                        .promptText(.body, fallback: .footnote, theme: theme)
                        .foregroundColor(theme.text.secondary)
                    }
                    .settingsSwitch(showsLabel: true)
                }

                HStack(spacing: theme.catalogLayoutMetric("component.library.36.elements.layout.computerUseConfirmOverlay.confirmCard.horizontalGap2", inheriting: PromptInspectionStyle.metric("gap", theme.space.s10, theme))) {
                    Spacer()
                    secondaryButton(L("Deny")) {
                        if let inspectionAction { inspectionAction("Deny"); return }
                        queue.resolve(id: request.id, approved: false)
                    }
                    primaryButton(L("Allow")) {
                        if let inspectionAction { inspectionAction(approveRemaining ? "Allow similar · local callback" : "Allow · local callback"); return }
                        if approveRemaining {
                            queue.resolveApprovingRest(id: request.id)
                        } else {
                            queue.resolve(id: request.id, approved: true)
                        }
                    }
                }.catalogLayoutTarget("component.library.36.elements.layout.computerUseConfirmOverlay.confirmCard.horizontalGap2")
            }.catalogLayoutTarget("component.library.36.elements.layout.computerUseConfirmOverlay.confirmCard.verticalGap")
        }
    }

    @ViewBuilder
    private func field(label: String, value: String, prominent: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.catalogLayoutMetric("component.library.36.elements.layout.computerUseConfirmOverlay.field.horizontalGap", inheriting: PromptInspectionStyle.metric("gap", theme.space.s8, theme))) {
            Text(label)
                .promptText(.caption, fallback: .micro, weight: 600, theme: theme)
                .foregroundColor(theme.text.tertiary)
                .frame(width: 52, alignment: .leading)
            Text(value)
                .promptText(prominent ? .label : .body, fallback: prominent ? .label : .caption, theme: theme)
                .foregroundColor(prominent ? theme.text.primary : theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }.catalogLayoutTarget("component.library.36.elements.layout.computerUseConfirmOverlay.field.horizontalGap")
    }

    @ViewBuilder
    private func typedTextField(_ text: String) -> some View {
        let isLong = text.count > 40
        let shown = (isLong && !payloadExpanded) ? String(text.prefix(40)) + "…" : text
        VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.36.elements.layout.computerUseConfirmOverlay.typedTextField.verticalGap", inheriting: PromptInspectionStyle.metric("gap", theme.space.s4, theme))) {
            HStack(alignment: .firstTextBaseline, spacing: theme.catalogLayoutMetric("component.library.36.elements.layout.computerUseConfirmOverlay.typedTextField.horizontalGap", inheriting: PromptInspectionStyle.metric("gap", theme.space.s8, theme))) {
                Text("Text", bundle: .module)
                    .promptText(.caption, fallback: .micro, weight: 600, theme: theme)
                    .foregroundColor(theme.text.tertiary)
                    .frame(width: 52, alignment: .leading)
                Text(shown)
                    .promptText(.code, fallback: .code, theme: theme)
                    .foregroundColor(theme.text.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }.catalogLayoutTarget("component.library.36.elements.layout.computerUseConfirmOverlay.typedTextField.horizontalGap")
            if isLong {
                Button(action: { payloadExpanded.toggle() }) {
                    Text(payloadExpanded ? L("Show less") : L("Show full text"))
                        .promptText(.caption, fallback: .micro, weight: 500, theme: theme)
                        .foregroundColor(theme.text.link)
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.leading, theme.space.s64)
            }
        }.catalogLayoutTarget("component.library.36.elements.layout.computerUseConfirmOverlay.typedTextField.verticalGap")
    }

    /// The generated AppleScript shown on the confirm card, in a scrollable
    /// monospaced block so the user reads exactly what will run before
    /// approving. Bounded in height so a long script doesn't push the buttons
    /// off-screen.
    @ViewBuilder
    private func scriptField(_ script: String) -> some View {
        VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.36.elements.layout.computerUseConfirmOverlay.scriptField.verticalGap", inheriting: PromptInspectionStyle.metric("gap", theme.space.s4, theme))) {
            Text("Script", bundle: .module)
                .promptText(.caption, fallback: .micro, weight: 600, theme: theme)
                .foregroundColor(theme.text.tertiary)
            ScrollView {
                Text(script)
                    .promptText(.code, fallback: .footnote, family: .code, theme: theme)
                    .foregroundColor(theme.text.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, theme.catalogLayoutMetric("component.library.36.elements.layout.computerUseConfirmOverlay.scriptField.padding.horizontal", inheriting: PromptInspectionStyle.metric("padding", theme.space.s8, theme))).padding(.vertical, theme.catalogLayoutMetric("component.library.36.elements.layout.computerUseConfirmOverlay.scriptField.padding.vertical", inheriting: PromptInspectionStyle.metric("padding", theme.space.s8, theme))).catalogLayoutTarget("component.library.36.elements.layout.computerUseConfirmOverlay.scriptField.padding.horizontal").catalogLayoutTarget("component.library.36.elements.layout.computerUseConfirmOverlay.scriptField.padding.vertical")
            }
            .frame(maxHeight: 160)
            .background(
                RoundedRectangle(cornerRadius: theme.radius.medium)
                    .fill(theme.surface.hover)
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.radius.medium).stroke(theme.border.default, lineWidth: theme.stroke.default)
                    )
            )
        }.catalogLayoutTarget("component.library.36.elements.layout.computerUseConfirmOverlay.scriptField.verticalGap")
    }

    // MARK: Consent card

    private func consentCard(for request: CloudVisionConsentRequest) -> some View {
        cardChrome {
            VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.36.elements.layout.computerUseConfirmOverlay.consentCard.verticalGap", inheriting: PromptInspectionStyle.metric("gap", theme.space.s12, theme))) {
                HStack(spacing: theme.catalogLayoutMetric("component.library.36.elements.layout.computerUseConfirmOverlay.consentCard.horizontalGap", inheriting: PromptInspectionStyle.metric("gap", theme.space.s8, theme))) {
                    Image(systemName: "eye.trianglebadge.exclamationmark")
                        .glyphSize(.medium)
                        .foregroundColor(theme.status.info.foreground)
                    Text("Use Cloud vision?", bundle: .module)
                        .promptText(.heading, fallback: .label, weight: 600, theme: theme)
                        .foregroundColor(theme.text.primary)
                    Spacer()
                }.catalogLayoutTarget("component.library.36.elements.layout.computerUseConfirmOverlay.consentCard.horizontalGap")
                Text(
                    "A screenshot would help here, but this agent uses a cloud model. Osaurus masks sensitive text on-device first, then sends the redacted image. Screenshots need Screen Recording permission.",
                    bundle: .module
                )
                .promptText(.caption, fallback: .caption, theme: theme)
                .foregroundColor(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: theme.catalogLayoutMetric("component.library.36.elements.layout.computerUseConfirmOverlay.consentCard.horizontalGap2", inheriting: PromptInspectionStyle.metric("gap", theme.space.s10, theme))) {
                    Spacer()
                    secondaryButton(L("Not now")) {
                        if let inspectionAction { inspectionAction("Not now · local callback"); return }
                        queue.resolveConsent(id: request.id, choice: .deny)
                    }
                    secondaryButton(L("Allow once")) {
                        if let inspectionAction { inspectionAction("Allow once · local callback"); return }
                        queue.resolveConsent(id: request.id, choice: .allowOnce)
                    }
                    primaryButton(L("Always allow")) {
                        if let inspectionAction { inspectionAction("Always allow · local callback"); return }
                        queue.resolveConsent(id: request.id, choice: .allowAlways)
                    }
                }.catalogLayoutTarget("component.library.36.elements.layout.computerUseConfirmOverlay.consentCard.horizontalGap2")
            }.catalogLayoutTarget("component.library.36.elements.layout.computerUseConfirmOverlay.consentCard.verticalGap")
        }
    }

    // MARK: Shared chrome

    @ViewBuilder
    private func cardChrome<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, theme.catalogLayoutMetric("component.library.36.elements.layout.computerUseConfirmOverlay.cardChrome.padding.horizontal", inheriting: PromptInspectionStyle.metric("padding", theme.space.s16, theme))).padding(.vertical, theme.catalogLayoutMetric("component.library.36.elements.layout.computerUseConfirmOverlay.cardChrome.padding.vertical", inheriting: PromptInspectionStyle.metric("padding", theme.space.s16, theme))).catalogLayoutTarget("component.library.36.elements.layout.computerUseConfirmOverlay.cardChrome.padding.horizontal").catalogLayoutTarget("component.library.36.elements.layout.computerUseConfirmOverlay.cardChrome.padding.vertical")
            .frame(minHeight: PromptInspectionStyle.metric("height", 0, theme))
            .environment(\.theme, theme)
            .assignedBaseChrome(36, fallback: .overlay)
            .frame(maxWidth: 420)
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .assignedSettingsButtonStyle(.secondary, size: .compact)
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .assignedSettingsButtonStyle(.primary, size: .compact)
    }

    private func effectBadge(_ effect: EffectClass) -> some View {
        StatusChip(effect.displayLabel.uppercased(), tone: .warning)
            .environment(\.theme, PromptInspectionStyle.badgeTheme(environmentTheme))
    }
}

extension ComputerUseConfirmOverlay {
    @MainActor static func inspectionCard(consent: Bool, onAction: @escaping (String) -> Void = { _ in }) -> some View {
        var renderer = ComputerUseConfirmOverlay()
        renderer.inspectionAction = onAction
        if consent {
            renderer.inspectionConsent = .init(toolCallId: "inspector-display-only")
        } else {
            renderer.inspectionRequest = .init(toolCallId: "inspector-display-only", preview: .init(
                appName: "Local sample", actionLabel: "Review sample text", targetLabel: "Sample field",
                effect: .edit, note: "Display only. No pending action exists.",
                typedText: "A longer local text sample for checking the original payload presentation.",
                scriptBody: "-- Display only; never executed\nreturn \"Sample\""))
        }
        return renderer
    }
}
