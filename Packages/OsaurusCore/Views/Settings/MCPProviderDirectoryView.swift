//
//  MCPProviderDirectoryView.swift
//  osaurus
//
//  The browsable MCP service directory. Two renderings of the same catalog:
//  `MCPProviderDirectoryView` (search + tile grid) is the first step of the
//  Add Service sheet; `MCPProviderDirectoryRow` is the flat grouped-list row
//  Tools & MCP → Services shows inline so discovering providers is one click
//  away.
//

import SwiftUI

struct MCPProviderDirectoryView: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    @Binding var query: String
    let onSelectTemplate: (MCPProviderTemplate) -> Void
    let onSelectCustom: () -> Void

    @State private var category: MCPProviderCategory?
    @State private var metadataDocumentPublished = false

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            searchField

            MCPProviderCategoryChips(selection: $category)

            LazyVGrid(
                // Two columns in the 560pt Add Service sheet; at three, a
                // card's one-line title truncates to a few letters.
                columns: [GridItem(.adaptive(minimum: 210), spacing: 12)],
                spacing: 12
            ) {
                MCPProviderDirectoryCard(
                    icon: "slider.horizontal.3",
                    title: "Custom Server",
                    tagline: "Connect to any other MCP-compatible server",
                    action: onSelectCustom
                )
                ForEach(filteredTemplates) { template in
                    MCPProviderDirectoryCard(
                        icon: template.iconSystemName,
                        title: template.displayName,
                        tagline: template.tagline,
                        requiresSubscription: template.requiresSubscription,
                        action: { onSelectTemplate(template) }
                    )
                }
            }

            if filteredTemplates.isEmpty && (!trimmedQuery.isEmpty || category != nil) {
                noMatchesHint
            }
        }
        .task { metadataDocumentPublished = await MCPOAuthClientMetadata.isDocumentPublished() }
    }

    /// Templates that match the current query and category. Empty query
    /// returns the whole category (or catalog).
    private var filteredTemplates: [MCPProviderTemplate] {
        Self.templates(
            matching: trimmedQuery,
            category: category,
            metadataDocumentPublished: metadataDocumentPublished
        )
    }

    /// Shared matcher so the inline list on Tools & MCP → Services and the
    /// Add Service sheet filter the catalog identically. Match is
    /// case-insensitive across name, tagline, and category so users can find
    /// Linear by typing "issues" or every legal service by typing "legal".
    nonisolated static func templates(
        matching rawQuery: String,
        category: MCPProviderCategory? = nil,
        metadataDocumentPublished: Bool = false
    ) -> [MCPProviderTemplate] {
        let query = rawQuery.trimmingCharacters(in: .whitespaces)
        return MCPProviderTemplate.available(metadataDocumentPublished: metadataDocumentPublished).filter {
            if let category, $0.category != category { return false }
            guard !query.isEmpty else { return true }
            return $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.tagline.localizedCaseInsensitiveContains(query)
                || $0.category.displayName.localizedCaseInsensitiveContains(query)
                || LCached($0.category.displayName).localizedCaseInsensitiveContains(query)
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    private var searchField: some View {
        SearchField(text: $query, placeholder: "Search services", fillsAvailableWidth: true)
    }

    private var noMatchesHint: some View {
        SettingsEmptyState(
            inline: "magnifyingglass",
            title: trimmedQuery.isEmpty
                ? "No services in this category" : L("No services match \"\(trimmedQuery)\""),
            hint: "Try a different name, or pick Custom Server above."
        )
    }
}

// MARK: - Directory Card

/// One cell in the directory grid: icon, title, two-line tagline, full-cell
/// tap target.
struct MCPProviderDirectoryCard: View {
    @Environment(\.theme) private var inheritedTheme
    private var theme: any ThemeProtocol { inheritedTheme }
    /// Catalog keys.
    let icon: String
    let title: String
    let tagline: String
    var requiresSubscription = false
    let action: () -> Void

    var body: some View {
        LibraryCard(title: LCached(title), minHeight: 130, action: action) {
            LibraryIcon(symbol: icon, tint: theme.action.primary.default.background)
        } content: {
            LibraryCardPreview(text: LCached(tagline))
            if requiresSubscription {
                MCPProviderSubscriptionNote()
            }
        }.environment(\.theme, theme)
    }
}

// MARK: - Directory Row

/// One row of the inline directory list: small icon tile, name, one-line
/// tagline, and an "Add" affordance. Flat — it is always a row inside a
/// `SettingsGroup`.
struct MCPProviderDirectoryRow: View {
    @Environment(\.theme) private var inheritedTheme
    private var theme: any ThemeProtocol { inheritedTheme }
    /// Catalog keys.
    let icon: String
    let title: String
    let tagline: String
    var requiresSubscription = false
    let action: () -> Void

    var body: some View {
        LibraryRow(title: LCached(title), subtitle: LCached(tagline), action: action) {
            SettingsIconTile(icon: icon)
        } badges: {
            if requiresSubscription {
                MCPProviderSubscriptionNote()
            }
        } trailing: {
            Label {
                Text("Add", bundle: .module)
            } icon: {
                Image(systemName: "plus")
            }
            .labelStyle(.titleAndIcon)
            .catalogTypography(.label, theme: theme, fallback: SettingsFont.smallLabel)
            .foregroundColor(theme.text.link)
            .fixedSize()
        }
    }
}

// MARK: - Category Chips

struct MCPProviderCategoryChips: View {
    @Binding var selection: MCPProviderCategory?

    var body: some View {
        FilterChipRow(
            MCPProviderCategory.allCases,
            selection: $selection,
            title: { String(localized: String.LocalizationValue($0.displayName), bundle: .module) }
        )
    }
}

/// Small caption for enterprise data products that need a paid account.
struct MCPProviderSubscriptionNote: View {
    @Environment(\.theme) private var inheritedTheme
    private var theme: any ThemeProtocol { inheritedTheme }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "lock.fill")
                .glyphSize(8, weight: .semibold)
            Text("Requires subscription", bundle: .module)
                .catalogTypography(.caption, theme: theme, fallback: SettingsFont.chip)
        }
        .foregroundColor(theme.text.tertiary)
        .lineLimit(1)
        .fixedSize()
    }
}
