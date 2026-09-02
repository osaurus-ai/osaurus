//
//  WhatsNewHeroBackground.swift
//  osaurus
//
//  Accent gradient with a single large glyph centered in the frame, used as
//  the hero background for What's New pages that don't supply an image. Each
//  page passes its own SF Symbol so the hero reflects the feature announced.
//

import SwiftUI

struct WhatsNewHeroBackground: View {
    @Environment(\.theme) private var theme

    /// SF Symbol drawn over the gradient. Defaults to a generic sparkle.
    var systemImage: String = "sparkles"

    /// Bundled asset-catalog image drawn instead of `systemImage` when set
    /// (e.g. the Osaurus logo).
    var assetImage: String? = nil

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

            if let assetImage {
                Image(assetImage, bundle: .module)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 96, height: 96)
                    .foregroundStyle(.white.opacity(0.95))
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 54, weight: .regular))
                    .foregroundStyle(.white.opacity(0.95))
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
                    .symbolRenderingMode(.hierarchical)
            }
        }
    }
}
