//
//  ChatFindBar.swift
//  osaurus
//
//  In-conversation find bar (Cmd+F). Docks at the top-trailing edge of the
//  readable column and grows to fill it up to a cap; matches are computed per turn in ChatView and navigated
//  via the same scroll-to-turn machinery the minimap uses.
//

import SwiftUI
import AppKit

struct ChatFindBar: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var enabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(44, enabled: enabled) }
    @State private var composing = false

    @Binding var query: String
    /// Bumped by the window's Cmd+F handler; every change re-focuses the
    /// text field even when the bar is already visible.
    var focusTrigger: Int = 0
    /// True while a debounced recompute has been pending long enough to
    /// warrant feedback; shows a small spinner trailing the text field in
    /// place of the (stale) match count.
    var isSearching: Bool = false
    /// Zero-based index of the current match; meaningless when `matchCount == 0`.
    let matchIndex: Int
    let matchCount: Int
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onClose: () -> Void

    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: theme.catalogLayoutMetric("component.library.44.elements.layout.chatFindBar.body.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(44, "gap", theme.space.s8, theme))) {
            Image(systemName: "magnifyingglass")
                .glyphSize(.footnote, weight: .medium)
                .foregroundColor(theme.text.tertiary)

            ZStack(alignment: .leading) {
                if query.isEmpty {
                    Text(L("Find in conversation"))
                        .componentInspectionText(44, role: .body, fallback: .caption, theme: theme)
                        .foregroundColor(theme.text.secondary).allowsHitTesting(false)
                }
                InspectorAssignedTextField(text: $query, isComposing: $composing,
                    font: theme.assignedNativeFont("component.library.44.text", fallback: theme.nsFont(.caption)),
                    textColor: NSColor(theme.text.primary), onSubmit: onNext,
                    onFocusChange: { isFieldFocused = $0 }, tracking: theme.assignedTracking("component.library.44.text"),
                    editable: enabled, requestedFocus: isFieldFocused, onCommand: { selector in
                        if selector == #selector(NSResponder.moveUp(_:)) { onPrevious(); return true }
                        if selector == #selector(NSResponder.moveDown(_:)) { onNext(); return true }
                        return false
                    })
                    .accessibilityLabel(L("Find in conversation"))
            }
            .frame(minWidth: 96, maxWidth: .infinity).frame(minHeight: theme.assignedLineHeight("component.library.44.text", fallback: theme.scaledTextStyle(.caption).lineHeight))

            if isSearching {
                SettingsSpinner(size: .mini)
                    .frame(minWidth: 34, alignment: .center)
            } else {
                Text(matchCountLabel)
                    .componentInspectionText(44, role: .caption, fallback: .footnote, monospacedDigit: true, weight: 500, theme: theme)
                    .foregroundColor(theme.text.tertiary)
                    .frame(minWidth: 34)
            }

            Divider().frame(height: 14)

            navButton(systemName: "chevron.up", action: onPrevious)
                .help(Text("Previous match", bundle: .module))
            navButton(systemName: "chevron.down", action: onNext)
                .help(Text("Next match", bundle: .module))

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .glyphSize(.tiny, weight: .semibold)
                    .foregroundColor(theme.text.secondary)
                    .frame(width: NativeComponentInspectionStyle.metric(44, "height", 18, theme), height: NativeComponentInspectionStyle.metric(44, "height", 18, theme))
                    .componentInspectionSurface(44, background: .clear, radius: theme.radius.small)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("Close find bar", bundle: .module))
        }.catalogLayoutTarget("component.library.44.elements.layout.chatFindBar.body.horizontalGap")
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.44.elements.layout.chatFindBar.body.paddingX", inheriting: NativeComponentInspectionStyle.metric(44, "padding", theme.space.s12, theme))).catalogLayoutTarget("component.library.44.elements.layout.chatFindBar.body.paddingX")
        .padding(.vertical, theme.catalogLayoutMetric("component.library.44.elements.layout.chatFindBar.body.paddingY", inheriting: NativeComponentInspectionStyle.metric(44, "padding", theme.space.s8, theme))).catalogLayoutTarget("component.library.44.elements.layout.chatFindBar.body.paddingY")
        .background(
            RoundedRectangle(cornerRadius: theme.radius.medium)
                .fill(theme.assignedColor("component.library.44.background", fallback: theme.surface.subtle))
                .themeElevation(theme.elevation.raised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.medium)
                .stroke(theme.assignedColor("component.library.44.border", fallback: theme.border.default), lineWidth: theme.stroke.default)
        )
        .nativeCatalogTarget(["background", "border", "borderWidth", "radius", "padding", "gap"].map { NativeCatalogAssignment.key("component.library.44." + $0, theme: theme) }, "Conversation search bar")
        .onAppear {
            // Setting @FocusState synchronously in onAppear races the
            // overlay's insertion into the window's responder chain and
            // silently loses (issue #1964) — the field appeared unfocused.
            // Deferring one runloop turn lets the hosting view attach first.
            DispatchQueue.main.async { isFieldFocused = true }
        }
        .onChange(of: focusTrigger) { _, _ in
            isFieldFocused = true
        }
    }

    private var matchCountLabel: String {
        guard matchCount > 0 else { return query.isEmpty ? "" : "0" }
        return "\(matchIndex + 1)/\(matchCount)"
    }

    private func navButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .glyphSize(.micro, weight: .semibold)
                .foregroundColor(matchCount > 0 ? theme.text.primary : theme.assignedColor("component.library.44.disabledForeground", fallback: theme.text.tertiary))
                .frame(width: NativeComponentInspectionStyle.metric(44, "height", 18, theme), height: NativeComponentInspectionStyle.metric(44, "height", 18, theme))
                .componentInspectionSurface(44, background: .clear, radius: theme.radius.small)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(matchCount == 0)
    }
}
