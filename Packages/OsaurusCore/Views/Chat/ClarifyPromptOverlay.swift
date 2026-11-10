//
//  ClarifyPromptOverlay.swift
//  osaurus
//
//  Inline prompt for the agent's `clarify` tool. Renders bottom-pinned
//  through `PromptOverlayHost` + `PromptCard` so visual chrome stays
//  identical to `SecretPromptOverlay`. The clarify-specific bits live
//  here: the option chip strip and the optional free-form text field
//  shown beneath it (or instead of it, when no options are provided).
//
//  Three answer shapes, modeled by `ClarifyMode`:
//
//    - `.freeForm`     — no options; user types into a single text
//                        field and submits with the arrow / Return.
//    - `.singleSelect` — chips above + text field below. Tapping a chip
//                        submits immediately; typing + Return submits
//                        the typed value (escape hatch for "my answer
//                        isn't on the menu").
//    - `.multiSelect`  — chips become checkboxes; user picks any
//                        number then taps the explicit Submit button.
//                        No free-form input here — it would muddy the
//                        structured answer ("did the typed value win
//                        or the chip selection?").
//

import AppKit
import SwiftUI

// MARK: - Overlay

struct ClarifyPromptOverlay: View {
    let state: ClarifyPromptState
    let onDismiss: () -> Void

    var body: some View {
        PromptOverlayHost(onCancelDismiss: cancelAndDismiss) {
            ClarifyPromptCard(state: state, onCancel: cancelAndDismiss, onSubmitted: onDismiss)
        }
        .onDisappear {
            // Safety net: matches `SecretPromptOverlay` so the queue
            // never gets stuck when SwiftUI tears the view down for
            // unrelated reasons (window close, session switch).
            state.cancel()
        }
    }

    private func cancelAndDismiss() {
        // User-initiated dismissal (Cancel button / Esc) — lets the
        // session preserve the question in the transcript, unlike the
        // silent `cancel()` used by teardown safety nets.
        state.cancelByUser()
        onDismiss()
    }
}

#if OSAURUS_DESIGN_SYSTEM
extension ClarifyPromptOverlay {
    @MainActor static func inspectionCard(mode: Int, report: @escaping (String) -> Void) -> some View {
        ClarifyPromptCard(
            state: ClarifyPromptState(question: "Choose a local sample to review. **No agent is running.**",
                options: mode == 0 ? [] : ["Colors", "Typography", "Geometry with a longer option label"],
                allowMultiple: mode == 2, onSubmit: report),
            onCancel: { report("Local sample cancelled") }, onSubmitted: {}
        )
    }
}
#endif

// MARK: - Mode

/// Which interaction mode the card is rendering. Derived from
/// `state.options` + `state.allowMultiple` once at the top of `body` so
/// every downstream check (`hasChips`, `wantsTextInput`, …) reads off a
/// single source of truth rather than re-deriving from raw fields.
private enum ClarifyMode {
    case freeForm
    case singleSelect
    case multiSelect

    init(options: [String], allowMultiple: Bool) {
        if options.isEmpty {
            self = .freeForm
        } else if allowMultiple {
            self = .multiSelect
        } else {
            self = .singleSelect
        }
    }

    var hasChips: Bool { self != .freeForm }
    var wantsTextInput: Bool { self != .multiSelect }
    var isMultiSelect: Bool { self == .multiSelect }
}

// MARK: - Card

private struct ClarifyPromptCard: View {
    let state: ClarifyPromptState
    let onCancel: () -> Void
    let onSubmitted: () -> Void

