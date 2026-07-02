//
//  SettingsPrimitives.swift
//  osaurus
//
//  Shared SwiftUI building blocks used by `ConfigurationView` and the
//  Server → Settings tab. Pulled out of `ConfigurationView.swift` so
//  both files (and any future settings panel) can reuse the same look
//  and feel without duplicating the styling.
//

import SwiftUI

// MARK: - Settings Section

struct SettingsSection<Content: View>: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let title: String
    let icon: String
    /// Settings-search landing anchor for section-level results (no single
    /// control to point at), e.g. Notifications or Legal.
    var anchorId: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(themeManager.currentTheme.accentColor)

                Text(LocalizedStringKey(title), bundle: .module)
                    .textCase(.uppercase)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(themeManager.currentTheme.secondaryText)
                    .tracking(0.5)
            }

            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(themeManager.currentTheme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(themeManager.currentTheme.cardBorder, lineWidth: 1)
                )
        )
        .settingsLandingAnchor(anchorId)
    }
}

// MARK: - Search Highlight

extension View {
    /// Wraps a control in a soft accent glow while it's the active search-result
    /// landing target — no border, just a halo that hugs the control's shape. A
    /// no-op when `active` is false. Driven by `settingsLandingAnchor`.
    func settingsSearchHighlight(_ active: Bool) -> some View {
        modifier(SettingsSearchHighlightModifier(active: active))
    }
}

private struct SettingsSearchHighlightModifier: ViewModifier {
    let active: Bool
    @ObservedObject private var themeManager = ThemeManager.shared

    /// 0 at rest, eased up to 1 and gently back to 0 once when the control
    /// becomes a match — a single soft breath layered over a faint persistent
    /// glow, so the matched control stays gently lit without any border.
    @State private var glow: CGFloat = 0

    /// Half the breath: rise over `breathDuration`, fall over `breathDuration`.
    private static let breathDuration: Double = 0.9

    private var glowOpacity: Double { active ? 0.22 + 0.5 * Double(glow) : 0 }
    private var glowRadius: CGFloat { active ? 6 + 14 * glow : 0 }

    func body(content: Content) -> some View {
        let theme = themeManager.currentTheme
        content
            // Rasterize the (possibly whole-card) content once per frame so the
            // animated glow blurs a single flattened layer, not every subview.
            .compositingGroup()
            // The glow follows the control's own (rounded) shape — no ring.
            .shadow(color: theme.accentColor.opacity(glowOpacity), radius: glowRadius)
            .animation(.easeOut(duration: 0.25), value: active)
            .onAppear { if active { firePulse() } }
            .onChange(of: active) { _, isActive in
                if isActive { firePulse() } else { glow = 0 }
            }
    }

    /// One smooth breath: ease the glow up, then — on completion — ease it back
    /// down to the resting glow. Using the completion handler (rather than a
    /// repeating / autoreversing animation) keeps the model value honest, so the
    /// glow can't snap or get stuck bright when it finishes.
    private func firePulse() {
        glow = 0
        withAnimation(.easeInOut(duration: Self.breathDuration)) {
            glow = 1
        } completion: {
            withAnimation(.easeInOut(duration: Self.breathDuration)) {
                glow = 0
            }
        }
    }
}

// MARK: - Settings Field

struct SettingsField<Content: View>: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let label: String
    var hint: String? = nil
    /// Settings-search landing anchor for the control. When a search result
    /// targets this id, the control scrolls into view and glows.
    var anchorId: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(label), bundle: .module)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(themeManager.currentTheme.secondaryText)

            // Glow the control itself, not the label/hint around it.
            content()
                .settingsLandingAnchor(anchorId)

            if let hint = hint {
                Text(LocalizedStringKey(hint), bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
            }
        }
    }
}

// MARK: - Settings Subsection

struct SettingsSubsection<Content: View>: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let label: String
    /// Settings-search landing anchor for this subsection.
    var anchorId: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Rectangle()
                    .fill(themeManager.currentTheme.accentColor)
                    .frame(width: 3, height: 14)
                    .clipShape(RoundedRectangle(cornerRadius: 1.5))

                Text(LocalizedStringKey(label), bundle: .module)
                    .textCase(.uppercase)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
                    .tracking(0.5)
            }

            content()
                .padding(.leading, 9)
        }
        .settingsLandingAnchor(anchorId)
    }
}

