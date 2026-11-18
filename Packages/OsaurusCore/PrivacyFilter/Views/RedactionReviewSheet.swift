//
//  RedactionReviewSheet.swift
//  osaurus / PrivacyFilter
//
//  Modal presented before a cloud send when the pipeline found items
//  that need a person to decide. Compact by default: one list grouped
//  by where each item came from (your message, a tool result, the
//  model's own text), a short preview under the selected row, and a
//  footer that sets how the rest of the conversation behaves. "Show
//  full message" opens the side-by-side outgoing preview.
//
//  The user can:
//    • Toggle individual rows, or Redact All
//    • From a row's menu: never redact this value / domain (kept in
//      Settings → Privacy Filter → Never Redact), or answer for the
//      whole category in this conversation
//    • Pick the conversation policy: ask, redact automatically, or off
//    • Send (commit) or Cancel the send entirely
//
//  Keyboard: ↑/↓ move the selection, Space toggles it, Return sends,
//  Esc cancels.
//

import SwiftUI

struct RedactionReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var inheritedTheme
    private var theme: any ThemeProtocol { inheritedTheme }
    @ObservedObject var state: RedactionReviewState
    @State private var showsFullPreview = false
    @FocusState private var listFocused: Bool

    /// True when the user has toggled every detected entity off. We
    /// gate the primary Send button in this state so a privacy
    /// feature can't silently send unscrubbed text — the destructive
    /// "Send anyway" alternative is shown alongside an explanatory
    /// banner.
    private var allSkipped: Bool {
        !state.entities.isEmpty && state.approvedCount == 0
    }

    /// Context long enough that the inline snippet can't show it well.
    private var hasLongContext: Bool {
        state.entities.contains { ($0.containingText?.count ?? 0) > 600 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s0) {
            header
            listToolbar
            if showsFullPreview {
                HSplitView {
                    list(inlinePreview: false)
                        .frame(minWidth: 320, idealWidth: 360)
                    ContextPreview(state: state)
                        .frame(minWidth: 360, idealWidth: 440)
                }
            } else {
                list(inlinePreview: true)
            }
            ThemeHairlineDivider()
            footer
        }
        .frame(
            minWidth: showsFullPreview ? 820 : 560,
            idealWidth: showsFullPreview ? 880 : 620,
            minHeight: 380 * max(1, theme.fontScale),
            idealHeight: 460 * max(1, theme.fontScale)
        )
        .background(theme.surface.canvas)
        .onAppear {
            showsFullPreview = hasLongContext
            listFocused = true
        }
        .onDisappear { state.sheetDismissed() }
    }

    private var headerSubtitle: String {
        if let provider = state.providerName {
            return L(
                "These items will be replaced with placeholders before your message goes to \(provider). Your choices apply to the rest of this conversation."
            )
        }
        return L(
            "These items will be replaced with placeholders before your message leaves your Mac. Your choices apply to the rest of this conversation."
        )
    }

    private var header: some View {
        SettingsSheetHeader(
            icon: "eye.slash.fill",
            title: "Review Before Sending",
            subtitleText: headerSubtitle,
            onClose: {
                state.cancel()
                dismiss()
            }
        )
    }

    /// Bulk toggle and the full-preview switch. The footer is reserved
    /// for terminal actions (Cancel / Send) and the conversation policy.
    private var listToolbar: some View {
        HStack(spacing: theme.space.s8) {
            Toggle(
                isOn: Binding(
                    get: { state.allApproved == true },
                    set: { newValue in newValue ? state.approveAll() : state.skipAll() }
                )
            ) {
                Text(localized: "Redact all")
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                    .foregroundColor(theme.text.secondary)
            }
            .settingsCheckbox()
            .fixedSize()

            Spacer()

            Button(action: { showsFullPreview.toggle() }) {
                Text(showsFullPreview ? L("Hide full message") : L("Show full message"))
            }
            .buttonStyle(.settings(.secondary, size: .compact))
            .fixedSize()
        }
        .padding(.horizontal, theme.settingsSheetInset)
        .padding(.top, theme.space.s12)
        .padding(.bottom, theme.space.s6)
    }

    private func list(inlinePreview: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.space.s12) {
                ForEach(state.groups, id: \.origin) { group in
                    VStack(alignment: .leading, spacing: theme.space.s6) {
                        Text(verbatim: Self.title(for: group.origin))
                            .catalogTypography(.label, theme: theme, fallback: SettingsFont.footnote)
                            .foregroundColor(theme.text.tertiary)
                        ForEach(group.entities) { entity in
                            row(for: entity, inlinePreview: inlinePreview)
                        }
                    }
                }
            }
            .padding(.horizontal, theme.settingsSheetInset)
            .padding(.vertical, theme.space.s8)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($listFocused)
        .onKeyPress(.upArrow) {
            state.moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            state.moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.space) {
            state.toggleSelected()
            return .handled
        }
    }

    private func row(for entity: DetectedEntity, inlinePreview: Bool) -> some View {
        let isSelected = state.selectedEntityID == entity.id
        return VStack(alignment: .leading, spacing: theme.space.s8) {
            HStack(alignment: .center, spacing: theme.space.s12) {
                Image(systemName: entity.category.reviewIcon)
                    .glyphSize(.body, weight: .medium)
                    .foregroundColor(theme.text.link)
                    .frame(width: 22, height: 22)
                    .settingsChrome(.selected)

                VStack(alignment: .leading, spacing: theme.space.s2) {
                    // Long URLs / addresses get middle-truncated across at
                    // most two lines so the salient parts (scheme + host;
                    // street + city) stay visible without exploding the
                    // sheet height.
                    Text(entity.original)
                        .catalogTypography(.heading, theme: theme, fallback: SettingsFont.sectionTitle)
                        .foregroundColor(entity.approved ? theme.text.primary : theme.text.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: theme.space.s6) {
                        Text(verbatim: entity.approved
                            ? "\(entity.category.localizedName)  →  \(entity.placeholder.token)"
                            : "\(entity.category.localizedName)  ·  \(L("Sent as written"))")
                            .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                            .foregroundColor(theme.text.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if state.neverRedactEntry(for: entity) != nil {
                            StatusChip(L("Never redact"), tone: .neutral, icon: "checkmark.shield")
                        }
                        if let answer = state.categoryAnswers[entity.category] {
                            StatusChip(
                                answer == .alwaysRedact ? L("Always in this chat") : L("Never in this chat"),
                                tone: .accent
                            )
                        }
                    }
                }
                .layoutPriority(1)

                rowMenu(for: entity)

                Toggle(
                    isOn: Binding(
                        get: { entity.approved },
                        set: { newValue in state.setApproval(entity, to: newValue) }
                    )
                ) {
                    Text(localized: "Redact")
                }
                .settingsSwitch()
                .fixedSize()
                .localizedHelp("Redact")
                .accessibilityLabel(Text(verbatim: L("Redact \(entity.original)")))
            }

            if inlinePreview, isSelected {
                InlineContextPreview(state: state, entity: entity)
            }
        }
        .padding(.horizontal, theme.space.s12)
        .padding(.vertical, theme.space.s8)
        // Selected rows pick up an accent border so the user has a
        // visual link to the highlighted match in the preview.
        .settingsChrome(isSelected ? .selected : .control)
        .contentShape(Rectangle())
        .onTapGesture {
            state.select(entity)
            listFocused = true
        }
    }

    @ViewBuilder
    private func rowMenu(for entity: DetectedEntity) -> some View {
        let category = entity.category.localizedName
        SettingsOverflowMenu(help: "More options", size: .compact) {
            if state.neverRedactEntry(for: entity) != nil {
                Button(localized: "Undo never redact") { state.removeNeverRedact(for: entity) }
            } else {
                Button(localized: "Never redact this value") { state.addNeverRedact(.value, for: entity) }
                if let host = NeverRedactEntry.host(of: entity.original), host != entity.original.lowercased() {
                    Button(L("Never redact \(host)")) { state.addNeverRedact(.domain, for: entity) }
                }
            }
            Divider()
            Button(L("Always redact \(category) in this conversation")) {
                state.setCategoryAnswer(entity.category, .alwaysRedact)
            }
            Button(L("Never redact \(category) in this conversation")) {
                state.setCategoryAnswer(entity.category, .neverRedact)
            }
            if state.categoryAnswers[entity.category] != nil {
                Button(L("Ask about \(category) again")) {
                    state.setCategoryAnswer(entity.category, nil)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            // Row 1: how the rest of this conversation behaves. Replaces
            // the old "Always approve in this conversation" checkbox.
            HStack(spacing: theme.space.s8) {
                Text(localized: "For the rest of this conversation")
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                    .foregroundColor(theme.text.secondary)
                    .lineLimit(1)
                SettingsMenuPicker(
                    selection: Binding(
                        get: { state.policy },
                        set: { state.setPolicy($0) }
                    )
                ) {
                    ForEach(ConversationPrivacyPolicy.allCases, id: \.self) { policy in
                        Text(verbatim: policy.menuTitle).tag(policy)
                    }
                }
                .fixedSize()
                Spacer(minLength: 0)
            }

            // Row 2: skip-all warning banner. Only shown when the user
            // has toggled every detection off — this is a privacy
            // feature, so sending unscrubbed text needs to be a
            // deliberate choice, not an accidental one.
            if allSkipped {
                skipAllBanner
            }

            // Row 3: summary + cancel / send. Summary truncates so the
            // buttons stay pinned to the trailing edge.
            HStack(spacing: theme.space.s12) {
                Text(
                    "privacy.review.summary \(state.approvedCount) \(state.skippedCount)",
                    bundle: .module
                )
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(0)

                Spacer(minLength: 8)

                Button(action: {
                    state.cancel()
                    dismiss()
                }) {
                    Text("privacy.review.cancel", bundle: .module)
                }
                .buttonStyle(.settings(.secondary))
                .keyboardShortcut(.cancelAction)
                .fixedSize()

                sendButton
            }
        }
        .padding(theme.settingsSheetInset)
        .background(theme.surface.subtle)
    }

    /// Primary commit button. Two variants:
    /// * normal `Send` (return-key shortcut, accent-colored).
    /// * destructive `Send anyway` when every detection has been
    ///   skipped — no return-key binding, so pressing Enter can't
    ///   bypass the explicit choice the warning banner is asking the
    ///   user to make.
    @ViewBuilder
    private var sendButton: some View {
        let label = allSkipped ? "privacy.review.sendAnyway" : "privacy.review.send"
        let minWidth: CGFloat = allSkipped ? 100 : 80
        let action: () -> Void = {
            state.confirm()
            dismiss()
        }

        if allSkipped {
            Button(role: .destructive, action: action) {
                Text(LocalizedStringKey(label), bundle: .module)
                    .frame(minWidth: minWidth)
            }
            .buttonStyle(.settings(.destructive))
            .fixedSize()
        } else {
            Button(action: action) {
                Text(LocalizedStringKey(label), bundle: .module)
                    .frame(minWidth: minWidth)
            }
            .buttonStyle(.settings(.primary))
            .keyboardShortcut(.defaultAction)
            .fixedSize()
        }
    }

    private var skipAllBanner: some View {
        HStack(alignment: .top, spacing: theme.space.s8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .glyphSize(.footnote, weight: .semibold)
                .foregroundColor(theme.status.warning.foreground)
                .padding(.top, theme.space.s2)
            Text("privacy.review.skipAllWarning", bundle: .module)
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                .foregroundColor(theme.text.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, theme.space.s12)
        .padding(.vertical, theme.space.s8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(.status(.warning))
    }

    /// Group header for rows that came from `origin`.
    static func title(for origin: PrivacySegmentOrigin) -> String {
        switch origin {
        case .userInput: return L("From your message")
        case .toolResult(let name?): return L("From the \(name) tool")
        case .toolResult(nil): return L("From tool results")
        case .modelOutput: return L("From the model's own text")
        }
    }
}

extension ConversationPrivacyPolicy {
    /// Label in the sheet footer and the composer's privacy menu.
    var menuTitle: String {
        switch self {
        case .ask: return L("Ask about new items")
        case .autoRedact: return L("Redact automatically")
        case .off: return L("Turn filter off")
        }
    }

    /// Short state name for the composer chip.
    var chipTitle: String {
        switch self {
        case .ask: return L("Review")
        case .autoRedact: return L("Auto")
        case .off: return L("Off")
        }
    }

    var chipIcon: String {
        switch self {
        case .ask: return "eye.slash"
        case .autoRedact: return "checkmark.shield"
        case .off: return "shield.slash"
        }
    }
}

// MARK: - Previews of the outgoing text

/// Approved (original, placeholder) pairs from the same containing
/// segment as `entity`, so the preview shows exactly what will leave
/// the device: toggling a row off reveals that original in the preview.
@MainActor
private func activePairs(for entity: DetectedEntity, in state: RedactionReviewState) -> [RedactionPreviewBuilder.Pair] {
    guard let containing = entity.containingText else { return [] }
    return state.entities.compactMap { other in
        guard other.containingText == containing, other.approved else { return nil }
        return RedactionPreviewBuilder.Pair(original: other.original, placeholder: other.placeholder.token)
    }
}

private func focusText(for entity: DetectedEntity) -> String {
    entity.approved ? entity.placeholder.token : entity.original
}

/// Short preview under the selected row in the compact layout.
private struct InlineContextPreview: View {
    @Environment(\.theme) private var theme
    @ObservedObject var state: RedactionReviewState
    let entity: DetectedEntity

    var body: some View {
        if let containing = entity.containingText, !containing.isEmpty {
            let preview = RedactionPreviewBuilder.build(text: containing, pairs: activePairs(for: entity, in: state))
            RedactionPreviewTextView(
                scrubbedText: preview.scrubbed,
                highlights: preview.highlights,
                theme: theme,
                focusText: focusText(for: entity)
            )
            .frame(
                maxWidth: .infinity,
                minHeight: theme.lineHeight(.body) * 2,
                maxHeight: theme.lineHeight(.body) * 5,
                alignment: .topLeading
            )
            .padding(.horizontal, theme.space.s8)
            .padding(.vertical, theme.space.s8)
            .settingsChrome(.subtle)
        }
    }
}

/// Right-hand pane of the expanded layout. Shows the **scrubbed
/// payload** the wire will carry — the containing text with originals
/// already substituted for placeholders — and reveals the original on
/// hover. Mirrors the chat bubble UX so the user has one mental model
/// for "what does Privacy Filter do to my text" across both surfaces.
private struct ContextPreview: View {
    @Environment(\.theme) private var inheritedTheme
    private var theme: any ThemeProtocol { inheritedTheme }
    @ObservedObject var state: RedactionReviewState

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s0) {
            if let entity = state.selectedEntity {
                header(for: entity)
                bodyView(for: entity)
            } else {
                emptySelection
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.surface.canvas)
    }

    private func header(for entity: DetectedEntity) -> some View {
        HStack(spacing: theme.space.s8) {
            Image(systemName: entity.category.reviewIcon)
                .glyphSize(.body, weight: .medium)
                .foregroundColor(theme.text.link)
                .frame(width: 26, height: 26)
                .settingsChrome(.selected)

            VStack(alignment: .leading, spacing: theme.space.s4) {
                Text(entity.original)
                    .catalogTypography(.heading, theme: theme, fallback: SettingsFont.sectionTitle)
                    .foregroundColor(theme.text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: theme.space.s6) {
                    Text(entity.category.localizedName)
                        .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                        .foregroundColor(theme.text.secondary)
                    Image(systemName: "arrow.right")
                        .glyphSize(.tiny, weight: .semibold)
                        .foregroundColor(theme.text.tertiary)
                    StatusChip(entity.placeholder.token, tone: .accent)
                }
            }
            Spacer()
        }
        .padding(.horizontal, theme.space.s16)
        .padding(.top, theme.space.s16)
        .padding(.bottom, theme.space.s8)
    }

    @ViewBuilder
    private func bodyView(for entity: DetectedEntity) -> some View {
        let pairs = activePairs(for: entity, in: state)
        VStack(alignment: .leading, spacing: theme.space.s8) {
            HStack(spacing: theme.space.s6) {
                Text("privacy.review.context.header", bundle: .module)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                    .foregroundColor(theme.text.tertiary)
                Spacer()
                if !pairs.isEmpty {
                    HStack(spacing: theme.space.s4) {
                        Image(systemName: "shield.lefthalf.filled")
                            .glyphSize(.tiny, weight: .semibold)
                        Text("privacy.review.context.hoverHint", bundle: .module)
                            .catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
                    }
                    .foregroundColor(theme.text.tertiary)
                }
            }

            if let containing = entity.containingText, !containing.isEmpty {
                let preview = RedactionPreviewBuilder.build(text: containing, pairs: pairs)
                RedactionPreviewTextView(
                    scrubbedText: preview.scrubbed,
                    highlights: preview.highlights,
                    theme: theme,
                    focusText: focusText(for: entity)
                )
                .frame(maxWidth: .infinity, minHeight: max(100, theme.lineHeight(.body) * 3), maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, theme.space.s12).padding(.vertical, theme.space.s12)
                .settingsChrome(.subtle)
            } else {
                emptyContextCard
            }
        }
        .padding(.horizontal, theme.space.s16)
        .padding(.bottom, theme.space.s16)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var emptyContextCard: some View {
        HStack(alignment: .top, spacing: theme.space.s8) {
            Image(systemName: "text.viewfinder")
                .glyphSize(.footnote, weight: .semibold)
                .foregroundColor(theme.text.tertiary)
                .padding(.top, theme.space.s2)
            Text("privacy.review.context.empty", bundle: .module)
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                .foregroundColor(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, theme.space.s12).padding(.vertical, theme.space.s12)
        .settingsChrome(.subtle)
    }

    private var emptySelection: some View {
        HStack {
            Spacer()
            VStack(spacing: theme.space.s8) {
                Image(systemName: "shield.lefthalf.filled")
                    .glyphSize(.xxlarge)
                    .foregroundColor(theme.text.disabled)
                Text("privacy.review.context.empty", bundle: .module)
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
            }
            .padding(.vertical, theme.space.s64)
            Spacer()
        }
    }
}

// MARK: - Category Icon

extension EntityCategory {
    /// SF Symbol shown next to each detected category in the review
    /// sheet and the composer's redaction list. View-only presentation,
    /// so it stays out of the core `EntityCategory` model.
    var reviewIcon: String {
        switch self {
        case .accountNumber: return "creditcard.fill"
        case .address: return "house.fill"
        case .email: return "envelope.fill"
        case .person: return "person.fill"
        case .phone: return "phone.fill"
        case .url: return "link"
        case .date: return "calendar"
        case .secret: return "key.fill"
        }
    }
}
