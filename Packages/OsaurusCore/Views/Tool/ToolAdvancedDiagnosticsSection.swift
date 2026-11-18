//
//  ToolAdvancedDiagnosticsSection.swift
//  osaurus
//
//  Collapsed-by-default diagnostics card for the Tools catalog. Keeps the
//  technically exact exposure vocabulary (Exposed / Loadable / Hidden /
//  Disabled / Blocked / Unavailable), per-tool token estimates, index and
//  search reason codes, and the reporter-safe export — without putting that
//  vocabulary on every catalog row.
//

import AppKit
import SwiftUI

// MARK: - Exposure Filters

private enum ToolExposureSourceFilter: String, CaseIterable, Identifiable {
    case all
    case builtIn
    case runtime
    case plugin
    case mcpProvider
    case sandboxPlugin
    case native
    case unknown

    var id: String { rawValue }

    var source: ToolExposureSource? {
        switch self {
        case .all: return nil
        case .builtIn: return .builtIn
        case .runtime: return .runtime
        case .plugin: return .plugin
        case .mcpProvider: return .mcpProvider
        case .sandboxPlugin: return .sandboxPlugin
        case .native: return .native
        case .unknown: return .unknown
        }
    }

    var title: String {
        source?.displayLabel ?? "All Sources"
    }
}

private enum ToolExposureStateFilter: String, CaseIterable, Identifiable {
    case all
    case exposed
    case loadable
    case hidden
    case disabled
    case blocked
    case unavailable

    var id: String { rawValue }

    var state: ToolExposureState? {
        switch self {
        case .all: return nil
        case .exposed: return .exposed
        case .loadable: return .loadable
        case .hidden: return .hidden
        case .disabled: return .disabled
        case .blocked: return .blocked
        case .unavailable: return .unavailable
        }
    }

    var title: String {
        state?.displayLabel ?? "All States"
    }

    static func filter(for state: ToolExposureState) -> ToolExposureStateFilter {
        switch state {
        case .exposed: return .exposed
        case .loadable: return .loadable
        case .hidden: return .hidden
        case .disabled: return .disabled
        case .blocked: return .blocked
        case .unavailable: return .unavailable
        }
    }
}

extension ToolExposureSourceFilter: ToolCatalogFilterOption {}
extension ToolExposureStateFilter: ToolCatalogFilterOption {}

/// Shared color/icon styling for exposure states, used by the summary chips
/// and the per-row state labels so they always agree.
private enum ToolExposureStateStyle {
    static func color(for state: ToolExposureState, theme: ThemeProtocol) -> Color {
        switch state {
        case .exposed: return theme.status.success.foreground
        case .loadable: return theme.action.primary.default.background
        case .hidden: return theme.status.warning.foreground
        case .disabled: return theme.text.secondary
        case .blocked, .unavailable: return theme.status.error.foreground
        }
    }

    static func icon(for state: ToolExposureState) -> String {
        switch state {
        case .exposed: return "eye"
        case .loadable: return "arrow.down.circle"
        case .hidden: return "eye.slash"
        case .disabled: return "power"
        case .blocked: return "lock"
        case .unavailable: return "exclamationmark.triangle"
        }
    }
}

// MARK: - Advanced Diagnostics Section

struct ToolAdvancedDiagnosticsSection: View {
    @Environment(\.theme) private var theme

    let diagnostic: ToolExposureDiagnostic
    /// Free-text query from the catalog toolbar, applied to the diagnostic
    /// rows alongside the section's own source/state filters.
    let searchText: String

    @State private var isExpanded = false
    @State private var sourceFilter: ToolExposureSourceFilter = .all
    @State private var stateFilter: ToolExposureStateFilter = .all
    @State private var showAllRows = false
    @State private var exportError: String?

