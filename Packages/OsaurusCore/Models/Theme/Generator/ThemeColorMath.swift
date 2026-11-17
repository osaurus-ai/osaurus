//
//  ThemeColorMath.swift
//  osaurus
//
//  Pure sRGB / OKLCH / WCAG math for the theme generator. No AppKit, so it
//  runs off the main actor.
//

import Foundation

struct ThemeRGB: Equatable, Sendable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double = 1
}

struct ThemeOKLCH: Equatable, Sendable {
    /// Perceptual lightness, 0–1.
    var l: Double
    var c: Double
    /// Hue in degrees, 0–360.
    var h: Double
}

enum ThemeColorMath {
    // MARK: Hex

    /// Parses `#RGB`, `#RRGGBB` or `#RRGGBBAA`.
    static func rgb(hex: String) -> ThemeRGB? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("#") else { return nil }
        s.removeFirst()
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else { return nil }
        let hasAlpha = s.count == 8
        let shift: UInt64 = hasAlpha ? 8 : 0
        let r = Double((value >> (16 + shift)) & 0xFF) / 255
        let g = Double((value >> (8 + shift)) & 0xFF) / 255
        let b = Double((value >> shift) & 0xFF) / 255
        let a = hasAlpha ? Double(value & 0xFF) / 255 : 1
        return ThemeRGB(r: r, g: g, b: b, a: a)
    }

    /// `#RRGGBBAA`, matching the library's primitive format.
    static func hex(_ rgb: ThemeRGB) -> String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X%02X", byte(rgb.r), byte(rgb.g), byte(rgb.b), byte(rgb.a))
    }

    // MARK: WCAG

    static func luminance(_ c: ThemeRGB) -> Double {
        func linear(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    /// Composites a translucent color over an opaque backdrop.
    static func over(_ top: ThemeRGB, _ bottom: ThemeRGB) -> ThemeRGB {
        let a = top.a
        return ThemeRGB(r: top.r * a + bottom.r * (1 - a), g: top.g * a + bottom.g * (1 - a), b: top.b * a + bottom.b * (1 - a))
    }

    /// WCAG ratio, compositing either color over `backdrop` when translucent.
    static func contrast(_ a: ThemeRGB, _ b: ThemeRGB, backdrop: ThemeRGB? = nil) -> Double {
        let base = backdrop ?? ThemeRGB(r: 1, g: 1, b: 1)
        let solidB = b.a < 1 ? over(b, base) : b
        let solidA = a.a < 1 ? over(a, solidB) : a
        let la = luminance(solidA), lb = luminance(solidB)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func contrast(_ a: String, _ b: String) -> Double? {
        guard let x = rgb(hex: a), let y = rgb(hex: b) else { return nil }
        return contrast(x, y)
    }

    // MARK: OKLCH

    static func oklch(_ c: ThemeRGB) -> ThemeOKLCH {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let r = linear(c.r), g = linear(c.g), b = linear(c.b)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let A = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        var h = atan2(B, A) * 180 / .pi
        if h < 0 { h += 360 }
        return ThemeOKLCH(l: L, c: (A * A + B * B).squareRoot(), h: h)
    }

    /// Unclipped linear-light conversion; components may fall outside 0–1.
    private static func linearRGB(_ c: ThemeOKLCH) -> (Double, Double, Double) {
        let hr = c.h * .pi / 180
        let A = c.c * cos(hr), B = c.c * sin(hr)
        let l = pow(c.l + 0.3963377774 * A + 0.2158037573 * B, 3)
        let m = pow(c.l - 0.1055613458 * A - 0.0638541728 * B, 3)
        let s = pow(c.l - 0.0894841775 * A - 1.2914855480 * B, 3)
        return (
            4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        )
    }

    static func isInGamut(_ c: ThemeOKLCH) -> Bool {
        let (r, g, b) = linearRGB(c)
        let e = 0.0001
        return [r, g, b].allSatisfy { $0 >= -e && $0 <= 1 + e }
    }

    /// Converts to sRGB, reducing chroma (never hue or lightness) until the
    /// color fits the gamut.
    static func rgb(_ input: ThemeOKLCH) -> ThemeRGB {
        var c = ThemeOKLCH(l: min(max(input.l, 0), 1), c: max(input.c, 0), h: input.h)
        if !isInGamut(c) {
            var lo = 0.0, hi = c.c
            for _ in 0 ..< 24 {
                let mid = (lo + hi) / 2
                if isInGamut(ThemeOKLCH(l: c.l, c: mid, h: c.h)) { lo = mid } else { hi = mid }
            }
            c.c = lo
        }
        let (r, g, b) = linearRGB(c)
        func gamma(_ v: Double) -> Double {
            let v = min(max(v, 0), 1)
            return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
        }
        return ThemeRGB(r: gamma(r), g: gamma(g), b: gamma(b))
    }

    /// Perceptual distance (ΔE OK ×100, comparable to CIE ΔE scale).
    static func deltaE(_ a: ThemeRGB, _ b: ThemeRGB) -> Double {
        let x = oklch(a), y = oklch(b)
        let ax = x.c * cos(x.h * .pi / 180), bx = x.c * sin(x.h * .pi / 180)
        let ay = y.c * cos(y.h * .pi / 180), by = y.c * sin(y.h * .pi / 180)
        let d = ((x.l - y.l) * (x.l - y.l) + (ax - ay) * (ax - ay) + (bx - by) * (bx - by)).squareRoot()
        return d * 100
    }
}
