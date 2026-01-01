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

    // MARK: - State

    /// Entrance animation state
    @State private var isAppeared = false

    /// Hover state for close button
    @State private var isCloseHovered = false

    // MARK: - Constants

    private let cornerRadius: CGFloat = 14

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
        HStack(spacing: 14) {
            // Voice status indicator
            VoiceStatusIndicator(
                state: .listening,
                showLabel: true,
                compact: false
            )
            .fixedSize()

            // Waveform visualization - compact and centered
            WaveformView(
                level: audioLevel,
                style: .bars,
                barCount: 8,
                isActive: isActive
            )
            .frame(width: 56, height: 20)

            // Close button
            Button(action: { onDone?() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isCloseHovered ? theme.primaryText : theme.tertiaryText)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(isCloseHovered ? theme.secondaryBackground : theme.tertiaryBackground)
                    )
            }
            .buttonStyle(.plain)
            .scaleEffect(isCloseHovered ? 1.05 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isCloseHovered)
            .onHover { hovering in
                isCloseHovered = hovering
            }
            .help("Done (Esc)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .fixedSize()
        .background(overlayBackground)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(borderOverlay)
        .shadow(color: theme.shadowColor.opacity(0.15), radius: 12, x: 0, y: 4)
        // Subtle entrance animation
        .scaleEffect(isAppeared ? 1.0 : 0.95)
        .opacity(isAppeared ? 1.0 : 0)
        .onAppear {
            withAnimation(.easeOut(duration: 0.2)) {
                isAppeared = true
            }
        }
    }

    // MARK: - Border Overlay

    private var borderOverlay: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(theme.cardBorder, lineWidth: 1)
    }

    // MARK: - Background

    private var overlayBackground: some View {
        ZStack {
            // Frosted glass effect
            if #available(macOS 13.0, *) {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(theme.cardBackground.opacity(0.95))
            }

            // Tint overlay for depth
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
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
