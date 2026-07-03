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

    /// Whether the transcript is being cleaned up by the LLM
    let isProcessing: Bool

    /// Whether to show an explicit Stop button (manual mode, or automatic with
    /// pause duration 0 — cases where transcription won't stop on its own)
    var showsStopButton: Bool = false

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

    /// Hover state for stop button
    @State private var isStopHovered = false

    /// Pulsing state for the status dot
    @State private var dotPulse = false

    // MARK: - Constants

    private let cornerRadius: CGFloat = 14

    private var statusColor: Color { isProcessing ? theme.warningColor : theme.accentColor }
    private var statusText: LocalizedStringKey { isProcessing ? "Processing" : "Listening" }

    public init(
        audioLevel: Float,
        isActive: Bool,
        isProcessing: Bool = false,
        showsStopButton: Bool = false,
        onDone: (() -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self.audioLevel = audioLevel
        self.isActive = isActive
        self.isProcessing = isProcessing
        self.showsStopButton = showsStopButton
        self.onDone = onDone
        self.onCancel = onCancel
    }

    private let badgeHeight: CGFloat = 28

    public var body: some View {
        ZStack {
            // Live audio spectrum — the single waveform, centered in the card.
            WaveformView(
                level: audioLevel,
                style: .bars,
                barCount: 22,
                primaryColor: .white,
                isActive: isActive && !isProcessing
            )
            .frame(width: 240, height: 26)
            .opacity(isProcessing ? 0 : 1)

            // Stop / Cancel controls share the waveform's horizontal axis,
            // pinned to the card's left and right edges.
            HStack(spacing: 0) {
                cancelButton
                Spacer(minLength: 0)
                if showsStopButton && !isProcessing {
                    stopButton
                }
            }
        }
        .frame(height: 30)
        .padding(.horizontal, 16)
        // Push the row below the badge that straddles the top border.
        .padding(.top, badgeHeight / 2 + 14)
        .padding(.bottom, 16)
        .frame(width: 320)
        .modifier(OverlayGlassBackground(cornerRadius: cornerRadius))
        // The status badge straddles the top border like a notch.
        .overlay(alignment: .top) {
            statusBadge
                .offset(y: -badgeHeight / 2)
        }
        // Reserve room above the card so the straddling badge isn't clipped.
        .padding(.top, badgeHeight / 2)
        // Subtle entrance animation
        .scaleEffect(isAppeared ? 1.0 : 0.95)
        .opacity(isAppeared ? 1.0 : 0)
        .onAppear {
            withAnimation(.easeOut(duration: 0.2)) {
                isAppeared = true
            }
            dotPulse = true
        }
    }

    // MARK: - Subviews

    /// Pulsing dot + status label, rendered as an opaque pill so it reads
    /// cleanly where it cuts through the card's top border.
    private var statusBadge: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .scaleEffect(dotPulse ? 1.3 : 0.85)
                .opacity(dotPulse ? 1.0 : 0.55)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: dotPulse)

            Text(statusText, bundle: .module)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 14)
        .frame(height: badgeHeight)
        .modifier(BadgeGlassBackground(tint: statusColor))
    }

    /// Stop & insert — only shown when transcription won't stop on its own.
    private var stopButton: some View {
        Button(action: { onDone?() }) {
            Image(systemName: "stop.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white.opacity(isStopHovered ? 1.0 : 0.7))
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(Color.white.opacity(isStopHovered ? 0.22 : 0.12))
                )
        }
        .buttonStyle(.plain)
        .scaleEffect(isStopHovered ? 1.05 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isStopHovered)
        .onHover { hovering in
            isStopHovered = hovering
        }
        .localizedHelp("Stop and insert")
    }

    /// Cancel — discards the transcript.
    private var cancelButton: some View {
        Button(action: { onCancel?() }) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(isCloseHovered ? 1.0 : 0.7))
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(Color.white.opacity(isCloseHovered ? 0.22 : 0.12))
                )
        }
        .buttonStyle(.plain)
        .scaleEffect(isCloseHovered ? 1.05 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isCloseHovered)
        .onHover { hovering in
            isCloseHovered = hovering
        }
        .localizedHelp("Cancel (Esc)")
    }
}

// MARK: - Badge Glass Background

/// Liquid Glass capsule for the status badge (macOS 26+), tinted with the
/// state color, with a themed translucent fallback on earlier systems.
private struct BadgeGlassBackground: ViewModifier {
    @Environment(\.theme) private var theme
    let tint: Color

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .glassEffect(.regular.tint(tint.opacity(0.28)), in: Capsule())
                .overlay(Capsule().strokeBorder(tint.opacity(0.5), lineWidth: 1))
        } else {
            content
                .background(Capsule().fill(Color.black.opacity(0.85)))
                .background(Capsule().fill(tint.opacity(0.22)))
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(tint.opacity(0.5), lineWidth: 1))
        }
    }
}

// MARK: - Glass Background

/// Applies Liquid Glass to the overlay on macOS 26+, with a clean themed
/// fallback (solid rounded card + border + shadow) on earlier systems.
private struct OverlayGlassBackground: ViewModifier {
    @Environment(\.theme) private var theme
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // A consistent dark HUD (independent of the app theme) reads cleanly on
        // both light and dark desktops and avoids the washed-out "outcast" that a
        // translucent white fill produced on light themes.
        if #available(macOS 26.0, *) {
            content
                .background(shape.fill(Color.black.opacity(0.55)))
                .glassEffect(.regular, in: shape)
                .overlay(
                    shape.strokeBorder(theme.accentColor.opacity(0.55), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 4)
        } else {
            content
                .background(shape.fill(Color.black.opacity(0.8)))
                .clipShape(shape)
                .overlay(
                    shape.strokeBorder(theme.accentColor.opacity(0.55), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 3)
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
