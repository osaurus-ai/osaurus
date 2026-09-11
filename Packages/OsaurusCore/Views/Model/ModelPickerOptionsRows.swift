//
//  ModelPickerOptionsRows.swift
//  osaurus
//
//  Per-model option rows (Thinking, Reasoning Effort, MTP, …) rendered
//  inline in the model picker directly under the selected model's row.
//  The control structs describe display state plus semantic setters; the
//  owner (FloatingInputCard / ChatView) resolves the profile-specific
//  stored option, never the view.
//

import SwiftUI

/// Semantic Thinking row state for the picker's options rows. Carries
/// only display state plus a semantic setter — the profile-specific stored
/// boolean (including inverted options like `disableThinking`) is resolved
/// by the owner through `ModelProfileRegistry.thinkingStoredOption`, never
/// in the view.
struct ModelPickerThinkingControl {
    /// Effective on/off state the row shows: the explicit persisted choice
    /// when present, otherwise the model's chat-template default.
    let isEnabled: Bool
    /// Whether an explicit persisted override exists. Drives the Default
    /// pill vs. the reset affordance.
    let isExplicit: Bool
    /// Persist a semantic enabled state; nil removes the override so the
    /// model's template default applies naturally again.
    let onSetEnabled: (Bool?) -> Void
    var supportsUnspecifiedDefault: Bool = false
}

/// Inline model-options control state for the picker's currently selected
/// model: the semantic Thinking row (when the model has a thinking toggle)
/// plus every other option the model's profile (or live provider catalog)
/// exposes. Rendered as one expandable row directly beneath the selected
/// model wherever that model appears (its group, Favorites, search).
struct ModelPickerOptionsControl {
    /// Catalog-driven reasoning capabilities (ChatGPT/Codex live catalog or
    /// the documented official OpenAI GPT-5.6 contract), when present. Used
    /// to surface per-level catalog descriptions on the effort row.
    let capabilities: ModelReasoningCapabilities?
    /// Semantic Thinking row for models with a boolean thinking toggle.
    /// Rendered first, ahead of the generic rows.
    var thinking: ModelPickerThinkingControl? = nil
    /// Non-thinking option definitions for the selected model, in profile
    /// order. When `capabilities` is present this is just the dynamic
    /// `reasoningEffort` definition.
    let options: [ModelOptionDefinition]
    /// Explicit persisted values. Missing keys mean "use the default" —
    /// nothing is sent on the wire for them.
    let values: [String: ModelOptionValue]
    /// Display-only defaults (profile defaults, or the catalog default for
    /// capability-enriched effort). Never synthesized into requests.
    let defaults: [String: ModelOptionValue]
    /// Persist one option; a nil value removes the explicit override so the
    /// default applies naturally again.
    let onChange: (String, ModelOptionValue?) -> Void

    var isEmpty: Bool { options.isEmpty && thinking == nil }

    /// The segment id the UI marks as selected for a segmented option:
    /// explicit choice first, then the display default, then the first
    /// segment.
    func effectiveSegmentId(for option: ModelOptionDefinition) -> String? {
        if let explicit = values[option.id]?.stringValue { return explicit }
        if let fallback = defaults[option.id]?.stringValue { return fallback }
        if case .segmented(let segments) = option.kind { return segments.first?.id }
        return nil
    }

    /// The on/off state the UI shows for a toggle option: explicit choice
    /// first, then the display default, then the definition's default.
    func effectiveToggleValue(for option: ModelOptionDefinition) -> Bool {
        if let explicit = values[option.id]?.boolValue { return explicit }
        if let fallback = defaults[option.id]?.boolValue { return fallback }
        if case .toggle(let defaultValue) = option.kind { return defaultValue }
        return false
    }

    /// Leading inset of the option rows: lines up with the model name column
    /// of the row above (checkmark gutter), so the expansion reads as that
    /// model's own settings rather than a separate panel.
    static let leadingInset: CGFloat = 30
    static let trailingInset: CGFloat = 12

    /// Estimated rendered height of the inline options row at
    /// `availableWidth`. Used as the fallback when live measurement of the
    /// hosted SwiftUI content is unavailable.
    func estimatedHeight(availableWidth: CGFloat) -> CGFloat {
        rowsEstimatedHeight(availableWidth: availableWidth) + 6
    }

