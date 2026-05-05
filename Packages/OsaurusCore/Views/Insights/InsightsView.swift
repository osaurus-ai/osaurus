//
//  InsightsView.swift
//  osaurus
//
//  Request/response logging view for debugging and analytics.
//

import SwiftUI

struct InsightsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var insightsService = InsightsService.shared

    /// Use computed property to always get the current theme from ThemeManager
    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var hasAppeared = false
    @State private var selectedLogId: UUID?
    @State private var showClearConfirmation = false

    /// Resolved log for the current selection. Recomputed on every render so
    /// the pushed detail view stays in sync with the live ring buffer
    /// (selection is not invalidated when new entries arrive — IDs are
    /// stable). When the log disappears (cleared or filtered out) this
    /// returns nil and `body` pops back to the list.
    private var selectedLog: RequestLog? {
        guard let id = selectedLogId else { return nil }
        return insightsService.logs.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : -10)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

            ZStack {
                if let selected = selectedLog {
                    InsightsDetailPane(log: selected, onBack: pop)
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .trailing),
                                removal: .move(edge: .trailing)
                            )
                        )
                } else {
                    listContent
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .leading),
                                removal: .move(edge: .leading)
                            )
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .animation(.easeInOut(duration: 0.25), value: selectedLogId == nil)
            .opacity(hasAppeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
        .themedAlert(
            "Clear All Logs",
            isPresented: $showClearConfirmation,
            message: "Are you sure you want to clear all request logs? This action cannot be undone.",
            primaryButton: .destructive("Clear") { insightsService.clear() },
            secondaryButton: .cancel("Cancel")
        )
    }

    // MARK: - List content (filters + stats + table)

    private var listContent: some View {
        VStack(spacing: 0) {
            filterBar
                .padding(.horizontal, 24)
                .padding(.top, 16)

            statsBar
                .padding(.horizontal, 24)
                .padding(.top, 16)

            if insightsService.filteredLogs.isEmpty {
                emptyStateView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                logTableView
            }
        }
    }

    private func pop() {
        withAnimation(.easeInOut(duration: 0.25)) {
            selectedLogId = nil
        }
    }

    private func push(_ id: UUID) {
        withAnimation(.easeInOut(duration: 0.25)) {
            selectedLogId = id
        }
    }

    // MARK: - Header View

    private var headerView: some View {
        ManagerHeaderWithActions(
            title: L("Insights"),
            subtitle: L("Monitor API requests and performance")
        ) {
            HeaderSecondaryButton("Clear", icon: "trash") {
                showClearConfirmation = true
            }
            .opacity(insightsService.logs.isEmpty ? 0.5 : 1)
            .disabled(insightsService.logs.isEmpty)
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 12) {
            searchField
                .frame(maxWidth: 220)

            FilterPills(selection: $insightsService.methodFilter, tint: methodFilterTint)
            FilterPills(selection: $insightsService.sourceFilter, tint: { _ in .purple })

            Spacer()

            Text("\(insightsService.totalRequestCount) requests", bundle: .module)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundColor(theme.tertiaryText)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(theme.tertiaryText)

            TextField(
                text: $insightsService.searchFilter,
                prompt: Text("Search path or model...", bundle: .module)
            ) {
                Text("Search path or model...", bundle: .module)
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundColor(theme.primaryText)

            if !insightsService.searchFilter.isEmpty {
                Button(action: { insightsService.searchFilter = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.inputBorder.opacity(0.5), lineWidth: 1)
                )
        )
    }

    private func methodFilterTint(_ filter: MethodFilter) -> Color {
        switch filter {
        case .all: return .blue
        case .get: return .green
        case .post: return .blue
        }
    }

    // MARK: - Stats Bar

    private var statsBar: some View {
        let stats = insightsService.stats

        return HStack(spacing: 0) {
            StatPill(
                icon: "arrow.left.arrow.right",
                value: "\(stats.totalRequests)",
                label: "Requests",
                color: .blue
            )

            Divider()
                .frame(height: 24)
                .padding(.horizontal, 16)

            StatPill(
                icon: "checkmark.circle.fill",
                value: stats.formattedSuccessRate,
                label: "Success",
                color: .green
            )

            Divider()
                .frame(height: 24)
                .padding(.horizontal, 16)

            StatPill(
                icon: "clock",
                value: stats.formattedAvgDuration,
                label: "Avg Time",
                color: .orange
            )

            Divider()
                .frame(height: 24)
                .padding(.horizontal, 16)

            StatPill(
                icon: "exclamationmark.triangle.fill",
                value: "\(stats.errorCount)",
                label: "Errors",
                color: stats.errorCount > 0 ? .red : Color.gray.opacity(0.5)
            )

            // Show inference stats if there are any
            if stats.inferenceCount > 0 {
                Divider()
                    .frame(height: 24)
                    .padding(.horizontal, 16)

                StatPill(
                    icon: "bolt.fill",
                    value: "\(stats.inferenceCount)",
                    label: "Inferences",
                    color: .purple
                )

                Divider()
                    .frame(height: 24)
                    .padding(.horizontal, 16)

                StatPill(
                    icon: "gauge.with.needle",
                    value: stats.formattedAvgSpeed,
                    label: "Avg Speed",
                    color: .cyan
                )
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.secondaryBackground.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.primaryBorder.opacity(0.3), lineWidth: 1)
                )
        )
    }

    // MARK: - Log Table View

    private var logTableView: some View {
        VStack(spacing: 0) {
            // Table header
            HStack(spacing: 0) {
                Text("TIME", bundle: .module)
                    .frame(width: 70, alignment: .leading)
                Text("SOURCE", bundle: .module)
                    .frame(width: 64, alignment: .leading)
                Text("METHOD", bundle: .module)
                    .frame(width: 60, alignment: .leading)
                Text("PATH", bundle: .module)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("STATUS", bundle: .module)
                    .frame(width: 60, alignment: .center)
                Text("DURATION", bundle: .module)
                    .frame(width: 80, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(theme.tertiaryText.opacity(0.7))
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(theme.primaryBackground)

            Divider()
                .background(theme.primaryBorder.opacity(0.3))

            // Log rows
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(insightsService.filteredLogs) { log in
                        RequestLogRow(
                            log: log,
                            isSelected: selectedLogId == log.id,
                            onTap: { push(log.id) }
                        )

                        if log.id != insightsService.filteredLogs.last?.id {
                            Divider()
                                .background(theme.primaryBorder.opacity(0.2))
                                .padding(.horizontal, 24)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.left.arrow.right.circle")
                .font(.system(size: 48))
                .foregroundColor(theme.tertiaryText.opacity(0.3))

            Text("No Requests Yet", bundle: .module)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundColor(theme.secondaryText)

            Text(
                "API request activity will appear here.\nTest endpoints from Server tab or connect an app via the API.",
                bundle: .module
            )
            .font(.system(size: 13))
            .foregroundColor(theme.tertiaryText)
            .multilineTextAlignment(.center)
        }
        .padding(40)
    }
}

// MARK: - Filter Pills

/// Segmented-style pill bar for any string-backed `CaseIterable` filter
/// enum. Used by both the method (`All / GET / POST`) and source
/// (`All / Chat / HTTP / Plugin`) filters; the `tint` closure decides the
/// per-case selected color so each filter can keep its own visual identity.
private struct FilterPills<Filter>: View
where
    Filter: Hashable,
    Filter: CaseIterable,
    Filter: RawRepresentable,
    Filter.RawValue == String
{
    @Binding var selection: Filter
    let tint: (Filter) -> Color

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(Filter.allCases), id: \.self) { filter in
                let isSelected = selection == filter
                Button(action: { selection = filter }) {
                    Text(filter.rawValue)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundColor(isSelected ? .white : theme.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isSelected ? tint(filter).opacity(0.8) : Color.clear)
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.tertiaryBackground.opacity(0.5))
        )
        .fixedSize()
    }
}

// MARK: - Stat Pill

private struct StatPill: View {
    @Environment(\.theme) private var theme

    let icon: String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(color.opacity(0.8))

            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(theme.primaryText)

                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
            }
        }
    }
}

