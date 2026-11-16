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
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }

    /// The leading icon tile content.
    enum Leading {
        /// A catalog provider — renders its `ProviderIcon` and brand gradient.
        case preset(ProviderPreset)
        /// An explicit SF Symbol (e.g. the "Use an API key" drill-in) on the
        /// accent tile.
        case symbol(String)
        /// An SF Symbol carrying its own brand gradient. For rows that are a
        /// real vendor but have no `ProviderPreset` — Claude Code, which drives
        /// a local binary rather than an HTTP endpoint. Without this such a row
        /// would share the accent tile with the generic `.symbol` rows.
        case brandedSymbol(String, gradient: [Color])
    }

    private let leading: Leading
    /// Already localized.
    private let title: String
    /// Catalog key.
    private let subtitle: String
    private let badge: String?
    private let action: () -> Void

    private init(
        leading: Leading,
        title: String,
        subtitle: String,
        badge: String?,
        action: @escaping () -> Void
    ) {
        self.leading = leading
        self.title = title
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
            title: entry.preset.name,
            subtitle: entry.pickerSubtitle(preferAPIKey: preferAPIKey),
            badge: entry.preset.badge,
            action: action
        )
    }

    /// Explicit action row not tied to a single provider (e.g. "Use an API
    /// key"). `title`/`subtitle` are localization keys.
    ///
    /// Pass `gradient` for a row that represents a real vendor without a
    /// `ProviderPreset`, so it shows its own brand color instead of the
    /// shared accent.
    init(
        icon: String,
        title: String,
        subtitle: String,
        gradient: [Color]? = nil,
        action: @escaping () -> Void
    ) {
        self.init(
            leading: gradient.map { .brandedSymbol(icon, gradient: $0) } ?? .symbol(icon),
            title: LCached(title),
            subtitle: subtitle,
            badge: nil,
            action: action
        )
    }

    var body: some View {
        LibraryRow(title: title, subtitle: LCached(subtitle), showsChevron: true, action: action) {
            leadingTile
        } badges: {
            if let badge, case .preset(let preset) = leading {
                ProviderBadge(badge, gradient: preset.gradient)
            }
        }
    }

    @ViewBuilder
    private var leadingTile: some View {
        switch leading {
        case .preset(let preset):
            ProviderIconTile(preset: preset)
        case .symbol(let symbol):
            SettingsIconTile(icon: symbol, size: 32)
        case .brandedSymbol(let symbol, let gradient):
            SettingsIconTile(icon: symbol, size: 32, gradient: gradient)
        }
    }
}

/// A provider's brand tile: its `ProviderIcon` on the preset gradient, or a
/// muted cloud when there is no matching preset or the provider is inactive.
struct ProviderIconTile: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }

    let preset: ProviderPreset?
    var size: CGFloat = 32
    var isActive: Bool = true
    /// Glyph and wash color when inactive.
    var inactiveTint: Color?

    var body: some View {
        let lit = isActive && preset != nil
        let tint = inactiveTint ?? theme.text.secondary
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(
                    lit
                        ? AnyShapeStyle(
                            LinearGradient(
                                colors: preset?.gradient ?? [],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing))
                        : AnyShapeStyle(theme.wash(behind: tint))
                )
            if let preset {
                ProviderIcon(preset: preset, size: size * 0.45, color: lit ? FixedPalette.onMedia : tint)
            } else {
                Image(systemName: "cloud.fill")
                    .glyphSize(points: size * 0.45)
                    .foregroundColor(tint)
            }
        }
        .frame(width: size, height: size)
    }
}
