//
//  BrandPalette.swift
//  osaurus
//
//  Fixed identity colors: provider, channel and Claude Code brands, the dino
//  mascots, and the tool-kind and file-type tiles. They identify a thing the
//  way its logo does, so they hold in every theme and appearance. Theme
//  roles and the categorical `color.data` series cover everything else.
//

import AppKit
import SwiftUI

enum BrandPalette {
    /// Osaurus dino green `#68d735` (selection border, verified check).
    static let dinoGreen = Color(red: 0x68 / 255, green: 0xD7 / 255, blue: 0x35 / 255)
    /// Deep dino green `#24650f` for copy on light glass, where `dinoGreen`
    /// is 1.2–1.7:1.
    static let dinoGreenDeep = Color(red: 0x24 / 255, green: 0x65 / 255, blue: 0x0F / 255)
    /// The local-model card's gradient tint, fading to clear.
    static let dinoGreenGlow = Color(red: 133 / 255, green: 212 / 255, blue: 82 / 255).opacity(0.26)

    /// The dino's comic speech bubble: white paper, black ink and outline.
    static let bubblePaper = Color.white
    static let bubbleInk = Color.black
    /// Onboarding glass: the specular rim and the light that follows the
    /// pointer across the landscape.
    static let glassLight = Color.white

    /// Claude's brand gradient, from Anthropic's accent orange (#D97757) to a
    /// darker shade of the same hue. Not the app accent: an accent-tinted
    /// Claude Code row read the same as "Use an API key". The nearest
    /// provider gradient is OpenRouter at ΔE 22.7.
    /// The shareable workflow card: printed in one look whatever the
    /// viewer's theme, since it leaves the app as an image.
    enum ShareCard {
        static let ink = Color(red: 0x11 / 255, green: 0x10 / 255, blue: 0x0F / 255)
        static let paper = Color(red: 0xFD / 255, green: 0xFC / 255, blue: 0xFA / 255)
        static let muted = Color(red: 0xE0 / 255, green: 0xE0 / 255, blue: 0xD6 / 255)
        static let lime = Color(red: 0xC0 / 255, green: 0xEC / 255, blue: 0x51 / 255)
    }

    static let claudeCode: [Color] = [
        Color(red: 0.851, green: 0.467, blue: 0.341),
        Color(red: 0.749, green: 0.373, blue: 0.259),
    ]
}

extension ProviderPreset {
    /// Two-stop brand gradient for the provider's icon tile.
    var gradient: [Color] {
        switch self {
        case .anthropic: return [Color(red: 0.85, green: 0.55, blue: 0.35), Color(red: 0.75, green: 0.4, blue: 0.25)]
        case .azureOpenAI: return [Color(red: 0.0, green: 0.47, blue: 0.84), Color(red: 0.0, green: 0.62, blue: 0.72)]
        case .atlasCloud: return [Color(red: 0.03, green: 0.23, blue: 0.21), Color(red: 0.07, green: 0.39, blue: 0.34)]
        case .openai: return [Color(red: 0.0, green: 0.65, blue: 0.52), Color(red: 0.0, green: 0.5, blue: 0.4)]
        case .google: return [Color(red: 0.26, green: 0.52, blue: 0.96), Color(red: 0.18, green: 0.38, blue: 0.85)]
        case .xai: return [Color(red: 0.1, green: 0.1, blue: 0.1), Color(red: 0.2, green: 0.2, blue: 0.2)]
        case .deepseek: return [Color(red: 0.18, green: 0.36, blue: 0.95), Color(red: 0.34, green: 0.52, blue: 0.98)]
        case .fireworks: return [Color(red: 0.42, green: 0.16, blue: 0.94), Color(red: 0.56, green: 0.31, blue: 0.98)]
        case .mistral: return [Color(red: 0.98, green: 0.42, blue: 0.11), Color(red: 0.87, green: 0.24, blue: 0.09)]
        case .minimax: return [Color(red: 0.93, green: 0.27, blue: 0.23), Color(red: 0.83, green: 0.15, blue: 0.18)]
        case .venice: return [Color(red: 0.83, green: 0.66, blue: 0.33), Color(red: 0.72, green: 0.53, blue: 0.17)]
        case .openrouter: return [Color(red: 0.95, green: 0.55, blue: 0.25), Color(red: 0.85, green: 0.4, blue: 0.2)]
        case .ollama: return [Color(red: 0.36, green: 0.36, blue: 0.4), Color(red: 0.22, green: 0.22, blue: 0.26)]
        case .custom: return [Color(red: 0.55, green: 0.55, blue: 0.6), Color(red: 0.4, green: 0.4, blue: 0.45)]
        }
    }
}

