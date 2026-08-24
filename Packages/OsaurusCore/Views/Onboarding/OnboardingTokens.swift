//
//  OnboardingTokens.swift
//  osaurus
//
//  Host-level onboarding constants: the fixed window size and step slide
//  offsets. Visual design tokens for the redesigned flow live in
//  Views/Onboarding/DesignSystem/OnboardingDesign.swift.
//

import SwiftUI

// MARK: - Layout Tokens

enum OnboardingMetrics {
    // Window — fixed for every step (Figma: 1000×640, dark-only)
    static let windowWidth: CGFloat = 1000
    static let windowHeight: CGFloat = 640

    /// Horizontal offset used by step slide transitions. Sized to the full
    /// window width so views slide cleanly off-screen instead of overlapping.
    static let slideOffset: CGFloat = windowWidth

    /// Horizontal offset used by substate slide transitions inside a step
    /// (e.g. ConfigureAI's provider drill-in). Sized to the right panel
    /// (window − left column) so substates slide off the panel edge.
    static let substateSlideOffset: CGFloat = windowWidth - OnboardingLayout.leftColumnWidth
}

// MARK: - Delayed Appear Helper

extension View {
    /// Runs `action` on the main actor after `delay` seconds when the view
    /// appears. Cancelled automatically if the view disappears before the
    /// delay elapses (unlike `DispatchQueue.main.asyncAfter`).
    func onAppearAfter(_ delay: Double, perform action: @escaping () -> Void) -> some View {
        task {
            let nanos = UInt64(max(0, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            action()
        }
    }
}
