//
//  ResponsiveTypography.swift
//  osaurus
//
//  Scales font sizes based on container width for comfortable reading
//  Now integrates with theme typography settings including custom font families
//

import SwiftUI

enum Typography {
    static func scale(for width: CGFloat) -> CGFloat {
        // Map 640→1.0, 1024→1.15, 1400→1.25
        let clamped = max(640.0, min(1400.0, width))
        let s = (clamped - 640.0) / (1400.0 - 640.0)
        return 1.0 + s * 0.25
    }

    // MARK: - Default sizes (fallback when theme not available)

    static func title(_ width: CGFloat) -> Font {
        .system(size: 18 * scale(for: width), weight: .semibold, design: .rounded)
    }

    static func body(_ width: CGFloat) -> Font {
        .system(size: 15 * scale(for: width))
    }

    static func small(_ width: CGFloat) -> Font {
        .system(size: 13 * scale(for: width))
    }

    static func code(_ width: CGFloat) -> Font {
        .system(size: 14 * scale(for: width), weight: .regular, design: .monospaced)
    }

    // MARK: - Theme-aware typography with custom font support

    static func title(_ width: CGFloat, theme: ThemeProtocol) -> Font {
        let size = CGFloat(theme.titleSize) * scale(for: width)
        return customFont(theme.primaryFontName, size: size, weight: .semibold)
    }

    static func heading(_ width: CGFloat, theme: ThemeProtocol) -> Font {
        let size = CGFloat(theme.headingSize) * scale(for: width)
        return customFont(theme.primaryFontName, size: size, weight: .semibold)
    }

    static func body(_ width: CGFloat, theme: ThemeProtocol) -> Font {
        let size = CGFloat(theme.bodySize) * scale(for: width)
        return customFont(theme.primaryFontName, size: size, weight: .regular)
    }

    static func caption(_ width: CGFloat, theme: ThemeProtocol) -> Font {
        let size = CGFloat(theme.captionSize) * scale(for: width)
        return customFont(theme.primaryFontName, size: size, weight: .regular)
    }

    static func code(_ width: CGFloat, theme: ThemeProtocol) -> Font {
        let size = CGFloat(theme.codeSize) * scale(for: width)
        return monoFont(theme.monoFontName, size: size, weight: .regular)
    }

    // MARK: - Custom Font Helpers

    /// Creates a font from a font name, falling back to system font for SF fonts
    private static func customFont(_ fontName: String, size: CGFloat, weight: Font.Weight) -> Font {
        // System fonts - use native SwiftUI fonts for best rendering
        if fontName.lowercased().contains("sf pro") || fontName.isEmpty {
            return .system(size: size, weight: weight)
        }

        // Use Font.custom with the family name - SwiftUI handles weight variants
        return .custom(fontName, size: size).weight(weight)
    }

    /// Creates a monospace font from a font name
    private static func monoFont(_ fontName: String, size: CGFloat, weight: Font.Weight) -> Font {
        // System mono fonts
        if fontName.lowercased().contains("sf mono") || fontName.isEmpty {
            return .system(size: size, weight: weight, design: .monospaced)
        }

        // Use Font.custom with the family name - SwiftUI handles weight variants
        return .custom(fontName, size: size).weight(weight)
    }
}

// MARK: - View extension for easy access to themed typography

extension View {
    /// Returns a font scaled for the given width using theme typography
    func themedFont(_ style: ThemedFontStyle, width: CGFloat = 800) -> some View {
        self.modifier(ThemedFontModifier(style: style, width: width))
    }
}

enum ThemedFontStyle {
    case title
    case heading
    case body
    case caption
    case code
}

struct ThemedFontModifier: ViewModifier {
    let style: ThemedFontStyle
    let width: CGFloat
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content.font(resolvedFont)
    }

    private var resolvedFont: Font {
        switch style {
        case .title:
            return Typography.title(width, theme: theme)
        case .heading:
            return Typography.heading(width, theme: theme)
        case .body:
            return Typography.body(width, theme: theme)
        case .caption:
            return Typography.caption(width, theme: theme)
        case .code:
            return Typography.code(width, theme: theme)
        }
    }
}

// MARK: - Font Extension for Theme Integration

extension Font {
    /// Creates a font using theme settings
    static func themed(
        _ fontName: String,
        size: CGFloat,
        weight: Font.Weight = .regular,
        isMono: Bool = false
    ) -> Font {
        // System fonts
        if fontName.lowercased().contains("sf pro") || fontName.lowercased().contains("sf mono") || fontName.isEmpty {
            return .system(size: size, weight: weight, design: isMono ? .monospaced : .default)
        }

        // Custom fonts
        return .custom(fontName, size: size)
    }
}
