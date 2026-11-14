//
//  SettingsIndicators.swift
//  osaurus
//
//  Progress and loading placeholders for Management pages.
//

import SwiftUI

/// The one indeterminate loading glyph, on the progress recipe.
struct SettingsSpinner: View {
    enum Size {
        /// 12pt, inside text-height chrome (chips, fields, compact buttons).
        case mini
        /// 16pt, beside a row or a status line.
        case small
        /// 32pt, centred in an empty or loading page.
        case large

        var controlSize: ControlSize {
            switch self {
            case .mini: .mini
            case .small: .small
            case .large: .large
            }
        }
    }

    var size: Size = .small
    /// Data-driven ink (a status or button foreground); defaults to the recipe accent.
    var tint: Color?

    var body: some View {
        ProgressView()
            .controlSize(size.controlSize)
            .assignedProgressIndicator(tintOverride: tint)
    }
}

/// A thin progress track. `value` is clamped to 0…1; `nil` is indeterminate
/// (a sliding segment, static under Reduce Motion).
struct SettingsProgressBar: View {
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var baseComponentEnabled
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(12, enabled: baseComponentEnabled) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.inspectorForceReducedMotion) private var forceReducedMotion
    @State private var sweeping = false

    let value: Double?
    /// Fill color; defaults to the accent.
    var tint: Color?
    var height: CGFloat = 4

    private static let indeterminateFraction = 0.3
    private var clampedValue: Double {
        guard let value, !value.isNaN else { return 0 }
        return min(max(value, 0), 1)
    }
    private var fillColor: Color {
        baseComponentEnabled && tint != nil ? tint! : theme.assignedColor(baseComponentEnabled ? "component.library.12.accent" : "component.library.12.disabledForeground", fallback: tint ?? theme.action.primary.default.background)
    }
    private var trackColor: Color {
        guard baseComponentEnabled else {
            return theme.assignedColor("component.library.12.disabledBackground", fallback: theme.surface.subtle)
        }
        return theme.emptyTrack(theme.assignedColor("component.library.12.selected", fallback: theme.surface.subtle))
    }
    private var reducesMotion: Bool {
        reduceMotion || forceReducedMotion
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: theme.radius.medium).fill(trackColor)
                if value == nil {
                    let segment = geometry.size.width * Self.indeterminateFraction
                    RoundedRectangle(cornerRadius: theme.radius.medium)
                        .fill(fillColor)
                        .frame(width: segment)
                        .offset(x: sweeping && !reducesMotion ? geometry.size.width - segment : 0)
                } else {
                    RoundedRectangle(cornerRadius: theme.radius.medium)
                        .fill(fillColor)
                        .frame(width: max(0, geometry.size.width * clampedValue))
                }
            }
            .clipped()
        }
        .frame(height: theme.catalogMetric("trackHeight", fallback: height))
        .animation(reducesMotion ? nil : theme.motion.standard, value: clampedValue)
        .onAppear {
            guard value == nil, !reducesMotion else { return }
            withAnimation(theme.motion.loop(.easeInOut, duration: 1.1, autoreverses: true)) { sweeping = true }
        }
        .accessibilityElement()
        .accessibilityValue(value == nil ? Text(L("In progress")) : Text(verbatim: "\(Int(clampedValue * 100))%"))
    }
}

/// A placeholder block for skeleton cards while content loads. `width: nil`
/// fills the row.
struct SettingsSkeletonBar: View {
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var baseComponentEnabled
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(12, enabled: baseComponentEnabled) }

    var width: CGFloat?
    var height: CGFloat = 10

    var body: some View {
        RoundedRectangle(cornerRadius: min(theme.radius.small, height / 2), style: .continuous)
            .fill(theme.surface.subtle)
            .frame(width: width, height: theme.catalogMetric("height", fallback: height))
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}

/// Pulses a skeleton while it loads. Static under Reduce Motion.
private struct SettingsShimmerModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.inspectorForceReducedMotion) private var forceReducedMotion

    let delay: Double
    private var reducesMotion: Bool {
        reduceMotion || forceReducedMotion
    }
    @ViewBuilder func body(content: Content) -> some View {
        if reducesMotion { content }
        else { content.modifier(SettingsActiveShimmer(delay: delay)) }
    }
}

/// Separate identity removes an already-running repeat when Reduce Motion
/// changes while the skeleton is visible.
private struct SettingsActiveShimmer: ViewModifier {
    @Environment(\.theme) private var theme
    let delay: Double
    @State private var dimmed = false
    func body(content: Content) -> some View {
        content.opacity(dimmed ? 0.55 : 1).onAppear {
            withAnimation(theme.motion.loop(.easeInOut, duration: 0.9, autoreverses: true, delay: delay)) { dimmed = true }
        }
    }
}

extension View {
    /// The one loading pulse for skeleton cards.
    func settingsShimmer(delay: Double = 0) -> some View {
        modifier(SettingsShimmerModifier(delay: delay))
    }
}
