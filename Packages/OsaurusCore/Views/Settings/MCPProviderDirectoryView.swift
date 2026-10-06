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
                columns: [GridItem(.adaptive(minimum: 160), spacing: 12)],
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
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.tertiaryText)

            ZStack(alignment: .leading) {
                if query.isEmpty {
                    Text("Search services", bundle: .module)
                        .font(.system(size: 13))
                        .foregroundColor(theme.placeholderText)
                        .allowsHitTesting(false)
                }
                TextField("", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(theme.primaryText)
            }

            if !query.isEmpty {
                Button(action: { query = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.inputBorder, lineWidth: 1)
                )
        )
    }

    private var noMatchesHint: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .light))
                .foregroundColor(theme.tertiaryText)
            Group {
                if trimmedQuery.isEmpty {
                    Text("No services in this category", bundle: .module)
                } else {
                    Text("No services match \"\(trimmedQuery)\"", bundle: .module)
                }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(theme.secondaryText)
            Text("Try a different name, or pick Custom Server above.", bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

// MARK: - Directory Card

/// One cell in the directory grid: icon, title, two-line tagline, full-cell
/// tap target.
struct MCPProviderDirectoryCard: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let icon: String
    let title: String
    let tagline: String
    var requiresSubscription = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(themeManager.currentTheme.accentColor.opacity(0.12))
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(themeManager.currentTheme.accentColor)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey(title), bundle: .module)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(themeManager.currentTheme.primaryText)
                        .lineLimit(1)
                    Text(LocalizedStringKey(tagline), bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(themeManager.currentTheme.secondaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if requiresSubscription {
                        MCPProviderSubscriptionNote()
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        isHovering
                            ? themeManager.currentTheme.accentColor.opacity(0.06)
                            : themeManager.currentTheme.tertiaryBackground
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isHovering
                            ? themeManager.currentTheme.accentColor.opacity(0.4)
                            : themeManager.currentTheme.primaryBorder,
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
        }
    }
}

// MARK: - Directory Row

/// One row of the inline directory list: small icon tile, name, one-line
/// tagline, and an "Add" affordance. Flat — it is always a row inside a
/// `SettingsGroup`.
struct MCPProviderDirectoryRow: View {
    @Environment(\.theme) private var theme
    let icon: String
    let title: String
    let tagline: String
    var requiresSubscription = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(theme.accentColor.opacity(0.12))
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(title), bundle: .module)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(LocalizedStringKey(tagline), bundle: .module)
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(1)
                        if requiresSubscription {
                            MCPProviderSubscriptionNote()
                        }
                    }
                }

                Spacer(minLength: 8)

                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Add", bundle: .module)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(theme.accentColor)
                .opacity(isHovering ? 0.8 : 1)
            }
            .frame(maxWidth: .infinity, minHeight: SettingsGroupMetrics.rowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { isHovering = $0 }
    }
}

// MARK: - Category Chips

/// "All" plus one chip per category, shared by the Add Service sheet and the
/// inline directory on Tools & MCP → Services.
struct MCPProviderCategoryChips: View {
    @Environment(\.theme) private var theme
    @Binding var selection: MCPProviderCategory?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(title: "All", isSelected: selection == nil) { selection = nil }
                ForEach(MCPProviderCategory.allCases, id: \.self) { category in
                    chip(title: category.displayName, isSelected: selection == category) {
                        selection = selection == category ? nil : category
                    }
                }
            }
        }
    }

    private func chip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(LocalizedStringKey(title), bundle: .module)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .foregroundColor(isSelected ? .white : theme.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(isSelected ? theme.accentColor : theme.tertiaryBackground)
                )
                .overlay(
                    Capsule().stroke(isSelected ? Color.clear : theme.primaryBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Small caption for enterprise data products that need a paid account.
struct MCPProviderSubscriptionNote: View {
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "lock.fill")
                .font(.system(size: 8, weight: .semibold))
            Text("Requires subscription", bundle: .module)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(theme.tertiaryText)
        .lineLimit(1)
        .fixedSize()
    }
}
