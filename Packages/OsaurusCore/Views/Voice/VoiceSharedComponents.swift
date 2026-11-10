//
//  VoiceSharedComponents.swift
//  osaurus
//
//  Small building blocks shared by the Voice settings tabs (Chat Voice,
//  Transcription, Wake Word): the setup-requirement checklist row and the
//  accent-tinted info callout. Kept in one place so every tab renders the
//  same chrome instead of carrying a private copy.
//

import SwiftUI

// MARK: - Requirement Row

/// One line of a "Setup Required" checklist: status icon, title, optional
/// description, and a Fix button while the requirement is unmet. Flat — it
/// is always a row inside a `SettingsSection` group.
struct VoiceRequirementRow: View {
    @Environment(\.theme) private var theme

    let title: String
    var description: String? = nil
    let isComplete: Bool
    var action: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                .glyphSize(16)
                .foregroundColor(isComplete ? theme.status.success.foreground : theme.text.tertiary)
                .animation(theme.motion.quick, value: isComplete)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SettingsFont.rowTitle)
                    .foregroundColor(theme.text.primary)

                if let description {
                    Text(description)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                }
            }

            Spacer()

            if !isComplete, let action {
                Button(action: action) {
                    Text("Fix", bundle: .module)
                        .font(SettingsFont.compactLabel)
                }
                .assignedSettingsButtonStyle(.secondary, size: .compact)
                .onHover { hovering in
                    withAnimation(theme.motion.quick) {
                        isHovered = hovering
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: theme.settingsRowMinHeight)
    }
}

// MARK: - Info Box

/// Informational caption row used under toggles across the Voice tabs.
/// Flat — it is always a row inside a `SettingsSection` group. Takes a
/// localization key.
struct VoiceInfoBox: View {
    @Environment(\.theme) private var theme

    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .glyphSize(11)
                .foregroundColor(theme.text.tertiary)

            Text(LocalizedStringKey(text), bundle: .module)
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Pulsing Indicator

/// Continuous opacity pulse for "recording" dots. Holds the steady state
/// under Reduce Motion.
struct VoicePulsingIndicatorModifier: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(isPulsing ? 0.4 : 1.0)
            .animation(
                theme.motion.loop(.easeInOut, duration: 0.8, autoreverses: true),
                value: isPulsing
            )
            .onAppear {
                if !reduceMotion {
                    isPulsing = true
                }
            }
    }
}
