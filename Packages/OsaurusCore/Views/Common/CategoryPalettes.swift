//
//  CategoryPalettes.swift
//  osaurus
//
//  Data palettes: brand, category, mascot, model-family and chart-series
//  colors. These identify a thing (a channel, a tool kind, a file type, a
//  model family) rather than a UI role, so they do not follow the theme's
//  semantic roles.
//

import AppKit
import SwiftUI

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
        case .triceBeret, .triceBackpack: return Color(red: 0.94, green: 0.49, blue: 0.33)
        case .rexPurse, .rexMecha: return Color(red: 0.56, green: 0.82, blue: 0.38)
        case .brontoScarf: return Color(red: 0.58, green: 0.78, blue: 0.94)
        }
    }
}

extension ContextBreakdown.Tint {
    func seriesColor(isDark: Bool) -> Color {
        switch self {
        case .purple: return isDark ? Color(red: 0.68, green: 0.52, blue: 1.0) : .purple
        case .blue: return isDark ? Color(red: 0.45, green: 0.68, blue: 1.0) : .blue
        case .orange: return isDark ? Color(red: 1.0, green: 0.68, blue: 0.35) : .orange
        case .green: return isDark ? Color(red: 0.45, green: 0.85, blue: 0.55) : .green
        case .gray: return isDark ? Color(red: 0.58, green: 0.62, blue: 0.68) : Color(white: 0.55)
        case .cyan: return isDark ? Color(red: 0.35, green: 0.82, blue: 0.9) : .cyan
        case .teal: return isDark ? Color(red: 0.3, green: 0.75, blue: 0.75) : .teal
        case .indigo: return isDark ? Color(red: 0.55, green: 0.48, blue: 0.95) : .indigo
        case .pink: return isDark ? Color(red: 1.0, green: 0.55, blue: 0.78) : .pink
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

extension CloudModelCategory {
    /// Opaque per-category label colors that stay readable over native
    /// selected list rows.
    func tagColor(isDark: Bool) -> Color {
        let hex: String
        switch (self, isDark) {
        case (.textToText, false): hex = "1E40AF"
        case (.textToText, true): hex = "BFDBFE"
        case (.imageToText, false): hex = "115E59"
        case (.imageToText, true): hex = "99F6E4"
        case (.image, false): hex = "6B21A8"
        case (.image, true): hex = "E9D5FF"
        case (.textToVideo, false): hex = "92400E"
        case (.textToVideo, true): hex = "FDE68A"
        case (.imageToVideo, false): hex = "9F1239"
        case (.imageToVideo, true): hex = "FECDD3"
        case (.all, false): hex = "374151"
        case (.all, true): hex = "E5E7EB"
        }
        return Color(hex: hex)
    }
}
