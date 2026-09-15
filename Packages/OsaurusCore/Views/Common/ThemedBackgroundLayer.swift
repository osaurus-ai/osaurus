//
//  ThemedBackgroundLayer.swift
//  osaurus
//
//  Shared background layer used by chat windows.
//  Renders solid, gradient, or image backgrounds from the active theme config.
//

import SwiftUI

struct ThemedBackgroundLayer: View {
    let cachedBackgroundImage: NSImage?

    @Environment(\.theme) private var theme

    /// Fills edge to edge. The opaque chat panel is masked by AppKit at the
    /// system window radius, so this layer must not clip itself to a guessed
    /// radius: macOS 26 and 27 use different corners, and a hardcoded 24pt
    /// left the content clipped tighter than the frame on 27.
    var body: some View {
        backgroundLayer
    }

    @ViewBuilder
    private var backgroundLayer: some View {
        if let customTheme = theme.customThemeConfig {
            switch customTheme.background.type {
            case .solid:
                Color(themeHex: customTheme.background.solidColor ?? customTheme.colors.primaryBackground)

            case .gradient:
                let colors = (customTheme.background.gradientColors ?? ["#000000", "#333333"])
                    .map { Color(themeHex: $0) }
                let points = customTheme.background.gradientUnitPoints
                LinearGradient(
                    colors: colors,
                    startPoint: points.start,
                    endPoint: points.end
                )

            case .image:
                if let image = cachedBackgroundImage {
                    ZStack {
                        backgroundImageView(
                            image: image,
                            fit: customTheme.background.imageFit ?? .fill,
                            opacity: customTheme.background.imageOpacity ?? 1.0
                        )

                        if let overlayHex = customTheme.background.overlayColor {
                            Color(themeHex: overlayHex)
                                .opacity(customTheme.background.overlayOpacity ?? 0.5)
                        }
                    }
                } else {
                    Color(themeHex: customTheme.colors.primaryBackground)
                }
            }
        } else {
            theme.primaryBackground
        }
    }

    private func backgroundImageView(image: NSImage, fit: ThemeBackground.ImageFit, opacity: Double) -> some View {
        GeometryReader { geo in
            switch fit {
            case .fill:
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .opacity(opacity)
            case .fit:
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .opacity(opacity)
            case .stretch:
                Image(nsImage: image)
                    .resizable()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .opacity(opacity)
            case .tile:
                TiledImageView(image: image)
                    .opacity(opacity)
            }
        }
    }

    private struct TiledImageView: NSViewRepresentable {
        let image: NSImage

        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            view.wantsLayer = true
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            nsView.layer?.backgroundColor = NSColor(patternImage: image).cgColor
        }
    }
}