extension AgentChannelKind {
    /// Two-stop brand gradient for the card and sheet icon tiles, mirroring
    /// the provider-preset gradients used across the Providers tab.
    var brandGradient: [Color] {
        switch self {
        case .discord: [Color(hex: "5865F2"), Color(hex: "4051D3")]
        case .slack: [Color(hex: "611F69"), Color(hex: "4A154B")]
        case .telegram: [Color(hex: "2AABEE"), Color(hex: "1E96C8")]
        case .imessage: [Color(hex: "34C759"), Color(hex: "248A3D")]
        case .whatsapp: [Color(hex: "25D366"), Color(hex: "128C7E")]
        case .email: [Color(hex: "1E88E5"), Color(hex: "1565C0")]
        case .n8n: [Color(hex: "EA4B71"), Color(hex: "C2385A")]
        case .customHTTP: [Color(hex: "64748B"), Color(hex: "475569")]
        }
    }
}

extension ToolCategory {
    var gradient: [Color] {
        switch self {
        case .file: return [Color(hex: "f59e0b"), Color(hex: "d97706")]
        case .search: return [Color(hex: "8b5cf6"), Color(hex: "7c3aed")]
        case .terminal: return [Color(hex: "10b981"), Color(hex: "059669")]
        case .network: return [Color(hex: "3b82f6"), Color(hex: "2563eb")]
        case .database: return [Color(hex: "ec4899"), Color(hex: "db2777")]
        case .code: return [Color(hex: "06b6d4"), Color(hex: "0891b2")]
        case .general: return [Color(hex: "6b7280"), Color(hex: "4b5563")]
        }
    }
}

extension ToolCategory {
    /// First color of the SwiftUI gradient, translated to NSColor.
    var primaryNSColor: NSColor {
        switch self {
        case .file: return NSColor(red: 0.96, green: 0.62, blue: 0.27, alpha: 1)
        case .search: return NSColor(red: 0.55, green: 0.36, blue: 0.96, alpha: 1)
        case .terminal: return NSColor(red: 0.06, green: 0.73, blue: 0.51, alpha: 1)
        case .network: return NSColor(red: 0.23, green: 0.51, blue: 0.96, alpha: 1)
        case .database: return NSColor(red: 0.93, green: 0.29, blue: 0.60, alpha: 1)
        case .code: return NSColor(red: 0.02, green: 0.71, blue: 0.83, alpha: 1)
        case .general: return NSColor(red: 0.42, green: 0.45, blue: 0.50, alpha: 1)
        }
    }
}

extension AgentMascot {
    /// The dino's signature color, used to theme surfaces around the mascot
    /// (e.g. the onboarding hero glow, avatar tint, and selection ring) so
    /// the UI reacts in the selected dino's actual color rather than a
    /// name-hash approximation.
    public var color: Color {
        switch self {
        case .blue: return Color(red: 0.30, green: 0.56, blue: 0.92)
        case .green: return Color(red: 0.36, green: 0.72, blue: 0.42)
        case .orange: return Color(red: 0.95, green: 0.58, blue: 0.24)
        case .purple: return Color(red: 0.62, green: 0.42, blue: 0.92)
        case .red: return Color(red: 0.91, green: 0.38, blue: 0.36)
        case .yellow: return Color(red: 0.95, green: 0.78, blue: 0.27)
        }
    }
}

extension SharedArtifact {
    var typeGradientNSColors: [NSColor] {
        func c(_ hex: String) -> NSColor {
            let h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            var int: UInt64 = 0
            Scanner(string: h).scanHexInt64(&int)
            let r = CGFloat((int >> 16) & 0xFF) / 255
            let g = CGFloat((int >> 8) & 0xFF) / 255
            let b = CGFloat(int & 0xFF) / 255
            return NSColor(calibratedRed: r, green: g, blue: b, alpha: 1)
        }
        if isImage { return [c("8b5cf6"), c("7c3aed")] }
        if isPDF { return [c("ef4444"), c("dc2626")] }
        switch officeDocumentKind {
        case .wordProcessing: return [c("2b579a"), c("1e3f73")]
        case .spreadsheet: return [c("217346"), c("185a37")]
        case .presentation: return [c("d24726"), c("b03a1c")]
        case nil: break
        }
        if isVideo { return [c("ec4899"), c("db2777")] }
        if isAudio { return [c("f59e0b"), c("d97706")] }
        if isHTML { return [c("3b82f6"), c("2563eb")] }
        if isDirectory { return [c("f59e0b"), c("d97706")] }
        return [c("6b7280"), c("4b5563")]
    }
}
