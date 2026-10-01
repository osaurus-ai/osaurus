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
                .font(.system(size: 16))
                .foregroundColor(isComplete ? theme.successColor : theme.tertiaryText)
                .animation(.easeOut(duration: 0.2), value: isComplete)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.primaryText)

                if let description {
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                }
            }

            Spacer()

            if !isComplete, let action {
                Button(action: action) {
                    Text("Fix", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(isHovered ? .white : theme.accentColor)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            ZStack {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(isHovered ? theme.accentColor : Color.clear)
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(theme.accentColor, lineWidth: 1)
                            }
                        )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.15)) {
                        isHovered = hovering
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: SettingsGroupMetrics.rowMinHeight)
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
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)

            Text(LocalizedStringKey(text), bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Pulsing Indicator

/// Continuous opacity pulse for "recording" dots. Holds the steady state
/// under Reduce Motion.
struct VoicePulsingIndicatorModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(isPulsing ? 0.4 : 1.0)
            .animation(
                .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear {
                if !reduceMotion {
                    isPulsing = true
                }
            }
    }
}