// MARK: - Styled Settings Text Field

struct StyledSettingsTextField: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let label: String
    @Binding var text: String
    let placeholder: String
    let help: String
    var anchorId: String? = nil

    @State private var isFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(label), bundle: .module)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(themeManager.currentTheme.primaryText)

            HStack(spacing: 10) {
                ZStack(alignment: .leading) {
                    if text.isEmpty && !placeholder.isEmpty {
                        Text(LocalizedStringKey(placeholder), bundle: .module)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(themeManager.currentTheme.placeholderText)
                            .allowsHitTesting(false)
                    }

                    TextField(
                        "",
                        text: $text,
                        onEditingChanged: { editing in
                            withAnimation(.easeOut(duration: 0.15)) {
                                isFocused = editing
                            }
                        }
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(themeManager.currentTheme.primaryText)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(themeManager.currentTheme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                isFocused
                                    ? themeManager.currentTheme.accentColor.opacity(0.5)
                                    : themeManager.currentTheme.inputBorder,
                                lineWidth: isFocused ? 1.5 : 1
                            )
                    )
            )
            .settingsLandingAnchor(anchorId)

            if !help.isEmpty {
                Text(LocalizedStringKey(help), bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Settings Slider Field

struct SettingsSliderField: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let label: String
    let help: String
    @Binding var text: String
    let range: ClosedRange<Float>
    let step: Float
    let defaultValue: Float
    let formatString: String
    var anchorId: String? = nil

    @State private var sliderValue: Float = 0
    @State private var isInitialized = false

    private var effectiveValue: Float {
        if let v = Float(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return min(max(v, range.lowerBound), range.upperBound)
        }
        return defaultValue
    }

    private var displayValue: String {
        String(format: formatString, effectiveValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(label), bundle: .module)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(themeManager.currentTheme.primaryText)

            HStack(spacing: 12) {
                Text(String(format: formatString, range.lowerBound))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
                    .frame(width: 28, alignment: .trailing)

                Slider(
                    value: $sliderValue,
                    in: range,
                    step: step
                )
                .tint(themeManager.currentTheme.accentColor)
                .onChange(of: sliderValue) { _, newValue in
                    guard isInitialized else { return }
                    text = String(format: formatString, newValue)
                }

                Text(String(format: formatString, range.upperBound))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
                    .frame(width: 28, alignment: .leading)

                Text(displayValue)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(themeManager.currentTheme.primaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(themeManager.currentTheme.inputBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(themeManager.currentTheme.inputBorder, lineWidth: 1)
                            )
                    )
                    .frame(width: 52)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(themeManager.currentTheme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(themeManager.currentTheme.inputBorder, lineWidth: 1)
                    )
            )
            .settingsLandingAnchor(anchorId)

            if !help.isEmpty {
                Text(LocalizedStringKey(help), bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            sliderValue = effectiveValue
            DispatchQueue.main.async {
                isInitialized = true
            }
        }
        .onChange(of: text) { _, _ in
            guard isInitialized else { return }
            let newEffective = effectiveValue
            if abs(sliderValue - newEffective) > step / 2 {
                sliderValue = newEffective
            }
        }
    }
}

// MARK: - Settings Stepper Field

struct SettingsStepperField: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let label: String
    let help: String
    @Binding var text: String
    let range: ClosedRange<Int>
    let step: Int
    let defaultValue: Int
    var anchorId: String? = nil

    @State private var isFocused = false

    private var effectiveValue: Int {
        if let v = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return min(max(v, range.lowerBound), range.upperBound)
        }
        return defaultValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(label), bundle: .module)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(themeManager.currentTheme.primaryText)

            HStack(spacing: 0) {
                ZStack(alignment: .leading) {
                    if text.isEmpty {
                        Text(String(defaultValue))
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(themeManager.currentTheme.placeholderText)
                            .allowsHitTesting(false)
                    }

                    TextField(
                        "",
                        text: $text,
                        onEditingChanged: { editing in
                            withAnimation(.easeOut(duration: 0.15)) {
                                isFocused = editing
                            }
                        }
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(themeManager.currentTheme.primaryText)
                }
                .padding(.horizontal, 12)

                Divider()
                    .frame(height: 20)

                HStack(spacing: 0) {
                    Button(action: decrement) {
                        Image(systemName: "minus")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(
                                effectiveValue <= range.lowerBound
                                    ? themeManager.currentTheme.tertiaryText
                                    : themeManager.currentTheme.primaryText
                            )
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(effectiveValue <= range.lowerBound)

                    Divider()
                        .frame(height: 20)

                    Button(action: increment) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(
                                effectiveValue >= range.upperBound
                                    ? themeManager.currentTheme.tertiaryText
                                    : themeManager.currentTheme.primaryText
                            )
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(effectiveValue >= range.upperBound)
                }
            }
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(themeManager.currentTheme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                isFocused
                                    ? themeManager.currentTheme.accentColor.opacity(0.5)
                                    : themeManager.currentTheme.inputBorder,
                                lineWidth: isFocused ? 1.5 : 1
                            )
                    )
            )
            .settingsLandingAnchor(anchorId)

            if !help.isEmpty {
                Text(LocalizedStringKey(help), bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(themeManager.currentTheme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func increment() {
        let newValue = min(effectiveValue + step, range.upperBound)
        text = String(newValue)
    }

    private func decrement() {
        let newValue = max(effectiveValue - step, range.lowerBound)
        text = String(newValue)
    }
}

// MARK: - Settings Toggle

struct SettingsToggle: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let title: String
    let description: String
    var badge: String? = nil
    /// Settings-search landing anchor for this toggle.
    var anchorId: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(LocalizedStringKey(title), bundle: .module)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(themeManager.currentTheme.primaryText)
                    if let badge {
                        Text(LocalizedStringKey(badge), bundle: .module)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(themeManager.currentTheme.accentColor)
                    }
                }
                Text(LocalizedStringKey(description), bundle: .module)
                    .font(.system(size: 11))
                    .foregroundStyle(themeManager.currentTheme.tertiaryText)
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .toggleStyle(SwitchToggleStyle(tint: themeManager.currentTheme.accentColor))
                .labelsHidden()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(themeManager.currentTheme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(themeManager.currentTheme.inputBorder, lineWidth: 1)
                )
        )
        .settingsLandingAnchor(anchorId)
    }
}