    /// Estimated rendered height of the option rows alone. Segmented rows
    /// account for chip wrapping in the given content width.
    func rowsEstimatedHeight(availableWidth: CGFloat) -> CGFloat {
        // Thinking row: single header line with the switch + padding.
        let thinkingHeight: CGFloat = thinking != nil ? 36 : 0
        return thinkingHeight
            + options.reduce(CGFloat(0)) { total, option in
                switch option.kind {
                case .segmented(let segments):
                    var lines: CGFloat = 1
                    var lineWidth: CGFloat = 0
                    for segment in segments {
                        // chip ≈ label width (~6.5pt/char) + horizontal padding + spacing
                        let chipWidth = CGFloat(segment.label.count) * 6.5 + 26
                        if lineWidth + chipWidth > availableWidth {
                            lines += 1
                            lineWidth = chipWidth
                        } else {
                            lineWidth += chipWidth
                        }
                    }
                    // header + chip lines + row padding (+ description line when
                    // the catalog publishes level copy)
                    let descriptionHeight: CGFloat =
                        (option.id == "reasoningEffort" && capabilities != nil) ? 16 : 0
                    return total + 24 + lines * 30 + 18 + descriptionHeight
                case .toggle:
                    return total + 36
                }
            }
    }

    /// A stable key describing everything that affects the rows' rendered
    /// height, so the table can cache its measurement.
    var layoutKey: String {
        var parts: [String] = []
        if let thinking {
            parts.append("thinking:\(thinking.isEnabled):\(thinking.isExplicit):\(thinking.supportsUnspecifiedDefault)")
        }
        parts.append("caps:\(capabilities != nil)")
        for option in options {
            let value = values[option.id].map { "\($0)" } ?? "-"
            let fallback = defaults[option.id].map { "\($0)" } ?? "-"
            parts.append("\(option.id)=\(value)|\(fallback)")
        }
        return parts.joined(separator: ";")
    }
}

