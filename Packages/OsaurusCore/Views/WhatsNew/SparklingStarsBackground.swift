//
//  SparklingStarsBackground.swift
//  osaurus
//
//  A soft gradient with a single large sparkle centered in the frame
//  as a static fallback background for What's New
//  pages without an image

import SwiftUI

struct SparklingStarsBackground: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    theme.accentColor.opacity(0.55),
                    theme.accentColor.opacity(0.20),
                    theme.primaryBackground,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Image(systemName: "sparkles.2")
                .font(.system(size: 96, weight: .light))
                .foregroundStyle(theme.primaryText.opacity(0.9))
        }
    }
}
