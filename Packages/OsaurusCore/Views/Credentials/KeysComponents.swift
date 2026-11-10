//
//  KeysComponents.swift
//  osaurus
//
//  Pieces shared by the Keys page, the key editor and an agent's Sandbox
//  keys: the tile that says what a key belongs to, and the pill that shows
//  its value (masked until revealed).
//

import SwiftUI

extension CredentialOrigin {
    var symbol: String {
        switch self {
        case .user: return "key.fill"
        case .mcp: return "server.rack"
        case .plugin: return "puzzlepiece.extension.fill"
        case .channel: return "bubble.left.and.bubble.right.fill"
        case .workflow: return "flowchart.fill"
        case .sandboxPrompt: return "terminal.fill"
        case .config: return "doc.text.fill"
        }
    }

    /// Category hue (like tool categories), so keys from the same kind of
    /// owner read as a family.
    var tint: Color {
        let hue: Double
        switch self {
        case .user: hue = 0.58
        case .mcp: hue = 0.74
        case .plugin: hue = 0.36
        case .channel: hue = 0.07
        case .workflow: hue = 0.48
        case .sandboxPrompt: hue = 0.90
        case .config: hue = 0.13
        }
        return Color(hue: hue, saturation: 0.55, brightness: 0.85)
    }
}

extension AppKeyRow.Group {
    var symbol: String {
        switch self {
        case .models: return "cpu"
        case .webSearch: return "magnifyingglass"
        case .voice: return "waveform"
        case .downloads: return "arrow.down.circle.fill"
        }
    }

    var tint: Color {
        let hue: Double
        switch self {
        case .models: hue = 0.62
        case .webSearch: hue = 0.52
        case .voice: hue = 0.84
        case .downloads: hue = 0.36
        }
        return Color(hue: hue, saturation: 0.55, brightness: 0.85)
    }
}

/// A key's value in a quiet well: dots while hidden, the text once shown.
struct KeyValuePill: View {
    @Environment(\.theme) private var theme

    /// Verbatim; nil shows the mask.
    let value: String?
    let isHidden: Bool

    var body: some View {
        HStack(spacing: theme.space.s6) {
            Image(systemName: isHidden ? (value == nil ? "lock.fill" : "lock.open.fill") : "textformat")
                .glyphSize(9, weight: .semibold)
                .foregroundColor(theme.text.tertiary)
                .accessibilityHidden(true)
            Text(verbatim: value ?? "••••••••")
                .font(SettingsFont.monoSmall)
                .foregroundColor(value == nil ? theme.text.tertiary : theme.text.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(.horizontal, theme.space.s8)
        .padding(.vertical, theme.space.s4)
        .frame(maxWidth: 180, alignment: .leading)
        .settingsChrome(.inset)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(value ?? L("Hidden value"))
    }
}
