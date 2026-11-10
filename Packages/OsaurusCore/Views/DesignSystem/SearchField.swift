//
//  SearchField.swift
//  osaurus
//
//  The one search input: magnifier, IME-aware field, clear button, on
//  control chrome at control height so it lines up with adjacent buttons.
//

import AppKit
import SwiftUI

struct SearchField: View {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Binding var text: String
    var placeholder: LocalizedStringKey
    var width: CGFloat = SearchField.standardWidth
    /// Fill the remaining width (stacked toolbars, sheet search) instead of
    /// the fixed width.
    var fillsAvailableWidth: Bool = false
    var onFocusChange: ((Bool) -> Void)? = nil
    var onSubmit: (() -> Void)? = nil
    /// ↑ / ↓ while typing, for a result list under the field.
    var onMove: ((Int) -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    var autofocus: Bool = false
    /// False leaves the field out of Tab order and out of the window's own
    /// pick of what to focus first, for a search beside a keyboard-driven view.
    var joinsKeyLoop: Bool = true

    /// Width used beside a tab selector or filter row.
    static let standardWidth: CGFloat = 220

    /// Tracks IME composition so the placeholder hides while composing.
    @State private var isComposing: Bool = false
    @State private var isFocused = false
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: theme.space.s6) {
            Image(systemName: "magnifyingglass")
                .font(SettingsFont.glyph)
                .foregroundColor(theme.text.tertiary)
                .accessibilityHidden(true)

            ZStack(alignment: .leading) {
                if text.isEmpty && !isComposing {
                    Text(localized: placeholder)
                        .foregroundColor(isEnabled ? theme.assignedColor("component.input.placeholder", fallback: theme.text.placeholder) : theme.assignedColor("component.input.disabled.foreground", fallback: theme.text.disabled))
                        .lineLimit(1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                IMEAwareTextField(
                    text: $text,
                    isComposing: $isComposing,
                    font: theme.assignedNativeFont("component.input.text", fallback: theme.nsFont(.label, weight: .regular)),
                    textColor: NSColor(isEnabled ? theme.assignedColor("component.input.foreground", fallback: theme.text.primary) : theme.assignedColor("component.input.disabled.foreground", fallback: theme.text.disabled)),
                    onSubmit: onSubmit,
                    onFocusChange: { focused in isFocused = focused; onFocusChange?(focused) },
                    tracking: theme.assignedTracking("component.input.text"),
                    editable: isEnabled,
                    onMove: onMove,
                    onCancel: onCancel,
                    clearsOnEscape: true,
                    focusOnAppear: autofocus,
                    joinsKeyLoop: joinsKeyLoop
                )
                .accessibilityLabel(Text(localized: placeholder))
                .frame(height: theme.assignedLineHeight("component.input.text", fallback: theme.lineHeight(.label)))
            }
            .assignedTypography("component.input.text", fallback: SettingsFont.body)

            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(SettingsFont.glyphSmall)
                        .foregroundColor(theme.text.tertiary)
                }
                .buttonStyle(.plain)
                .help(Text("Clear", bundle: .module))
                .accessibilityLabel(Text("Clear search", bundle: .module))
            }
        }
        .padding(.horizontal, theme.assignedMetric("component.input.paddingX", fallback: theme.settingsFieldInset))
        .padding(.vertical, theme.assignedMetric("component.input.paddingY", fallback: 0))
        .frame(minHeight: theme.assignedMetric("component.control.heightDefault", fallback: theme.controlSize.defaultHeight))
        .frame(width: fillsAvailableWidth ? nil : width)
        .frame(maxWidth: fillsAvailableWidth ? .infinity : nil)
        .background(
            RoundedRectangle(cornerRadius: theme.assignedMetric("component.input.radius", fallback: theme.radius.medium), style: .continuous)
                .fill(isEnabled ? theme.assignedColor("component.input.background", fallback: theme.surface.raised) : theme.assignedColor("component.input.disabled.background", fallback: theme.surface.disabled))
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.assignedMetric("component.input.radius", fallback: theme.radius.medium), style: .continuous)
                .strokeBorder(theme.assignedColor(isHovering && isEnabled ? "component.input.borderHover" : "component.input.border", fallback: theme.border.strong), lineWidth: theme.assignedMetric("component.input.borderWidth", fallback: theme.stroke.default))
        )
        .assignedFocusRing(isFocused && isEnabled, radius: theme.assignedMetric("component.input.radius", fallback: theme.radius.medium))
        .onHover { isHovering = $0 }
    }
}