// MARK: - Settings Divider

struct SettingsDivider: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    var body: some View {
        Rectangle()
            .fill(themeManager.currentTheme.cardBorder)
            .frame(height: 1)
    }
}

// MARK: - Settings Button Style

struct SettingsButtonStyle: ButtonStyle {
    @ObservedObject private var themeManager = ThemeManager.shared
    let isPrimary: Bool
    let isDestructive: Bool

    init(isPrimary: Bool = false, isDestructive: Bool = false) {
        self.isPrimary = isPrimary
        self.isDestructive = isDestructive
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(
                isDestructive
                    ? .red
                    : (isPrimary ? .white : themeManager.currentTheme.primaryText)
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        isPrimary ? themeManager.currentTheme.accentColor : themeManager.currentTheme.tertiaryBackground
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isPrimary ? Color.clear : themeManager.currentTheme.inputBorder, lineWidth: 1)
                    )
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

// MARK: - Status Badge

/// Small status pill used by the Server → Settings panel to signal
/// whether a control is engine-ready, awaiting a runtime bridge, or
/// is host-owned future work. Mirrors the status tag system used by
/// the panel spec.
struct ServerSettingsStatusBadge: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    enum Status {
        case engineReady
        case partial
        case needsBridge
        case future
        case hostOwned

        var label: String {
            switch self {
            case .engineReady: return L("Live")
            case .partial: return L("Partial")
            case .needsBridge: return L("Planned")
            case .future: return L("Future")
            case .hostOwned: return L("Host")
            }
        }

        func color(theme: ThemeProtocol) -> Color {
            switch self {
            case .engineReady: return theme.successColor
            case .partial: return theme.warningColor
            case .needsBridge: return theme.warningColor
            case .future: return theme.tertiaryText
            case .hostOwned: return theme.accentColor
            }
        }
    }

    let status: Status

    var body: some View {
        let color = status.color(theme: themeManager.currentTheme)
        Text(LocalizedStringKey(status.label), bundle: .module)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
            .overlay(Capsule().stroke(color.opacity(0.25), lineWidth: 0.5))
    }
}
