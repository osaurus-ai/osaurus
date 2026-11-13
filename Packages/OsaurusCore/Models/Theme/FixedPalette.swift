//
//  FixedPalette.swift
//  osaurus
//
//  The few colors that deliberately ignore the theme. Views name these
//  instead of writing literals, so every exception to the semantic roles is
//  listed in one place.
//

import AppKit
import SwiftUI

enum FixedPalette {
    /// Glyphs and text drawn on images, video, brand gradients and saturated
    /// category fills, where theme text would lose contrast.
    static let onMedia = Color.white
    static let onMediaNS = NSColor.white

    /// The dim under `onMedia` glyphs on images and video. Media pixels are
    /// theme-independent, so the dim is too.
    static func mediaScrim(_ opacity: Double) -> Color { Color.black.opacity(opacity) }
    static func mediaScrimNS(_ opacity: Double) -> NSColor { NSColor.black.withAlphaComponent(opacity) }

    /// The letterbox behind full-screen images and video.
    static let mediaBackdrop = Color.black

    /// QR codes need a white quiet zone and black modules to scan.
    static let qrPaper = Color.white
    static let qrInk = Color.black

    /// A glyph on a caller-chosen fill (a pale status shade, a saturated
    /// tint): white or black, whichever contrasts more with the fill.
    static func glyph(on fill: Color) -> Color {
        let lum = ThemeContrast.luminance(fill)
        return ThemeContrast.ratio(lum, 1) >= ThemeContrast.ratio(lum, 0) ? .white : .black
    }
}
