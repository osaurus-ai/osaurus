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
    @Environment(\.theme) private var theme
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
            Divider().padding(.bottom, 4)
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
            Divider()
            footer
        }
        .frame(minWidth: 820, idealWidth: 880, minHeight: 480, idealHeight: 520)
        .background(theme.primaryBackground)
        .onDisappear { state.sheetDismissed() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("privacy.review.title", bundle: .module)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundColor(theme.primaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text("privacy.review.subtitle", bundle: .module)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    /// Small toolbar above the list. Hosts the bulk-toggle buttons so
    /// the footer can be reserved for terminal actions (Cancel / Send
    /// / Send anyway) with stable layout.
    private var listToolbar: some View {
        HStack(spacing: 8) {
            Button(action: state.approveAll) {
                Text("privacy.review.approveAll", bundle: .module)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()

            Button(action: state.skipAll) {
                Text("privacy.review.skipAll", bundle: .module)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(state.entities) { entity in
                    row(for: entity)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
    }

    private func row(for entity: DetectedEntity) -> some View {
        let isSelected = state.selectedEntityID == entity.id
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: entity.category.reviewIcon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.accentColor)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(theme.accentColor.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 2) {
                // Long URLs / addresses get middle-truncated across at
                // most two lines so the salient parts (scheme + host;
                // street + city) stay visible without exploding the
                // sheet height.
                Text(entity.original)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: "\(entity.category.localizedName)  →  \(entity.placeholder.token)")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
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
            .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // Selected rows pick up an accent border so the user has a
        // visual link to the highlighted match in the right pane.
        // Tapping anywhere outside the toggle (which we explicitly
        // let bubble its own gesture) updates the selection.
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? theme.accentColor.opacity(0.10) : theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            isSelected ? theme.accentColor.opacity(0.55) : theme.inputBorder,
                            lineWidth: isSelected ? 1.5 : 1
                        )
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { state.select(entity) }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Row 1: always-approve toggle on its own line so its
            // localised string ("Always approve in this conversation"
            // and similar long Latin variants) doesn't fight with the
            // Cancel / Send buttons.
            Toggle(isOn: $state.alwaysApprove) {
                Text("privacy.review.alwaysApprove", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)

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
            HStack(spacing: 12) {
                Text(
                    "privacy.review.summary \(state.approvedCount) \(state.skippedCount)",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
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
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                .fixedSize()

                sendButton
            }
        }
        .padding(20)
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
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .fixedSize()
        } else {
            Button(action: action) {
                Text(LocalizedStringKey(label), bundle: .module)
                    .frame(minWidth: minWidth)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .fixedSize()
        }
    }

    private var skipAllBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(.orange)
                .padding(.top, 1)
            Text("privacy.review.skipAllWarning", bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.primaryText)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.orange.opacity(0.4), lineWidth: 1)
                )
        )
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
    @Environment(\.theme) private var theme
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
        .background(theme.primaryBackground)
    }

    private func header(for entity: DetectedEntity) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entity.category.reviewIcon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.accentColor)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(theme.accentColor.opacity(0.14))
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(entity.original)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(entity.category.localizedName)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)
                    Text(entity.placeholder.token)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(theme.accentColor.opacity(0.12)))
                }
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func bodyView(for entity: DetectedEntity) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("privacy.review.context.header", bundle: .module)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
                    .textCase(.uppercase)
                    .tracking(0.4)
                Spacer()
                if !activePairs.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.system(size: 9, weight: .semibold))
                        Text("privacy.review.context.hoverHint", bundle: .module)
                            .font(.system(size: 10))
                    }
                    .foregroundColor(theme.tertiaryText)
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
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.codeBlockBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(theme.accentColor.opacity(0.18), lineWidth: 1)
                        )
                )
            } else {
                emptyContextCard
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var emptyContextCard: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
                .padding(.top, 1)
            Text("privacy.review.context.empty", bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.codeBlockBackground.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.primaryBorder.opacity(0.2), lineWidth: 1)
                )
        )
    }

    private var emptySelection: some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 24))
                    .foregroundColor(theme.tertiaryText.opacity(0.6))
                Text("privacy.review.context.empty", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
            .padding(.vertical, 60)
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
