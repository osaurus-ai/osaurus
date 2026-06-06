//
//  ProviderRowCard.swift
//  osaurus
//
//  Shared selection row for the remote-provider picker. Used by both the
//  providers empty state and the add-provider sheet picker — identical
//  treatment on both surfaces — driven by `ProviderCatalog` entries so there's
//  a single card implementation instead of one per surface.
//

import SwiftUI

struct ProviderRowCard: View {
    /// The leading icon tile content.
    enum Leading {
        /// A catalog provider — renders its `ProviderIcon` and brand gradient.
        case preset(ProviderPreset)
        /// An explicit SF Symbol (e.g. the "Use an API key" drill-in), tinted
        /// with the accent gradient on hover.
        case symbol(String)
    }

    private let leading: Leading
    private let titleText: Text
    private let subtitle: String
    private let badge: String?
    private let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    private init(
        leading: Leading,
        titleText: Text,
        subtitle: String,
        badge: String?,
        action: @escaping () -> Void
    ) {
        self.leading = leading
        self.titleText = titleText
        self.subtitle = subtitle
        self.badge = badge
        self.action = action
    }

    /// Catalog provider row. `preferAPIKey` selects the API-key subtitle for
    /// rows shown inside the "Use an API key" sub-list.
    init(
        entry: ProviderCatalogEntry,
        preferAPIKey: Bool = false,
        action: @escaping () -> Void
    ) {
        self.init(
            leading: .preset(entry.preset),
            titleText: Text(entry.preset.name),
            subtitle: entry.pickerSubtitle(preferAPIKey: preferAPIKey),
            badge: entry.preset.badge,
            action: action
        )
    }

    /// Explicit action row not tied to a single provider (e.g. "Use an API
    /// key"). `title`/`subtitle` are localization keys.
    init(
        icon: String,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) {
        self.init(
            leading: .symbol(icon),
            titleText: Text(LocalizedStringKey(title), bundle: .module),
            subtitle: subtitle,
            badge: nil,
            action: action
        )
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                iconTile

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        titleText
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(theme.primaryText)

                        if let badge, case .preset(let preset) = leading {
                            ProviderBadge(badge, gradient: preset.gradient)
                        }
                    }
                    Text(LocalizedStringKey(subtitle), bundle: .module)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                isHovered ? theme.accentColor.opacity(0.4) : theme.cardBorder,
                                lineWidth: 1
                            )
                    )
            )
            .scaleEffect(isHovered ? 1.01 : 1.0)
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                isHovered = hovering
            }
        }
    }

    @ViewBuilder
    private var iconTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(
                    LinearGradient(
                        colors: isHovered
                            ? hoverGradient : [theme.tertiaryBackground, theme.tertiaryBackground],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 42, height: 42)

            switch leading {
            case .preset(let preset):
                ProviderIcon(preset: preset, size: 16, color: isHovered ? .white : theme.secondaryText)
            case .symbol(let symbol):
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(isHovered ? .white : theme.secondaryText)
            }
        }
    }

    private var hoverGradient: [Color] {
        switch leading {
        case .preset(let preset): return preset.gradient
        case .symbol: return [theme.accentColor, theme.accentColor.opacity(0.7)]
        }
    }
}
