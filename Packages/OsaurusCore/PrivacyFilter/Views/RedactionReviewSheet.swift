//
//  RedactionReviewSheet.swift
//  osaurus / PrivacyFilter
//
//  Modal presented before a cloud send when the engine has detected
//  PII the user hasn't already approved this turn. The user can:
//    • Toggle individual entries
//    • Approve All / Skip All (toolbar above the list)
//    • Tick "Always approve in this conversation"
//    • Send (commit current approvals) or Cancel the send entirely
//
//  Layout note: with real localizations, the original two-row footer
//  overflowed at 480pt — `Always approve in this conversation` and
//  `Cancel send` are both wide strings. The footer is now three rows
//  (always-approve toggle, optional skip-all banner, summary +
//  Cancel + Send) each with `fixedSize(horizontal:vertical:)` on
//  buttons so wrap behavior is stable and predictable.
//

import SwiftUI

struct RedactionReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }
    @ObservedObject var state: RedactionReviewState

    /// True when the user has toggled every detected entity off. We
    /// gate the primary Send button in this state so a privacy
    /// feature can't silently send unscrubbed text — the destructive
    /// "Send anyway" alternative is shown alongside an explanatory
    /// banner.
    private var allSkipped: Bool {
        !state.entities.isEmpty && state.approvedCount == 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            listToolbar
            // Master/detail split: the row list on the left stays
            // scannable for a quick approve-all pass, while the right
            // pane lets the user verify each match against the full
            // surrounding message before approving. The split view
            // collapses to a single list at narrow widths so the
            // sheet still works on a smaller display.
            HSplitView {
                list
                    .frame(minWidth: 320, idealWidth: 360)
                ContextPreview(state: state)
                    .frame(minWidth: 360, idealWidth: 440)
            }
            Divider().opacity(0.5)
            footer
        }
        .frame(minWidth: 820, idealWidth: 880,
            minHeight: 480 * max(1, theme.fontScale), idealHeight: 520 * max(1, theme.fontScale))
        .background(theme.surface.canvas)
        .onDisappear { state.sheetDismissed() }
    }

    private var header: some View {
        SettingsSheetHeader(
            icon: "eye.slash.fill",
            title: "privacy.review.title",
            subtitle: "privacy.review.subtitle",
            onClose: {
                state.cancel()
                dismiss()
            }
        )
    }

    /// Small toolbar above the list. Hosts the bulk-toggle buttons so
    /// the footer can be reserved for terminal actions (Cancel / Send
    /// / Send anyway) with stable layout.
    private var listToolbar: some View {
        HStack(spacing: theme.space.s8) {
            Button(action: state.approveAll) {
                Text("privacy.review.approveAll", bundle: .module)
            }
            .buttonStyle(.settings(.secondary, size: .compact))
            .fixedSize()

            Button(action: state.skipAll) {
                Text("privacy.review.skipAll", bundle: .module)
            }
            .buttonStyle(.settings(.secondary, size: .compact))
            .fixedSize()

            Spacer()
        }
        .padding(.horizontal, theme.settingsSheetInset)
        .padding(.top, theme.space.s12)
        .padding(.bottom, theme.space.s6)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: theme.space.s8) {
                ForEach(state.entities) { entity in
                    row(for: entity)
                }
            }
            .padding(.horizontal, theme.settingsSheetInset)
            .padding(.vertical, theme.space.s8)
        }
    }

    private func row(for entity: DetectedEntity) -> some View {
        let isSelected = state.selectedEntityID == entity.id
        return HStack(alignment: .center, spacing: theme.space.s12) {
            Image(systemName: entity.category.reviewIcon)
                .glyphSize(14, weight: .medium)
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
                    .foregroundColor(theme.text.primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: "\(entity.category.localizedName)  →  \(entity.placeholder.token)")
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                    .foregroundColor(theme.text.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .layoutPriority(1)

            Toggle(
                "",
                isOn: Binding(
                    get: { entity.approved },
                    set: { newValue in state.setApproval(entity, to: newValue) }
                )
            )
            .settingsSwitch()
            .fixedSize()
        }
        .padding(.horizontal, theme.space.s12)
        .padding(.vertical, theme.space.s8)
        // Selected rows pick up an accent border so the user has a
        // visual link to the highlighted match in the right pane.
        // Tapping anywhere outside the toggle (which we explicitly
        // let bubble its own gesture) updates the selection.
        .settingsChrome(isSelected ? .selected : .control)
        .contentShape(Rectangle())
        .onTapGesture { state.select(entity) }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            // Row 1: always-approve toggle on its own line so its
            // localised string ("Always approve in this conversation"
            // and similar long Latin variants) doesn't fight with the
            // Cancel / Send buttons.
            Toggle(isOn: $state.alwaysApprove) {
                Text("privacy.review.alwaysApprove", bundle: .module)
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                    .foregroundColor(theme.text.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .settingsCheckbox()

            // Row 2: skip-all warning banner. Only shown when the user
            // has actively toggled every detection off — this is a
            // privacy feature, so sending unscrubbed text needs to be
            // a deliberate choice, not an accidental one.
            if allSkipped {
                skipAllBanner
            }

            // Row 3: summary + cancel / send. Summary uses
            // `layoutPriority(0)` and truncates so the buttons stay
            // pinned to the trailing edge.
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
                .catalogTypography(.caption, theme: theme, fallback: SettingsFont.glyphSmall)
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

}

// MARK: - Context Preview

/// Right-hand pane in the redaction review sheet. Shows the
/// **scrubbed payload** the wire will carry — the user's containing
/// text with originals already substituted for placeholders — and
/// reveals the original on hover. Mirrors the chat bubble UX so the
/// user has one mental model for "what does Privacy Filter do to my
/// text" across both surfaces.
///
/// Without this pane the user is approving redactions blind — fine
/// for `My name is Alice`, painful for "paste a document" workflows.
private struct ContextPreview: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }
    @ObservedObject var state: RedactionReviewState

    /// Approved (original, placeholder) pairs whose container
    /// matches the selected entity. We only substitute approved
    /// entries so the user sees exactly what will leave the device:
    /// toggling a row off in the left list immediately reveals that
    /// original in the right preview.
    private var activePairs: [RedactionPreviewBuilder.Pair] {
        guard let selected = state.selectedEntity,
            let containing = selected.containingText
        else { return [] }
        return state.entities.compactMap { entity in
            guard entity.containingText == containing, entity.approved else { return nil }
            return RedactionPreviewBuilder.Pair(
                original: entity.original,
                placeholder: entity.placeholder.token
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                .glyphSize(14, weight: .medium)
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
                        .glyphSize(9, weight: .semibold)
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
        VStack(alignment: .leading, spacing: theme.space.s8) {
            HStack(spacing: theme.space.s6) {
                Text("privacy.review.context.header", bundle: .module)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                    .foregroundColor(theme.text.tertiary)
                Spacer()
                if !activePairs.isEmpty {
                    HStack(spacing: theme.space.s4) {
                        Image(systemName: "shield.lefthalf.filled")
                            .glyphSize(9, weight: .semibold)
                        Text("privacy.review.context.hoverHint", bundle: .module)
                            .catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
                    }
                    .foregroundColor(theme.text.tertiary)
                }
            }

            if let containing = entity.containingText, !containing.isEmpty {
                let preview = RedactionPreviewBuilder.build(
                    text: containing,
                    pairs: activePairs
                )
                RedactionPreviewTextView(
                    scrubbedText: preview.scrubbed,
                    highlights: preview.highlights,
                    theme: theme
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
                .glyphSize(11, weight: .semibold)
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
                    .glyphSize(24)
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

private extension EntityCategory {
    /// SF Symbol shown next to each detected category in the review
    /// sheet. View-only presentation, so it stays out of the core
    /// `EntityCategory` model and file-local to the only consumer.
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