/// The inline options content under the selected model: a hairline, then
/// the Thinking row (when present) and every other option row, each in the
/// same header idiom (icon · label · Default pill … reset · control) and
/// indented to the model-name column of the row above.
struct ModelPickerOptionsRows: View {
    let control: ModelPickerOptionsControl
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            divider
            if let thinking = control.thinking {
                thinkingOptionRow(thinking)
                if !control.options.isEmpty {
                    divider
                }
            }
            ForEach(Array(control.options.enumerated()), id: \.element.id) { index, option in
                if index > 0 {
                    divider
                }
                switch option.kind {
                case .segmented:
                    segmentedOptionRow(option)
                case .toggle:
                    toggleOptionRow(option)
                }
            }
        }
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Model Options", bundle: .module))
    }

    private var divider: some View {
        Divider()
            .background(theme.primaryBorder.opacity(0.15))
            .padding(.leading, ModelPickerOptionsControl.leadingInset)
            .padding(.trailing, ModelPickerOptionsControl.trailingInset)
    }

    /// Dedicated Thinking row in the shared header idiom: brain glyph
    /// (accent while on), title, the Default pill while the model's
    /// template default applies, and the switch on the trailing edge; an
    /// explicit override swaps the pill for a compact reset affordance.
    @ViewBuilder
    private func thinkingOptionRow(_ thinking: ModelPickerThinkingControl) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: "brain")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(thinking.isEnabled ? theme.accentColor : theme.tertiaryText)

            Text("Thinking", bundle: .module)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.primaryText)

            if !thinking.isExplicit {
                defaultPill
            }

            Spacer(minLength: 8)

            if thinking.isExplicit {
                compactResetButton { thinking.onSetEnabled(nil) }
            }

            if thinking.supportsUnspecifiedDefault {
                Picker(
                    "Thinking",
                    selection: Binding(
                        get: { thinking.isExplicit ? (thinking.isEnabled ? "on" : "off") : "default" },
                        set: { thinking.onSetEnabled($0 == "default" ? nil : $0 == "on") }
                    )
                ) {
                    Text("Default", bundle: .module).tag("default")
                    Text("On", bundle: .module).tag("on")
                    Text("Off", bundle: .module).tag("off")
                }
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("model-thinking-mode")
            } else {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { thinking.isEnabled },
                        set: { thinking.onSetEnabled($0) }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            }
        }
        .padding(.leading, ModelPickerOptionsControl.leadingInset)
        .padding(.trailing, ModelPickerOptionsControl.trailingInset)
        .padding(.vertical, 9)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: thinking.isEnabled)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Thinking", bundle: .module))
        .accessibilityValue(
            thinking.supportsUnspecifiedDefault && !thinking.isExplicit
                ? Text("Default", bundle: .module)
                : thinking.isEnabled
                    ? Text("On", bundle: .module)
                    : Text("Off", bundle: .module)
        )
    }

    /// Icon-only reset affordance for compact rows where the labeled
    /// `resetButton` would crowd the switch; the label moves to the tooltip.
    private func compactResetButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(theme.secondaryText)
                .frame(width: 20, height: 20)
                .background(Circle().fill(theme.secondaryBackground))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(String(localized: "Reset to default", bundle: .module))
        .accessibilityLabel(Text("Reset to default", bundle: .module))
    }

    /// Segmented option row: the option's segments in declared order, the
    /// effective selection marked, a "Default" pill while no explicit
    /// override exists, and a reset affordance while one does. For the
    /// catalog-enriched effort row, catalog level descriptions render as
    /// secondary text/help.
    @ViewBuilder
    private func segmentedOptionRow(_ option: ModelOptionDefinition) -> some View {
        let segments: [ModelOptionSegment] = {
            if case .segmented(let segments) = option.kind { return segments }
            return []
        }()
        let isExplicit = control.values[option.id] != nil
        let effectiveId = control.effectiveSegmentId(for: option)
        // Catalog levels (with descriptions) back the effort row when the
        // provider published capabilities; other rows have segments only.
        let capabilityLevels: [ModelReasoningCapabilities.Level]? =
            (option.id == "reasoningEffort") ? control.capabilities?.levels : nil

        VStack(alignment: .leading, spacing: 8) {
            optionRowHeader(option: option, isExplicit: isExplicit)

            FlowLayout(spacing: 6) {
                ForEach(segments) { segment in
                    segmentChip(
                        label: segment.label,
                        help: capabilityLevels?.first(where: { $0.id == segment.id })?.description,
                        isSelected: segment.id == effectiveId,
                        action: { control.onChange(option.id, .string(segment.id)) }
                    )
                }
            }

            // The effective level's catalog description, when the provider
            // published one (Codex catalog levels carry ChatGPT's own copy).
            if let description = capabilityLevels?
                .first(where: { $0.id == effectiveId })?.description,
                !description.isEmpty
            {
                Text(description)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let help = option.help, !help.isEmpty {
                Text(help)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, ModelPickerOptionsControl.leadingInset)
        .padding(.trailing, ModelPickerOptionsControl.trailingInset)
        .padding(.vertical, 9)
    }

    /// Toggle option row in the same visual family as the segmented rows.
    @ViewBuilder
    private func toggleOptionRow(_ option: ModelOptionDefinition) -> some View {
        let isExplicit = control.values[option.id] != nil
        let isOn = control.effectiveToggleValue(for: option)

        HStack(spacing: 6) {
            if let icon = option.icon {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isExplicit ? theme.accentColor : theme.tertiaryText)
            }
            Text(option.label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.primaryText)

            if !isExplicit {
                defaultPill
            }

            Spacer(minLength: 8)

            if isExplicit {
                // Compact next to the switch: the labeled reset would crowd it.
                compactResetButton { control.onChange(option.id, nil) }
            }

            Toggle(
                "",
                isOn: Binding(
                    get: { isOn },
                    set: { control.onChange(option.id, .bool($0)) }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
        }
        .padding(.leading, ModelPickerOptionsControl.leadingInset)
        .padding(.trailing, ModelPickerOptionsControl.trailingInset)
        .padding(.vertical, 9)
    }

    /// Shared header line for option rows: icon, label, "Default" pill while
    /// no explicit override exists, reset affordance while one does.
    private func optionRowHeader(option: ModelOptionDefinition, isExplicit: Bool) -> some View {
        HStack(spacing: 6) {
            if let icon = option.icon {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isExplicit ? theme.accentColor : theme.tertiaryText)
            }

            Text(option.label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.primaryText)

            if !isExplicit {
                defaultPill
            }

            Spacer()

            if isExplicit {
                resetButton { control.onChange(option.id, nil) }
            }
        }
    }

    private var defaultPill: some View {
        Text("Default", bundle: .module)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(theme.tertiaryText)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(theme.secondaryBackground))
            .overlay(Capsule().strokeBorder(theme.primaryBorder.opacity(0.15), lineWidth: 1))
    }

    private func resetButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 9))
                Text("Reset to default", bundle: .module)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(theme.secondaryText)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    private func segmentChip(
        label: String,
        help: String?,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            isSelected
                                ? theme.accentColor.opacity(theme.isDark ? 0.15 : 0.1)
                                : theme.secondaryBackground.opacity(0.6)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            isSelected
                                ? theme.accentColor.opacity(0.3)
                                : theme.primaryBorder.opacity(0.12),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(help ?? label)
    }
}
