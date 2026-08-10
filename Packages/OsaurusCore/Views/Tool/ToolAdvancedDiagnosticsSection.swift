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
        case .exposed: return theme.successColor
        case .loadable: return theme.accentColor
        case .hidden: return theme.warningColor
        case .disabled: return theme.secondaryText
        case .blocked, .unavailable: return theme.errorColor
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
        VStack(alignment: .leading, spacing: 12) {
            headerButton

            if isExpanded {
                Divider()

                FlowLayout(spacing: 6) {
                    exposureCountChip(.exposed)
                    exposureCountChip(.loadable)
                    exposureCountChip(.hidden)
                    exposureCountChip(.disabled)
                    exposureCountChip(.blocked)
                    exposureCountChip(.unavailable)
                }

                HStack(spacing: 8) {
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
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(HoverableCardBackground())
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
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.accentColor.opacity(0.12))
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(theme.accentColor)
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Advanced diagnostics", bundle: .module)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(theme.primaryText)
                    Text("Audit exactly how each tool is exposed to the model", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text("\(filteredRows.count)/\(diagnostic.rows.count)", bundle: .module)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(theme.tertiaryBackground))
                    .fixedSize()

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
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
            HStack(spacing: 5) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 11, weight: .semibold))
                Text("Export", bundle: .module)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(theme.primaryText)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(theme.tertiaryBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(theme.inputBorder, lineWidth: 1)
                    )
            )
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
        return Button {
            stateFilter = isActive ? .all : ToolExposureStateFilter.filter(for: state)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: ToolExposureStateStyle.icon(for: state))
                    .font(.system(size: 9, weight: .semibold))
                Text("\(diagnostic.stateCounts[state, default: 0]) \(state.displayLabel)", bundle: .module)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundColor(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(tint.opacity(isActive ? 0.22 : 0.12))
                    .overlay(Capsule().stroke(tint.opacity(isActive ? 0.55 : 0), lineWidth: 1))
            )
        }
        .buttonStyle(PlainButtonStyle())
        .help(Text("Filter by this state", bundle: .module))
    }

    @ViewBuilder
    private var rowsList: some View {
        let rows = filteredRows
        if rows.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundColor(theme.tertiaryText)
                Text("No exposure rows match the current filters", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.tertiaryBackground.opacity(0.5)))
        } else {
            let cap = toolGroupRenderCapValue
            let shown = (showAllRows || rows.count <= cap) ? rows : Array(rows.prefix(cap))

            VStack(spacing: 4) {
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
        HStack(spacing: 8) {
            Image(systemName: ToolExposureStateStyle.icon(for: row.state))
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(ToolExposureStateStyle.color(for: row.state, theme: theme))
                .frame(width: 16)

            Text(row.toolName)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)

            Text(row.state.displayLabel)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(ToolExposureStateStyle.color(for: row.state, theme: theme))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(
                        ToolExposureStateStyle.color(for: row.state, theme: theme).opacity(0.12)
                    )
                )

            Text(row.source.displayLabel)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(theme.tertiaryBackground))

            Spacer(minLength: 4)

            Text("tokens \(row.tokenEstimate)", bundle: .module)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(theme.tertiaryText)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.tertiaryBackground.opacity(0.35)))
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
