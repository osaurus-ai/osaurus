//
//  TranscriptionOverlayView.swift
//  osaurus
//
//  Floating overlay UI for Transcription Mode.
//  Uses the app's design system and existing voice components.
//

import SwiftUI

/// Overlay view for transcription mode - uses existing voice components
public struct TranscriptionOverlayView: View {
    /// Current audio level (0.0 to 1.0)
    let audioLevel: Float

    /// Whether transcription is currently active
    let isActive: Bool

    /// Callback when user presses Done
    var onDone: (() -> Void)?

    /// Callback when user presses Cancel
    var onCancel: (() -> Void)?

    @Environment(\.theme) private var theme

    public init(
        audioLevel: Float,
        isActive: Bool,
        onDone: (() -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self.audioLevel = audioLevel
        self.isActive = isActive
        self.onDone = onDone
        self.onCancel = onCancel
    }

    public var body: some View {
        HStack(spacing: 16) {
            // Voice status indicator (uses existing component)
            VoiceStatusIndicator(
                state: .listening,
                showLabel: true,
                compact: false
            )
            .fixedSize()

            // Waveform visualization (uses existing component)
            WaveformView(
                level: audioLevel,
                style: .bars,
                barCount: 10,
                isActive: isActive
            )
            .frame(width: 80, height: 24)

            Spacer(minLength: 16)

            // Done button
            Button(action: { onDone?() }) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Done")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.accentColor)
                )
            }
            .buttonStyle(.plain)
            .fixedSize()

            // Cancel button
            Button(action: { onCancel?() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(theme.tertiaryBackground)
                    )
            }
            .buttonStyle(.plain)
            .help("Cancel (Esc)")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .fixedSize()
        .background(overlayBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(theme.cardBorder, lineWidth: 1)
        )
        .shadow(color: theme.shadowColor.opacity(0.15), radius: 12, x: 0, y: 4)
    }

    // MARK: - Background

    private var overlayBackground: some View {
        ZStack {
            // Frosted glass effect
            if #available(macOS 13.0, *) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThinMaterial)
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(theme.cardBackground.opacity(0.95))
            }

            // Tint overlay
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.cardBackground.opacity(0.85))
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct TranscriptionOverlayView_Previews: PreviewProvider {
        static var previews: some View {
            ZStack {
                Color(hex: "0f0f10")
                    .ignoresSafeArea()

                VStack(spacing: 30) {
                    // Active with audio
                    TranscriptionOverlayView(
                        audioLevel: 0.6,
                        isActive: true,
                        onDone: { print("Done") },
                        onCancel: { print("Cancel") }
                    )

                    // Active with low audio
                    TranscriptionOverlayView(
                        audioLevel: 0.15,
                        isActive: true,
                        onDone: { print("Done") },
                        onCancel: { print("Cancel") }
                    )
                }
                .padding(40)
            }
            .frame(width: 450, height: 250)
        }
    }
#endif