    @State private var freeFormAnswer: String = ""
    @State private var selectedOptions: Set<String> = []
    @State private var isInputFocused: Bool = false
    @Environment(\.theme) private var environmentTheme
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(36, authoritative: true) }

    private var mode: ClarifyMode {
        ClarifyMode(options: state.options, allowMultiple: state.allowMultiple)
    }

    private var canSubmitFreeForm: Bool {
        !freeFormAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSubmitMultiSelect: Bool {
        mode.isMultiSelect && !selectedOptions.isEmpty
    }

    var body: some View {
        PromptCard(
            pillIcon: "questionmark.bubble.fill",
            pillLabel: "Question",
            title: nil,
            descriptionMarkdown: state.question,
            footnote: nil,
            onCancel: onCancel,
            bodyContent: { chipStrip },
            inputRow: { inputRow }
        )
        .environment(\.theme, theme)
        .onAppear { autoFocusIfNeeded() }
    }

    private func autoFocusIfNeeded() {
        guard mode.wantsTextInput else { return }
        // `EditableTextView.syncFocus` claims first responder from the
        // binding on the next runloop tick, so no entry-animation delay
        // race: keystrokes land in the field as soon as it's mounted.
        isInputFocused = true
    }

    // MARK: - Body slot: chips

    @ViewBuilder
    private var chipStrip: some View {
        if mode.hasChips {
            FlowChips(
                options: state.options,
                selected: selectedOptions,
                allowMultiple: mode.isMultiSelect,
                onTap: handleOptionTap
            )
            // Stretch the strip to the card's full width so chips
            // anchor to the leading edge instead of centering as a
            // self-sized cluster (PromptCard's outer VStack defaults
            // to center alignment).
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func handleOptionTap(_ option: String) {
        switch mode {
        case .multiSelect:
            // Toggle membership; user submits via the Submit button.
            if selectedOptions.contains(option) {
                selectedOptions.remove(option)
            } else {
                selectedOptions.insert(option)
            }
        case .singleSelect:
            // Single-select: tapping IS the submission.
            state.submit(option)
            onSubmitted()
        case .freeForm:
            // No chips in this mode — `chipStrip` doesn't render any.
            break
        }
    }

    // MARK: - Input slot

    @ViewBuilder
    private var inputRow: some View {
        switch mode {
        case .multiSelect:
            multiSelectSubmitRow
        case .singleSelect, .freeForm:
            freeFormInputRow
        }
    }

    private var multiSelectSubmitRow: some View {
        HStack {
            Text(
                selectedOptions.isEmpty
                    ? "Pick one or more above."
                    : "\(selectedOptions.count) selected"
            )
            .promptText(.caption, fallback: .caption, theme: theme)
            .foregroundColor(theme.text.tertiary)
            Spacer()
            Button(action: submitMultiSelect) {
                Text(localized: "Submit")
            }
            .keyboardShortcut(.defaultAction)
            .assignedSettingsButtonStyle(.primary, size: .compact)
            .disabled(!canSubmitMultiSelect)
            .pointingHandCursor()
        }
    }

    private var freeFormInputRow: some View {
        // Different placeholder when chips exist: signals the input is an
        // alternate path ("type instead") rather than the only path.
        PromptReplyField(
            text: $freeFormAnswer,
            placeholder: mode.hasChips ? "Or type a custom answer…" : "Type your answer…",
            canSubmit: canSubmitFreeForm,
            isFocused: $isInputFocused,
            onSubmit: submitFreeForm,
            onEscape: onCancel
        )
    }

    // MARK: - Submission

    private func submitFreeForm() {
        guard canSubmitFreeForm else { return }
        state.submit(freeFormAnswer)
        onSubmitted()
    }

    private func submitMultiSelect() {
        guard canSubmitMultiSelect else { return }
        // Preserve the order the model gave us so chip positions reflect
        // intent (e.g. "Recommended first"); ad-hoc Set iteration would
        // shuffle them.
        let ordered = state.options.filter { selectedOptions.contains($0) }
        state.submit(ordered.joined(separator: ", "))
        onSubmitted()
    }
}

// MARK: - Chip strip

/// Wrapping chip strip — each chip sizes to its own label (no
/// truncation), wraps to a new row when the line is full. `LazyVGrid`
/// was tried first but its adaptive columns force equal-width cells
/// per row, which truncated mid-length labels like "Business landing
/// page" into ellipses. A real flow layout gives every label the room
/// it needs.
private struct FlowChips: View {
    @Environment(\.theme) private var environmentTheme
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(36, authoritative: true) }
    let options: [String]
    let selected: Set<String>
    let allowMultiple: Bool
    let onTap: (String) -> Void

    var body: some View {
        ChipFlowLayout(spacing: PromptInspectionStyle.metric("gap", 8, theme), lineSpacing: PromptInspectionStyle.metric("gap", 8, theme)) {
            ForEach(options, id: \.self) { option in
                OptionChip(
                    label: option,
                    isSelected: selected.contains(option),
                    showsCheckmark: allowMultiple,
                    action: { onTap(option) }
                )
            }
        }
    }
}

/// One chip in the flow strip. Extracted so `FlowChips` stays a tiny
/// loop and the visual recipe lives in one place.
private struct OptionChip: View {
    let label: String
    let isSelected: Bool
    let showsCheckmark: Bool
    let action: () -> Void
    @State private var inspectorHovered = false
    @Environment(\.isEnabled) private var componentEnabled

    @Environment(\.theme) private var environmentTheme
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(36, authoritative: true) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: theme.catalogLayoutMetric("component.library.36.elements.layout.optionChip.body.horizontalGap", inheriting: PromptInspectionStyle.metric("gap", 6, theme))) {
                if showsCheckmark {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .glyphSize(11, weight: .semibold)
                        .foregroundColor(isSelected ? theme.text.primary : theme.text.tertiary)
                }
                Text(label)
                    .promptText(.label, fallback: .label, theme: theme)
                    .foregroundColor(theme.text.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }.catalogLayoutTarget("component.library.36.elements.layout.optionChip.body.horizontalGap")
            .padding(.horizontal, theme.catalogLayoutMetric("component.library.36.elements.layout.optionChip.body.paddingX", inheriting: PromptInspectionStyle.metric("padding", 11, theme))).catalogLayoutTarget("component.library.36.elements.layout.optionChip.body.paddingX")
            .padding(.vertical, theme.catalogLayoutMetric("component.library.36.elements.layout.optionChip.body.paddingY", inheriting: PromptInspectionStyle.metric("padding", 7, theme))).catalogLayoutTarget("component.library.36.elements.layout.optionChip.body.paddingY")
            .frame(minHeight: PromptInspectionStyle.metric("height", 0, theme))
            .background(
                RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                    .fill(PromptInspectionStyle.fill(hovered: inspectorHovered, enabled: componentEnabled, selected: isSelected, theme: theme, fallback: isSelected ? theme.surface.selected : theme.surface.raised))
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                    .strokeBorder(
                        isSelected ? theme.border.strong : theme.border.default,
                        lineWidth: theme.stroke.default
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { inspectorHovered = $0 }
        .pointingHandCursor()
    }
}

// MARK: - ChipFlowLayout

/// Minimal flow layout: places children left-to-right with `spacing`
/// between them and wraps to a new line when the next child would
/// overflow the proposed width. Each child gets exactly its ideal
/// size — no equal-width column squashing.
///
/// Internal (not file-private) so other clarify surfaces can
/// reuse the same wrapping behavior as the in-chat prompt card.
struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        arrange(in: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        for placement in arrange(in: bounds.width, subviews: subviews).placements {
            placement.subview.place(
                at: CGPoint(
                    x: bounds.minX + placement.origin.x,
                    y: bounds.minY + placement.origin.y
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(
                    width: placement.size.width,
                    height: placement.size.height
                )
            )
        }
    }

    private struct Placement {
        var subview: LayoutSubview
        var origin: CGPoint
        var size: CGSize
    }

    private struct Arrangement {
        var placements: [Placement]
        var size: CGSize
    }

    private func arrange(in maxWidth: CGFloat, subviews: Subviews) -> Arrangement {
        var placements: [Placement] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            // Measure each subview at its ideal size (unbounded width
            // proposal) so chips like "Restaurant / cafe" claim their
            // intrinsic width instead of being squeezed to a column.
            let size = subview.sizeThatFits(.unspecified)
            // Wrap when the next chip wouldn't fit on the current line.
            // The `x > 0` guard guarantees at least one chip per line so
            // a single overlong label doesn't infinite-loop or vanish.
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            placements.append(
                Placement(
                    subview: subview,
                    origin: CGPoint(x: x, y: y),
                    size: size
                )
            )
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            totalWidth = max(totalWidth, x - spacing)
        }
        return Arrangement(
            placements: placements,
            size: CGSize(width: totalWidth, height: y + lineHeight)
        )
    }
}
