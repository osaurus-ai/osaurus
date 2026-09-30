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

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            searchField

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
                        action: { onSelectTemplate(template) }
                    )
                }
            }

            if filteredTemplates.isEmpty && !trimmedQuery.isEmpty {
                noMatchesHint
            }
        }
    }

    /// Templates that match the current query. Empty query returns the full
    /// catalog. Match is case-insensitive across `displayName` and `tagline`
    /// so users can find Linear by typing "issues".
    private var filteredTemplates: [MCPProviderTemplate] {
        Self.templates(matching: trimmedQuery)
    }

    /// Shared matcher so the inline list on Tools & MCP → Services and the
    /// Add Service sheet filter the catalog identically.
    static func templates(matching rawQuery: String) -> [MCPProviderTemplate] {
        let query = rawQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return MCPProviderTemplate.allTemplates }
        return MCPProviderTemplate.allTemplates.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.tagline.localizedCaseInsensitiveContains(query)
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
            Text("No services match \"\(trimmedQuery)\"", bundle: .module)
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
                    Text(LocalizedStringKey(tagline), bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
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
