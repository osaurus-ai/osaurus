//
//  LaTeXRenderer.swift
//  osaurus
//
//  Renders LaTeX math expressions using SwiftMath's native Core Graphics typesetter.
//  Provides both NSImage output (for inline math NSTextAttachments) and a SwiftUI
//  wrapper view (for block-level display math).
//

import AppKit
import SwiftMath
import SwiftUI

// MARK: - LaTeX Image Renderer

/// Renders LaTeX to NSImage using SwiftMath's offscreen `MTMathImage` API.
/// Thread-safe: uses NSCache and no NSView, so it can be called off the main actor.
final class LaTeXRenderer: @unchecked Sendable {
    static let shared = LaTeXRenderer()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 500
    }

    func renderToImage(
        latex: String,
        fontSize: CGFloat,
        textColor: NSColor
    ) -> NSImage? {
        let key = "\(latex)-\(fontSize)-\(textColor.hashValue)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let mathImage = MTMathImage(
            latex: latex,
            fontSize: fontSize,
            textColor: textColor,
            labelMode: .text,
            textAlignment: .left
        )
        let (error, image) = mathImage.asImage()
        guard error == nil, let image else { return nil }

        cache.setObject(image, forKey: key)
        return image
    }

    func clearCache() {
        cache.removeAllObjects()
    }
}

// MARK: - Block Math View (SwiftUI)

struct MathBlockView: View {
    let latex: String
    let baseWidth: CGFloat

    @Environment(\.theme) private var theme

    var body: some View {
        MathBlockRepresentable(
            latex: latex,
            fontSize: CGFloat(theme.bodySize) * Typography.scale(for: baseWidth) * 1.15,
            textColor: NSColor(theme.primaryText)
        )
        .frame(maxWidth: baseWidth - 32, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct MathBlockRepresentable: NSViewRepresentable {
    let latex: String
    let fontSize: CGFloat
    let textColor: NSColor

    func makeNSView(context: Context) -> MTMathUILabel {
        let label = MTMathUILabel()
        label.labelMode = .display
        label.textAlignment = .center
        configure(label)
        return label
    }

    func updateNSView(_ label: MTMathUILabel, context: Context) {
        configure(label)
    }

    private func configure(_ label: MTMathUILabel) {
        label.latex = latex
        label.font = MTFontManager().font(withName: MathFont.latinModernFont.rawValue, size: fontSize)
        label.textColor = textColor
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MTMathUILabel, context: Context) -> CGSize? {
        let size = nsView.fittingSize
        guard size.width > 0, size.height > 0 else { return nil }
        return size
    }
}