// MARK: - Request Log Row

private struct RequestLogRow: View {
    @Environment(\.theme) private var theme

    let log: RequestLog
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 0) {
                Text(log.formattedTimestamp)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
                    .frame(width: 70, alignment: .leading)

                SourceBadge(source: log.source)
                    .frame(width: 64, alignment: .leading)

                MethodBadge(method: log.method)
                    .frame(width: 60, alignment: .leading)

                HStack(spacing: 6) {
                    if let pluginId = log.pluginId {
                        InlineTag(tint: .teal) {
                            Text(pluginId).font(.system(size: 8, weight: .bold))
                        }
                    }
                    if let toolCount = log.toolDefinitionCount {
                        ToolsBadge(count: toolCount)
                    }
                    Text(log.path)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(log.isPluginLog ? logLevelColor(log.statusCode) : theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HTTPStatusBadge(statusCode: log.statusCode)
                    .frame(width: 60, alignment: .center)

                Text(log.formattedDuration)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 80, alignment: .trailing)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(isSelected ? theme.accentColor.opacity(0.12) : Color.clear)
            .overlay(alignment: .leading) {
                if isSelected {
                    Rectangle()
                        .fill(theme.accentColor)
                        .frame(width: 3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func logLevelColor(_ statusCode: Int) -> Color {
        switch statusCode {
        case 500: return .red
        case 299: return .orange
        default: return theme.primaryText
        }
    }
}

// MARK: - Inline Tag

/// Compact tinted pill used for in-row metadata (plugin id, tool count).
/// Wraps any `Content` view in the standard envelope (8pt fg opacity,
/// 12pt bg opacity, 5/2 padding, corner radius 3) so callers only worry
/// about the inner text/icon. Centralizes the look so changing pill
/// styling in one place updates every row badge.
private struct InlineTag<Content: View>: View {
    let tint: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .foregroundColor(tint.opacity(0.9))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3).fill(tint.opacity(0.12))
            )
    }
}

// MARK: - Tools Badge

private struct ToolsBadge: View {
    let count: Int

    var body: some View {
        InlineTag(tint: .teal) {
            HStack(spacing: 3) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 8, weight: .bold))
                Text("\(count)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
            }
        }
        .help(Text("\(count) tool(s) sent", bundle: .module))
    }
}

