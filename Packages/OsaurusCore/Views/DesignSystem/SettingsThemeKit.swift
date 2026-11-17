//
//  SettingsThemeKit.swift
//  osaurus
//
//  Kit pieces for editing themes:
//
//  - `SettingsSwatchPicker`    curated color circles plus a Custom… well
//  - `SettingsFontPicker`      System, then curated installed families
//  - `SettingsThemePreview`    real kit components painted by a given theme
//  - `SettingsThemeCardHero`   a theme's canvas, text and accents, for cards
//  - `SettingsJSONEditor`      monospaced editor above its findings
//

import AppKit
import SwiftUI

// MARK: - Swatch Picker

/// One-of-several colors as circles, with a trailing Custom… well. The
/// circles show the color as it will render (already adjusted), so the
/// user sees the real result rather than the raw pick.
struct SettingsSwatchPicker: View {
    @Environment(\.theme) private var theme

    struct Swatch: Identifiable {
        let id: String
        /// Already localized.
        let label: String
        let color: Color
    }

    let swatches: [Swatch]
    /// The chosen swatch id, or nil while the custom color is chosen.
    @Binding var selection: String?
    /// The raw custom pick (`#RRGGBB`).
    @Binding var customColor: String
    /// The custom color as it will render.
    var customPreview: Color?

    private var diameter: CGFloat { theme.controlSize.compactHeight - theme.space.s4 }

    var body: some View {
        HStack(spacing: theme.space.s8) {
            ForEach(swatches) { swatch in
                Button {
                    selection = swatch.id
                } label: {
                    circle(swatch.color, selected: selection == swatch.id)
                }
                .buttonStyle(.plain)
                .help(Text(verbatim: swatch.label))
                .accessibilityLabel(Text(verbatim: swatch.label))
                .accessibilityAddTraits(selection == swatch.id ? .isSelected : [])
            }
            ThemeHairlineDivider(axis: .vertical)
                .frame(height: diameter)
            if selection == nil, let customPreview {
                circle(customPreview, selected: true)
                    .accessibilityLabel(Text("Custom color", bundle: .module))
            }
            ColorPicker(
                selection: Binding(
                    get: { Color(themeHex: customColor) },
                    set: { color in
                        customColor = Self.hex(color) ?? customColor
                        selection = nil
                    }
                ),
                supportsOpacity: false
            ) {
                Text("Custom…", bundle: .module)
            }
            .labelsHidden()
            .help(Text("Custom color", bundle: .module))
        }
    }

    private func circle(_ color: Color, selected: Bool) -> some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .overlay(Circle().strokeBorder(theme.border.subtle, lineWidth: theme.stroke.default))
            .padding(theme.space.s2)
            .overlay(
                Circle().strokeBorder(selected ? theme.border.focus : Color.clear, lineWidth: theme.stroke.focus)
            )
            .contentShape(Circle())
            .animation(theme.motion.quick, value: selected)
    }

    /// `#RRGGBB` in sRGB.
    static func hex(_ color: Color) -> String? {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }
}

// MARK: - Font Picker

/// System first, then the curated readable families that are installed,
/// then the current value when it is something else (set through JSON or
/// carried over from Classic).
struct SettingsFontPicker: View {
    enum Kind {
        case ui
        case code
    }

    let kind: Kind
    @Binding var selection: String

    static let curatedUI = ["Atkinson Hyperlegible", "Lexend", "OpenDyslexic", "Inter", "IBM Plex Sans", "SF Mono"]
    static let curatedCode = ["Menlo", "JetBrains Mono", "IBM Plex Mono", "Fira Code"]

    static func installedFamilies(_ kind: Kind) -> [String] {
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        let curated = kind == .ui ? curatedUI : curatedCode
        return curated.filter { $0 == "SF Mono" || installed.contains($0) }
    }

    private var options: [SettingsPickerRow<String>.Option] {
        var families = Self.installedFamilies(kind)
        if selection != ThemeReadability.systemFont, !families.contains(selection) { families.append(selection) }
        return [.init(ThemeReadability.systemFont, "System")] + families.map { .init($0, $0, verbatim: true) }
    }

    var body: some View {
        SettingsMenuPicker(selection: $selection, options: options)
    }
}

// MARK: - Theme Preview

/// A compact preview built from real kit components (buttons, field,
/// toggle row, chat bubbles), painted by `theme` rather than the window's.
struct SettingsThemePreview: View {
    let theme: any ThemeProtocol
    /// Already localized ("Light", "Dark").
    var caption: String?

    var body: some View {
        SettingsThemePreviewBody(caption: caption)
            .environment(\.theme, theme)
            .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }
}

