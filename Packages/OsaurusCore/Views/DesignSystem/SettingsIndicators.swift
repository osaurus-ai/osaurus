//
//  SettingsIndicators.swift
//  osaurus
//
//  Progress and loading placeholders for Management pages.
//

import SwiftUI

/// A thin determinate progress track. `value` is clamped to 0…1.
struct SettingsProgressBar: View {
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var baseComponentEnabled
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(12, enabled: baseComponentEnabled) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if OSAURUS_DESIGN_SYSTEM
    @Environment(\.inspectorForceReducedMotion) private var forceReducedMotion
    #endif

    let value: Double
    /// Fill color; defaults to the accent.
    var tint: Color?
    var height: CGFloat = 4

    private var clampedValue: Double { value.isNaN ? 0 : min(max(value, 0), 1) }
    private var reducesMotion: Bool {
        #if OSAURUS_DESIGN_SYSTEM
        reduceMotion || forceReducedMotion
        #else
        reduceMotion
        #endif
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: theme.radius.medium).fill(theme.assignedColor(baseComponentEnabled ? "component.library.12.selected" : "component.library.12.disabledBackground", fallback: theme.surface.subtle))
                RoundedRectangle(cornerRadius: theme.radius.medium)
                    .fill(theme.assignedColor(baseComponentEnabled ? "component.library.12.accent" : "component.library.12.disabledForeground", fallback: tint ?? theme.action.primary.default.background))
                    .frame(width: max(0, geometry.size.width * clampedValue))
            }
        }
        .frame(height: theme.catalogMetric("trackHeight", fallback: height))
        .animation(reducesMotion ? nil : theme.motion.standard, value: clampedValue)
        .accessibilityElement()
        .accessibilityValue(Text(verbatim: "\(Int(clampedValue * 100))%"))
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
    #if OSAURUS_DESIGN_SYSTEM
    @Environment(\.inspectorForceReducedMotion) private var forceReducedMotion
    #endif

    let delay: Double
    private var reducesMotion: Bool {
        #if OSAURUS_DESIGN_SYSTEM
        reduceMotion || forceReducedMotion
        #else
        reduceMotion
        #endif
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