// MARK: - Method Badge

private struct MethodBadge: View {
    let method: String

    var body: some View {
        Text(method)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(methodColor.opacity(0.9))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(methodColor.opacity(0.15))
            )
    }

    private var methodColor: Color {
        switch method {
        case "GET": return .green
        case "POST": return .blue
        case "PUT": return .orange
        case "DELETE": return .red
        case "LOG": return .teal
        default: return .gray
        }
    }
}

// MARK: - HTTP Status Badge

private struct HTTPStatusBadge: View {
    let statusCode: Int

    var body: some View {
        Text("\(statusCode)", bundle: .module)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(statusColor)
            )
    }

    private var statusColor: Color {
        if statusCode >= 200 && statusCode < 300 {
            return .green
        } else if statusCode >= 400 && statusCode < 500 {
            return .orange
        } else if statusCode >= 500 {
            return .red
        }
        return .gray
    }
}

// MARK: - Source Badge

private struct SourceBadge: View {
    let source: RequestSource

    var body: some View {
        Text(source.shortName)
            .font(.system(size: 9, weight: .bold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundColor(badgeColor.opacity(0.9))
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(badgeColor.opacity(0.15))
            )
    }

    private var badgeColor: Color {
        switch source {
        case .chatUI: return .pink
        case .httpAPI: return .blue
        case .plugin: return .teal
        }
    }
}

extension RequestSource {
    var shortName: String {
        switch self {
        case .chatUI: return "Chat"
        case .httpAPI: return "HTTP"
        case .plugin: return "Plugin"
        }
    }
}

// MARK: - Preview

#Preview {
    InsightsView()
        .frame(width: 900, height: 600)
}