private struct SettingsThemePreviewBody: View {
    @Environment(\.theme) private var theme
    var caption: String?
    @State private var text = ""
    @State private var isOn = true

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            if let caption {
                Text(verbatim: caption)
                    .font(SettingsFont.chip)
                    .foregroundColor(theme.text.tertiary)
            }
            VStack(alignment: .leading, spacing: theme.space.s4) {
                Text("Good evening", bundle: .module)
                    .font(SettingsFont.cardTitle)
                    .foregroundColor(theme.text.primary)
                Text("Secondary text reads clearly.", bundle: .module)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.secondary)
                Text("A link", bundle: .module)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.link)
            }
            HStack(alignment: .bottom, spacing: theme.space.s8) {
                Spacer(minLength: theme.space.s16)
                Text("Summarize my notes", bundle: .module)
                    .textStyle(.chatBody)
                    .foregroundColor(theme.text.primary)
                    .padding(.horizontal, theme.space.s12)
                    .padding(.vertical, theme.space.s8)
                    .background(theme.chat.userBackground, in: RoundedRectangle(cornerRadius: theme.radius.bubble, style: .continuous))
            }
            Text("Here are three themes from this week.", bundle: .module)
                .textStyle(.chatBody)
                .foregroundColor(theme.text.primary)
                .padding(.horizontal, theme.space.s12)
                .padding(.vertical, theme.space.s8)
                .background(theme.chat.assistantBackground, in: RoundedRectangle(cornerRadius: theme.radius.bubble, style: .continuous))
            SettingsTextField(placeholder: L("Message"), text: $text)
            SettingsToggle(title: "Notifications", isOn: $isOn)
                .settingsChrome(.surface)
            HStack(spacing: theme.settingsControlGap) {
                SettingsButton(.secondary, "Cancel") {}
                SettingsButton(.primary, "Save") {}
                Spacer(minLength: 0)
                StatusChip(L("New"), tone: .accent)
            }
        }
        .padding(theme.settingsCardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface.canvas, in: RoundedRectangle(cornerRadius: theme.radius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.large, style: .continuous)
                .strokeBorder(theme.border.default, lineWidth: theme.stroke.default)
        )
        .allowsHitTesting(false)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Theme Card Hero

/// The top of a theme's library card: its canvas with a text sample and
/// accent chips, side by side for each mode it supports.
struct SettingsThemeCardHero: View {
    @Environment(\.theme) private var theme
    /// One theme per mode the theme supports, light first.
    let modes: [any ThemeProtocol]

    var body: some View {
        HStack(spacing: theme.space.s0) {
            ForEach(Array(modes.enumerated()), id: \.offset) { _, mode in
                tile(mode)
            }
        }
        .frame(height: theme.space.s64 + theme.space.s16)
        .accessibilityHidden(true)
    }

    private func tile(_ mode: any ThemeProtocol) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s6) {
            Text("Aa", bundle: .module)
                .font(SettingsFont.cardTitle)
                .foregroundColor(mode.text.primary)
            HStack(spacing: theme.space.s4) {
                Capsule().fill(mode.text.secondary).frame(width: theme.space.s32, height: theme.space.s4)
                Capsule().fill(mode.text.tertiary).frame(width: theme.space.s16, height: theme.space.s4)
            }
            Spacer(minLength: 0)
            HStack(spacing: theme.space.s4) {
                Circle().fill(mode.action.primary.default.background)
                    .frame(width: theme.space.s16, height: theme.space.s16)
                Circle().fill((mode.action.brand ?? mode.action.primary).default.background)
                    .frame(width: theme.space.s16, height: theme.space.s16)
                Circle().fill(mode.surface.subtle)
                    .overlay(Circle().strokeBorder(mode.border.default, lineWidth: mode.stroke.default))
                    .frame(width: theme.space.s16, height: theme.space.s16)
            }
        }
        .padding(theme.space.s12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(mode.surface.canvas)
    }
}

// MARK: - JSON Editor

/// A monospaced editor with the validator's findings listed below it.
struct SettingsJSONEditor: View {
    @Environment(\.theme) private var theme

    struct Finding: Identifiable {
        enum Severity {
            case error
            case warning
        }
        let id: String
        let severity: Severity
        /// Already localized.
        let message: String
        var line: Int?
    }

    @Binding var text: String
    let findings: [Finding]
    var minHeight: CGFloat = 320
    var maxHeight: CGFloat? = 420

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            SettingsTextEditor(
                text: $text, minHeight: minHeight, maxHeight: maxHeight, monospaced: true,
                isInvalid: findings.contains { $0.severity == .error }
            )
            if findings.isEmpty {
                SettingsFindingRow(severity: .ok, title: L("No problems found"))
            } else {
                ForEach(findings) { finding in
                    SettingsFindingRow(
                        severity: finding.severity == .error ? .blocked : .warning,
                        title: finding.message,
                        code: finding.line.map { L("line \($0)") }
                    )
                }
            }
        }
    }
}