    private var filteredRows: [ToolExposureDiagnostic.Row] {
        diagnostic.filteredRows(
            query: searchText,
            source: sourceFilter.source,
            state: stateFilter.state
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            headerButton

            if isExpanded {
                Divider()

                FlowLayout(spacing: theme.space.s6) {
                    exposureCountChip(.exposed)
                    exposureCountChip(.loadable)
                    exposureCountChip(.hidden)
                    exposureCountChip(.disabled)
                    exposureCountChip(.blocked)
                    exposureCountChip(.unavailable)
                }

                HStack(spacing: theme.space.s8) {
                    ToolFilterMenu(
                        icon: "square.grid.2x2",
                        accessibilityTitle: L("Exposure source filter"),
                        options: ToolExposureSourceFilter.allCases,
                        selection: $sourceFilter
                    )

                    ToolFilterMenu(
                        icon: "line.3.horizontal.decrease.circle",
                        accessibilityTitle: L("Exposure state filter"),
                        options: ToolExposureStateFilter.allCases,
                        selection: $stateFilter
                    )

                    Spacer(minLength: 8)

                    exportButton
                }

                rowsList
            }
        }
        .padding(theme.space.s16)
        .frame(maxWidth: .infinity)
        .settingsChrome(.card)
        .alert(
            Text("Export Failed", bundle: .module),
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )
        ) {
            Button(role: .cancel) {
                exportError = nil
            } label: {
                Text("OK", bundle: .module)
            }
        } message: {
            if let error = exportError {
                Text(error)
            }
        }
    }

    private var headerButton: some View {
        Button {
            withAnimation(theme.motion.springAnimation) {
                isExpanded.toggle()
            }
        } label: {
            HStack(alignment: .center, spacing: theme.space.s12) {
SettingsIconTile(icon: "slider.horizontal.3", size: 36)

                VStack(alignment: .leading, spacing: theme.space.s2) {
                    Text("Advanced diagnostics", bundle: .module)
                        .font(SettingsFont.cardTitle)
                        .foregroundColor(theme.text.primary)
                    Text("Audit exactly how each tool is exposed to the model", bundle: .module)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                StatusChip(L("\(filteredRows.count)/\(diagnostic.rows.count)"), tone: .neutral)
                    .fixedSize()

                Image(systemName: "chevron.right")
                    .glyphSize(.footnote, weight: .semibold)
                    .foregroundColor(theme.text.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(Text("Advanced diagnostics", bundle: .module))
        .accessibilityHint(Text("Shows exact tool exposure states, token estimates, and export", bundle: .module))
    }

    private var exportButton: some View {
        Button(action: exportReport) {
            HStack(spacing: theme.space.s4) {
                Image(systemName: "square.and.arrow.up")
                    .glyphSize(.footnote, weight: .semibold)
                Text("Export", bundle: .module)
                    .font(SettingsFont.smallLabel)
            }
            .foregroundColor(theme.text.primary)
            .padding(.horizontal, theme.space.s8)
            .frame(height: 28)
            .settingsChrome(.subtle)
        }
        .buttonStyle(PlainButtonStyle())
        .fixedSize()
        .help(Text("Export reporter-safe exposure report", bundle: .module))
        .accessibilityLabel(Text("Export reporter-safe exposure report", bundle: .module))
    }

    /// A summary chip that doubles as a one-tap state filter. `lineLimit(1)` +
    /// `fixedSize` keep each label on one line; `FlowLayout` wraps the row
    /// instead of letting labels break character-by-character.
    private func exposureCountChip(_ state: ToolExposureState) -> some View {
        let isActive = stateFilter.state == state
        let tint = ToolExposureStateStyle.color(for: state, theme: theme)
        return FilterChip(
            state.displayLabel,
            icon: ToolExposureStateStyle.icon(for: state),
            count: diagnostic.stateCounts[state, default: 0],
            isSelected: isActive,
            tint: tint,
            help: L("Filter by this state")
        ) {
            stateFilter = isActive ? .all : ToolExposureStateFilter.filter(for: state)
        }
    }

    @ViewBuilder
    private var rowsList: some View {
        let rows = filteredRows
        if rows.isEmpty {
            HStack(spacing: theme.space.s8) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundColor(theme.text.tertiary)
                Text("No exposure rows match the current filters", bundle: .module)
                    .font(SettingsFont.caption)
                    .foregroundColor(theme.text.secondary)
                Spacer()
            }
            .padding(theme.space.s12)
            .frame(maxWidth: .infinity)
            .settingsChrome(.inset)
        } else {
            let cap = toolGroupRenderCapValue
            let shown = (showAllRows || rows.count <= cap) ? rows : Array(rows.prefix(cap))

            VStack(spacing: theme.space.s4) {
                ForEach(shown) { row in
                    diagnosticRow(row)
                }

                if rows.count > cap {
                    ShowAllToolsButton(
                        hiddenCount: rows.count - cap,
                        isExpanded: showAllRows
                    ) {
                        showAllRows.toggle()
                    }
                }
            }
        }
    }

    private func diagnosticRow(_ row: ToolExposureDiagnostic.Row) -> some View {
        HStack(spacing: theme.space.s8) {
            Image(systemName: ToolExposureStateStyle.icon(for: row.state))
                .glyphSize(.micro, weight: .semibold)
                .foregroundColor(ToolExposureStateStyle.color(for: row.state, theme: theme))
                .frame(width: 16)

            Text(row.toolName)
                .font(SettingsFont.monoSmall)
                .foregroundColor(theme.text.primary)
                .lineLimit(1)

            StatusChip(row.state.displayLabel, tint: ToolExposureStateStyle.color(for: row.state, theme: theme))

            StatusChip(row.source.displayLabel, tone: .neutral)

            Spacer(minLength: 4)

            Text("tokens \(row.tokenEstimate)", bundle: .module)
                .font(SettingsFont.monoSmall)
                .foregroundColor(theme.text.tertiary)
                .fixedSize()
        }
        .padding(.horizontal, theme.space.s8)
        .padding(.vertical, theme.space.s6)
        .settingsChrome(.inset)
        .help(Self.diagnosticsDetail(for: row))
    }

    /// Verbose index/search diagnostics, shown on hover so rows stay compact.
    private static func diagnosticsDetail(for row: ToolExposureDiagnostic.Row) -> String {
        let index = row.indexedForSearch ? "indexed" : "not indexed"
        let search = row.searchableByCapabilitiesDiscover ? "discoverable" : "not discoverable"
        let reasons = row.searchReasonCodes.map(\.rawValue).joined(separator: ", ")
        var detail = "\(index) / \(search)"
        if !reasons.isEmpty { detail += " / \(reasons)" }
        return detail + " · tokens \(row.tokenEstimate)"
    }

    private func exportReport() {
        let report = diagnostic.reporterSafeMarkdown(rows: filteredRows)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "osaurus-tool-exposure-report.md"
        Task { @MainActor in
            guard await panel.beginModal() == .OK, let url = panel.url else { return }
            do {
                try report.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }
}
