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

    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(45, enabled: inspectionEnabled) }

    // MARK: - State

    /// Entrance animation state
    @State private var isAppeared = false

    /// Pulsing state for the status dot
    @State private var dotPulse = false

    // MARK: - Constants

    private let cornerRadius: CGFloat = 14

    private var statusColor: Color { isProcessing ? theme.status.warning.foreground : theme.status.info.foreground }
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

    private var badgeHeight: CGFloat { max(NativeComponentInspectionStyle.metric(45, "height", 28, theme), theme.lineHeight(.caption) + 2 * NativeComponentInspectionStyle.metric(45, "padding", theme.space.s4, theme)) }

    public var body: some View {
        Group {

        ZStack {
            if isProcessing {
                SettingsSpinner(tint: theme.text.primary)
                    .accessibilityHidden(true)
            } else {
                WaveformView(
                    level: audioLevel,
                    style: .bars,
                    barCount: 22,
                    primaryColor: theme.assignedColor("component.library.45.accent", fallback: FixedPalette.onMedia),
                    isActive: isActive
                )
                .frame(width: 240, height: 26)
            }

            HStack(spacing: theme.space.s0) {
                VoiceOverlayIconButton(icon: "xmark", label: "Cancel (Esc)") { onCancel?() }
                Spacer(minLength: 0)
                if showsStopButton && !isProcessing {
                    VoiceOverlayIconButton(icon: "stop.fill", label: "Stop and insert") { onDone?() }
                }
            }
        }
        .frame(height: 30)
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.45.elements.layout.transcriptionOverlayView.body.paddingX", inheriting: NativeComponentInspectionStyle.metric(45, "padding", theme.space.s16, theme))).catalogLayoutTarget("component.library.45.elements.layout.transcriptionOverlayView.body.paddingX")
        // Push the row below the badge that straddles the top border.
        .padding(.top, badgeHeight / 2 + 14)
        .padding(.bottom, theme.space.s16)
        .frame(width: 320)
        .modifier(OverlayBackground(cornerRadius: cornerRadius))
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
            withAnimation(theme.motion.quick) {
                isAppeared = true
            }
            dotPulse = true
        }
    
        }.environment(\.theme, theme)
}

    // MARK: - Subviews

    /// Pulsing dot + status label, rendered as an opaque pill so it reads
    /// cleanly where it cuts through the card's top border.
    private var statusBadge: some View {
        HStack(spacing: theme.catalogLayoutMetric("component.library.45.elements.layout.transcriptionOverlayView.statusBadge.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(45, "gap", theme.space.s6, theme))) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .scaleEffect(dotPulse ? 1.3 : 0.85)
                .opacity(dotPulse ? 1.0 : 0.55)
                .animation(theme.motion.loop(.easeInOut, duration: 0.8, autoreverses: true), value: dotPulse)

            Text(statusText, bundle: .module)
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.smallLabel)
                .foregroundColor(theme.assignedColor("component.library.45.foreground", fallback: FixedPalette.onMedia))
        }.catalogLayoutTarget("component.library.45.elements.layout.transcriptionOverlayView.statusBadge.horizontalGap")
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.45.elements.layout.transcriptionOverlayView.statusBadge.paddingX", inheriting: NativeComponentInspectionStyle.metric(45, "padding", theme.space.s14, theme))).catalogLayoutTarget("component.library.45.elements.layout.transcriptionOverlayView.statusBadge.paddingX")
        .frame(height: badgeHeight)
        .modifier(BadgeBackground(tint: statusColor))
    }
}

// MARK: - Badge Background

/// Opaque status badge capsule tinted with the state color. No Liquid Glass:
/// the base window material is the only translucent layer in the app.
private struct BadgeBackground: ViewModifier {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(45, enabled: inspectionEnabled) }
    let tint: Color

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: NativeComponentInspectionStyle.metric(45, "radius", 14, theme)).fill(theme.assignedColor("component.library.45.background", fallback: FixedPalette.mediaScrim(0.85))))
            .background(Capsule().fill(theme.assignedColor("component.library.45.background", fallback: theme.wash(behind: tint))))
            .clipShape(RoundedRectangle(cornerRadius: NativeComponentInspectionStyle.metric(45, "radius", 14, theme)))
            .overlay(RoundedRectangle(cornerRadius: NativeComponentInspectionStyle.metric(45, "radius", 14, theme)).strokeBorder(theme.assignedColor("component.library.45.border", fallback: theme.rule(around: tint)), lineWidth: theme.stroke.default))
    }
}

// MARK: - Overlay Background

/// Opaque dark HUD card (independent of the app theme) with an accent border
/// and a soft shadow. Reads cleanly on both light and dark desktops.
private struct OverlayBackground: ViewModifier {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(45, enabled: inspectionEnabled) }
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: NativeComponentInspectionStyle.metric(45, "radius", cornerRadius, theme), style: .continuous)
        content
            .background(shape.fill(theme.assignedColor("component.library.45.background", fallback: FixedPalette.mediaScrim(0.8))))
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(theme.assignedColor("component.library.45.border", fallback: theme.border.focus), lineWidth: theme.stroke.default)
            )
            .themeElevation(theme.elevation.raised)
    }
}

// MARK: - Preview

#if DEBUG
    struct TranscriptionOverlayView_Previews: PreviewProvider {
        @MainActor private static var theme: any ThemeProtocol { ThemeManager.shared.currentTheme }

        static var previews: some View {
            ZStack {
                CustomizableTheme.dark().surface.canvas
                    .ignoresSafeArea()

                VStack(spacing: theme.space.s32) {
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
                .padding(theme.space.s40)
            }
            .frame(width: 450, height: 250)
        }
    }
#endif
