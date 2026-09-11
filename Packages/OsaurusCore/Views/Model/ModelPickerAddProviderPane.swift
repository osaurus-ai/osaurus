//
//  ModelPickerAddProviderPane.swift
//  osaurus
//
//  Right-pane content for the model picker's "+ Add provider" action: the
//  provider catalog (sign-in providers, API-key providers, local, custom,
//  and Claude Code) rendered as compact rows. Picking one hands the
//  preset + auth method back to the host, which opens the existing
//  `RemoteProviderEditSheet` to enter credentials and test the connection.
//

import SwiftUI

/// What the user picked in the inline catalog.
struct ModelPickerAddProviderChoice: Equatable, Identifiable {
    enum Target: Equatable {
        case preset(ProviderPreset, authMethod: ProviderPickerAuthMethod)
        case claudeCode
    }

    let target: Target

    var id: String {
        switch target {
        case .preset(let preset, let method):
            switch method {
            case .oauth(let kind): return "\(preset.id)-oauth-\(kind.rawValue)"
            case .apiKey: return "\(preset.id)-apiKey"
            case .none: return "\(preset.id)-none"
            }
        case .claudeCode:
            return "claude-code"
        }
    }

    var preset: ProviderPreset? {
        if case .preset(let preset, _) = target { return preset }
        return nil
    }

    var authMethod: ProviderPickerAuthMethod? {
        if case .preset(_, let method) = target { return method }
        return nil
    }

    var isClaudeCode: Bool { target == .claudeCode }
}

struct ModelPickerAddProviderPane: View {
    /// Presets already configured (by matching preset), so their rows can
    /// say so instead of inviting a duplicate.
    let configuredPresets: Set<ProviderPreset>
    let isClaudeCodeConfigured: Bool
    let onChoose: (ModelPickerAddProviderChoice) -> Void
    let onCancel: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(theme.primaryBorder.opacity(0.3))
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    section(title: L("Sign in"), entries: ProviderCatalog.topLevel, preferAPIKey: false)

                    ForEach(ProviderCatalog.apiKeyGroups(includeAzure: true)) { group in
                        section(title: group.title, entries: group.entries, preferAPIKey: true)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        sectionTitle(L("Agents"))
                        CompactProviderRow(
                            leading: .brandedSymbol("terminal.fill", gradient: ClaudeCodeConfiguration.brandGradient),
                            title: "Claude Code",
                            subtitle: L("Route chats through your local Claude Code CLI"),
                            badge: nil,
                            isConfigured: isClaudeCodeConfigured,
                            action: { onChoose(ModelPickerAddProviderChoice(target: .claudeCode)) }
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onCancel) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Back", bundle: .module)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(theme.secondaryText)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()

            Text("Add provider", bundle: .module)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)

            Spacer()

            Text("Pick a provider, then enter its credentials.", bundle: .module)
                .font(.system(size: 10.5))
                .foregroundColor(theme.tertiaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    @ViewBuilder
    private func section(title: String, entries: [ProviderCatalogEntry], preferAPIKey: Bool) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                sectionTitle(title)
                ForEach(entries) { entry in
                    let method: ProviderPickerAuthMethod =
                        preferAPIKey ? (entry.supportsAPIKey ? .apiKey : (entry.authMethods.first ?? .apiKey))
                        : (entry.authMethods.first ?? .apiKey)
                    CompactProviderRow(
                        leading: .preset(entry.preset),
                        title: entry.preset.name,
                        subtitle: entry.pickerSubtitle(preferAPIKey: preferAPIKey),
                        badge: entry.preset.badge,
                        isConfigured: entry.preset != .custom && configuredPresets.contains(entry.preset),
                        action: {
                            onChoose(
                                ModelPickerAddProviderChoice(target: .preset(entry.preset, authMethod: method))
                            )
                        }
                    )
                }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .kerning(0.8)
            .textCase(.uppercase)
            .foregroundColor(theme.tertiaryText)
            .padding(.horizontal, 4)
            .padding(.bottom, 2)
    }

    // MARK: - Row

    private struct CompactProviderRow: View {
        enum Leading {
            case preset(ProviderPreset)
            case brandedSymbol(String, gradient: [Color])
        }

        let leading: Leading
        let title: String
        let subtitle: String
        let badge: String?
        let isConfigured: Bool
        let action: () -> Void

        @Environment(\.theme) private var theme
        @State private var isHovered = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: isHovered ? gradient : [theme.tertiaryBackground, theme.tertiaryBackground],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 28, height: 28)
                        switch leading {
                        case .preset(let preset):
                            ProviderIcon(preset: preset, size: 12, color: isHovered ? .white : theme.secondaryText)
                        case .brandedSymbol(let symbol, _):
                            Image(systemName: symbol)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(isHovered ? .white : theme.secondaryText)
                        }
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(theme.primaryText)
                            if let badge, case .preset(let preset) = leading {
                                ProviderBadge(badge, gradient: preset.gradient)
                            }
                            if isConfigured {
                                Text("Added", bundle: .module)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(theme.tertiaryText)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background(Capsule().fill(theme.secondaryBackground))
                            }
                        }
                        Text(subtitle)
                            .font(.system(size: 10.5))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 6)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isHovered ? theme.tertiaryBackground.opacity(0.7) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
            }
            .accessibilityLabel(Text(title))
            .accessibilityHint(Text(subtitle))
        }

        private var gradient: [Color] {
            switch leading {
            case .preset(let preset): return preset.gradient
            case .brandedSymbol(_, let gradient): return gradient
            }
        }
    }
}
