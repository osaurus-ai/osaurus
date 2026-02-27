//
//  CapabilitiesTableRepresentable.swift
//  osaurus
//
//  NSViewRepresentable wrapping an NSTableView for the capabilities
//  selector item list. Provides true cell reuse and efficient diffing
//  for large tool/skill lists (e.g. OpenRouter with thousands of models).
//
//  Key design decisions:
//  - NSDiffableDataSource with row IDs for efficient structural updates.
//  - Manual row heights via `tableView(_:heightOfRow:)` to avoid the
//    expensive Auto Layout measurement that `usesAutomaticRowHeights`
//    forces through NSHostingView on every cell appearance.
//  - Two update paths:
//      1. No-change early return (skip if rows are identical).
//      2. Full snapshot (apply diff via diffable data source).
//  - Single NSTrackingArea for hover instead of per-row SwiftUI trackers.
//

import AppKit
import SwiftUI

// MARK: - Supporting Types

/// Single-section identifier for the diffable data source.
enum CapabilitySection: Hashable {
    case main
}

/// Flattened row model for all three capability tabs.
/// Each case carries the data needed to render its SwiftUI row view.
enum CapabilityRow: Equatable, Identifiable {
    case groupHeader(
        id: String,
        name: String,
        icon: String,
        enabledCount: Int,
        totalCount: Int,
        isExpanded: Bool
    )
    case tool(
        id: String,
        name: String,
        description: String,
        enabled: Bool,
        isAgentRestricted: Bool,
        catalogTokens: Int,
        estimatedTokens: Int
    )
    case skill(
        id: String,
        name: String,
        description: String,
        enabled: Bool,
        isBuiltIn: Bool,
        isFromPlugin: Bool,
        estimatedTokens: Int
    )
    case compoundPlugin(
        id: String,
        name: String,
        toolCount: Int,
        skillCount: Int,
        isActive: Bool
    )

    var id: String {
        switch self {
        case .groupHeader(let id, _, _, _, _, _): return "gh-\(id)"
        case .tool(let id, _, _, _, _, _, _): return "tool-\(id)"
        case .skill(let id, _, _, _, _, _, _): return "skill-\(id)"
        case .compoundPlugin(let id, _, _, _, _): return "cp-\(id)"
        }
    }
}

/// Bundles all per-render context the coordinator needs to configure cells.
struct CapabilityRenderingContext {
    let theme: ThemeProtocol

    // Group header callbacks
    let onToggleGroup: ((String) -> Void)?
    let onEnableAllInGroup: ((String) -> Void)?
    let onDisableAllInGroup: ((String) -> Void)?

    // Tool/skill/plugin toggle callbacks
    let onToggleTool: ((String, Bool) -> Void)?
    let onToggleSkill: ((String) -> Void)?
    let onToggleCompoundPlugin: ((String) -> Void)?
}

// MARK: - CapabilitiesTableRepresentable

struct CapabilitiesTableRepresentable: NSViewRepresentable {

    /// Flattened rows for the current tab (built by the parent SwiftUI view).
    let rows: [CapabilityRow]
    let theme: ThemeProtocol

    // Group header callbacks
    var onToggleGroup: ((String) -> Void)?
    var onEnableAllInGroup: ((String) -> Void)?
    var onDisableAllInGroup: ((String) -> Void)?

    // Tool/skill/plugin toggle callbacks
    var onToggleTool: ((String, Bool) -> Void)?
    var onToggleSkill: ((String) -> Void)?
    var onToggleCompoundPlugin: ((String) -> Void)?

    // MARK: - NSViewRepresentable Lifecycle

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let tableView = Self.makeTableView()
        let scrollView = Self.makeScrollView(documentView: tableView)

        coordinator.tableView = tableView
        coordinator.setupDataSource(for: tableView)
        coordinator.setupHoverTracking(on: tableView)
        coordinator.setupScrollObservation(for: scrollView)

        coordinator.applyRows(rows, context: renderingContext)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.applyRows(rows, context: renderingContext)
    }

    // MARK: - View Factory Helpers

    private var renderingContext: CapabilityRenderingContext {
        CapabilityRenderingContext(
            theme: theme,
            onToggleGroup: onToggleGroup,
            onEnableAllInGroup: onEnableAllInGroup,
            onDisableAllInGroup: onDisableAllInGroup,
            onToggleTool: onToggleTool,
            onToggleSkill: onToggleSkill,
            onToggleCompoundPlugin: onToggleCompoundPlugin
        )
    }

    private static func makeTableView() -> HoverTrackingTableView {
        let tv = HoverTrackingTableView()
        tv.style = .plain
        tv.headerView = nil
        tv.rowSizeStyle = .custom
        tv.selectionHighlightStyle = .none
        tv.backgroundColor = .clear
        tv.intercellSpacing = .zero
        tv.usesAlternatingRowBackgroundColors = false
        tv.refusesFirstResponder = true
        tv.allowsMultipleSelection = false
        tv.allowsEmptySelection = true
        tv.gridStyleMask = []
        tv.usesAutomaticRowHeights = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("CapabilityColumn"))
        column.resizingMask = .autoresizingMask
        tv.addTableColumn(column)
        return tv
    }

    private static func makeScrollView(documentView: NSView) -> NSScrollView {
        let sv = NSScrollView()
        sv.documentView = documentView
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.autohidesScrollers = true
        sv.drawsBackground = false
        sv.contentView.drawsBackground = false
        sv.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        return sv
    }
}

// MARK: - Coordinator

extension CapabilitiesTableRepresentable {

    @MainActor
    final class Coordinator: NSObject, NSTableViewDelegate {

        // MARK: AppKit References

        weak var tableView: NSTableView?
        private(set) var dataSource: NSTableViewDiffableDataSource<CapabilitySection, String>?

        // MARK: Row State

        /// Ordered row IDs matching the current snapshot.
        private(set) var rowIds: [String] = []
        /// Row lookup keyed by row ID.
        private(set) var rowLookup: [String: CapabilityRow] = [:]

        // MARK: Rendering Context

        private var ctx = CapabilityRenderingContext(
            theme: LightTheme(),
            onToggleGroup: nil,
            onEnableAllInGroup: nil,
            onDisableAllInGroup: nil,
            onToggleTool: nil,
            onToggleSkill: nil,
            onToggleCompoundPlugin: nil
        )

        // MARK: Hover

        private var hoveredRowId: String?
        private var isScrolling = false

        // MARK: - Setup

        func setupDataSource(for tableView: NSTableView) {
            dataSource = NSTableViewDiffableDataSource<CapabilitySection, String>(
                tableView: tableView
            ) { [weak self] tableView, _, row, itemId in
                self?.dequeueAndConfigure(tableView: tableView, row: row, rowId: itemId)
                    ?? NSView()
            }
            tableView.delegate = self
        }

        func setupHoverTracking(on tableView: HoverTrackingTableView) {
            tableView.onMouseMoved = { [weak self] event in
                self?.handleMouseMoved(with: event)
            }
            tableView.onMouseExited = { [weak self] in
                self?.setHoveredRow(nil)
            }
        }

        func setupScrollObservation(for scrollView: NSScrollView) {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(onScrollStart),
                name: NSScrollView.willStartLiveScrollNotification,
                object: scrollView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(onScrollEnd),
                name: NSScrollView.didEndLiveScrollNotification,
                object: scrollView
            )
        }

        @objc private func onScrollStart() {
            isScrolling = true
            setHoveredRow(nil)
        }

        @objc private func onScrollEnd() {
            isScrolling = false
        }

        // MARK: - Apply Rows (Main Entry Point)

        func applyRows(
            _ rows: [CapabilityRow],
            context: CapabilityRenderingContext
        ) {
            ctx = context

            let newIds = rows.map(\.id)
            let newLookup = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })

            // --- Path 1: No-change early return ---
            if newIds == rowIds, !hasContentChanges(newLookup: newLookup) {
                return
            }

            // --- Path 2: Content changed but IDs unchanged — update visible cells in place ---
            if newIds == rowIds {
                rowLookup = newLookup
                reconfigureVisibleCells()
                return
            }

            // --- Path 3: Full snapshot ---
            applyFullSnapshot(newIds: newIds, newLookup: newLookup)
        }

        // MARK: - Update Paths (Private)

        private func hasContentChanges(newLookup: [String: CapabilityRow]) -> Bool {
            for id in rowIds {
                if newLookup[id] != rowLookup[id] { return true }
            }
            return false
        }

        /// Reconfigure all currently visible cells with updated data.
        private func reconfigureVisibleCells() {
            guard let tableView else { return }
            let range = tableView.rows(in: tableView.visibleRect)
            for row in range.location ..< (range.location + range.length) {
                guard row < rowIds.count else { continue }
                let rowId = rowIds[row]
                guard let rowData = rowLookup[rowId],
                    let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TableHostingCellView
                else { continue }
                configureCell(cell, with: rowData)
            }
        }

        /// Apply a new diffable snapshot.
        private func applyFullSnapshot(
            newIds: [String],
            newLookup: [String: CapabilityRow]
        ) {
            rowLookup = newLookup
            rowIds = newIds

            var snapshot = NSDiffableDataSourceSnapshot<CapabilitySection, String>()
            snapshot.appendSections([.main])
            snapshot.appendItems(newIds, toSection: .main)

            dataSource?.apply(snapshot, animatingDifferences: false)
        }

        // MARK: - Cell Factory

        private func dequeueAndConfigure(tableView: NSTableView, row: Int, rowId: String) -> NSView {
            guard let rowData = rowLookup[rowId] else { return NSView() }

            // Use distinct reuse identifiers for each row type to ensure
            // NSHostingView recycles the correct SwiftUI view hierarchy.
            // This prevents expensive view rebuilding during scrolling.
            let reuseIdentifier: NSUserInterfaceItemIdentifier
            switch rowData {
            case .groupHeader:
                reuseIdentifier = NSUserInterfaceItemIdentifier("CapabilityGroupHeaderCell")
            case .tool:
                reuseIdentifier = NSUserInterfaceItemIdentifier("CapabilityToolRowCell")
            case .skill:
                reuseIdentifier = NSUserInterfaceItemIdentifier("CapabilitySkillRowCell")
            case .compoundPlugin:
                reuseIdentifier = NSUserInterfaceItemIdentifier("CapabilityCompoundPluginRowCell")
            }

            let cell: TableHostingCellView
            if let reused = tableView.makeView(
                withIdentifier: reuseIdentifier,
                owner: nil
            ) as? TableHostingCellView {
                cell = reused
            } else {
                cell = TableHostingCellView(frame: .zero)
                cell.identifier = reuseIdentifier
            }

            configureCell(cell, with: rowData)
            return cell
        }

        private func configureCell(_ cell: TableHostingCellView, with row: CapabilityRow) {
            let isHovered = hoveredRowId == row.id
            let theme = ctx.theme

            switch row {
            case .groupHeader(let id, let name, let icon, let enabledCount, let totalCount, let isExpanded):
                cell.configure(
                    id: row.id,
                    content:
                        GroupHeaderCell(
                            name: name,
                            icon: icon,
                            enabledCount: enabledCount,
                            totalCount: totalCount,
                            isExpanded: isExpanded,
                            isHovered: isHovered,
                            onToggle: { [weak self] in self?.ctx.onToggleGroup?(id) },
                            onEnableAll: { [weak self] in self?.ctx.onEnableAllInGroup?(id) },
                            onDisableAll: { [weak self] in self?.ctx.onDisableAllInGroup?(id) }
                        )
                        .environment(\.theme, theme)
                )

            case .tool(
                let id,
                let name,
                let description,
                let enabled,
                let isAgentRestricted,
                let catalogTokens,
                let estimatedTokens
            ):
                cell.configure(
                    id: row.id,
                    content:
                        ToolRowCell(
                            name: name,
                            description: description,
                            enabled: enabled,
                            isAgentRestricted: isAgentRestricted,
                            catalogTokens: catalogTokens,
                            estimatedTokens: estimatedTokens,
                            isHovered: isHovered,
                            onToggle: { [weak self] in self?.ctx.onToggleTool?(id, enabled) }
                        )
                        .environment(\.theme, theme)
                )

            case .skill(
                let id,
                let name,
                let description,
                let enabled,
                let isBuiltIn,
                let isFromPlugin,
                let estimatedTokens
            ):
                cell.configure(
                    id: row.id,
                    content:
                        SkillRowCell(
                            name: name,
                            description: description,
                            enabled: enabled,
                            isBuiltIn: isBuiltIn,
                            isFromPlugin: isFromPlugin,
                            estimatedTokens: estimatedTokens,
                            isHovered: isHovered,
                            onToggle: { [weak self] in self?.ctx.onToggleSkill?(id) }
                        )
                        .environment(\.theme, theme)
                )

            case .compoundPlugin(let id, let name, let toolCount, let skillCount, let isActive):
                cell.configure(
                    id: row.id,
                    content:
                        CompoundPluginRowCell(
                            name: name,
                            toolCount: toolCount,
                            skillCount: skillCount,
                            isActive: isActive,
                            isHovered: isHovered,
                            onToggle: { [weak self] in self?.ctx.onToggleCompoundPlugin?(id) }
                        )
                        .environment(\.theme, theme)
                )
            }
        }

        // MARK: - Hover Tracking

        private func handleMouseMoved(with event: NSEvent) {
            guard !isScrolling else { return }
            guard let tableView else { return setHoveredRow(nil) }
            let point = tableView.convert(event.locationInWindow, from: nil)
            let row = tableView.row(at: point)

            guard row >= 0, row < rowIds.count else {
                return setHoveredRow(nil)
            }
            setHoveredRow(rowIds[row])
        }

        private func setHoveredRow(_ newRowId: String?) {
            guard hoveredRowId != newRowId else { return }
            let oldRowId = hoveredRowId
            hoveredRowId = newRowId

            guard let tableView else { return }

            // Reconfigure old and new hovered rows
            for targetId in [oldRowId, newRowId] {
                guard let targetId,
                    let idx = rowIds.firstIndex(of: targetId),
                    let rowData = rowLookup[targetId],
                    let cell = tableView.view(atColumn: 0, row: idx, makeIfNecessary: false) as? TableHostingCellView
                else { continue }
                configureCell(cell, with: rowData)
            }
        }

        // MARK: - NSTableViewDelegate

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row < rowIds.count, let rowData = rowLookup[rowIds[row]] else { return 44 }
            return Self.estimatedHeight(for: rowData)
        }

        // MARK: - Row Height Estimation

        /// Pre-calculated row heights based on content, avoiding expensive
        /// Auto Layout measurement during scrolling.
        private static func estimatedHeight(for row: CapabilityRow) -> CGFloat {
            switch row {
            case .groupHeader:
                // 12pt padding top/bottom + ~16pt content
                return 44

            case .tool:
                // 10pt padding top/bottom + name line + description line
                // Tool rows always show description, so height is consistent
                return 56

            case .skill:
                // 10pt padding top/bottom + name line + description line
                return 56

            case .compoundPlugin:
                // 10pt padding top/bottom + name line + tool/skill count line
                return 56
            }
        }
    }
}

// MARK: - Cell SwiftUI Views

/// Group header cell rendered in the NSTableView.
private struct GroupHeaderCell: View {
    let name: String
    let icon: String
    let enabledCount: Int
    let totalCount: Int
    let isExpanded: Bool
    let isHovered: Bool
    let onToggle: () -> Void
    let onEnableAll: () -> Void
    let onDisableAll: () -> Void

    @Environment(\.theme) private var theme

    private var allEnabled: Bool { enabledCount == totalCount }
    private var noneEnabled: Bool { enabledCount == 0 }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
                .frame(width: 12)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))

            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(isHovered ? theme.accentColor : theme.secondaryText)

            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)

            Spacer()

            // All/None — always rendered, visibility controlled by opacity
            HStack(spacing: 4) {
                Button {
                    onEnableAll()
                } label: {
                    Text("All")
                        .font(.system(size: 9, weight: allEnabled ? .bold : .medium))
                        .foregroundColor(allEnabled ? theme.accentColor : theme.tertiaryText)
                }
                Text("/").font(.system(size: 9)).foregroundColor(theme.tertiaryText)
                Button {
                    onDisableAll()
                } label: {
                    Text("None")
                        .font(.system(size: 9, weight: noneEnabled ? .bold : .medium))
                        .foregroundColor(noneEnabled ? theme.accentColor : theme.tertiaryText)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(theme.primaryBackground)
                    .overlay(Capsule().strokeBorder(theme.primaryBorder.opacity(0.15), lineWidth: 1))
            )
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)

            // Count badge
            CountBadge(enabled: enabledCount, total: totalCount)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        .modifier(HoverRowStyle(isHovered: isHovered, showAccent: true))
    }
}

/// Tool row cell rendered in the NSTableView.
private struct ToolRowCell: View {
    let name: String
    let description: String
    let enabled: Bool
    let isAgentRestricted: Bool
    let catalogTokens: Int
    let estimatedTokens: Int
    let isHovered: Bool
    let onToggle: () -> Void

    @Environment(\.theme) private var theme

    private var nameColor: Color {
        if isAgentRestricted { return theme.tertiaryText }
        return enabled ? theme.primaryText : theme.secondaryText
    }

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { enabled }, set: { _ in onToggle() }))
                .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                .scaleEffect(0.7)
                .frame(width: 36)
                .disabled(isAgentRestricted)
                .opacity(isAgentRestricted ? 0.4 : 1.0)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(nameColor)
                        .lineLimit(1)

                    if isAgentRestricted {
                        SmallCapsuleBadge(text: "Chat Mode only")
                    }
                }
                Text(description)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(2)
            }

            Spacer()

            if !isAgentRestricted {
                TokenBadge(count: catalogTokens)
                    .help(
                        catalogTokens == estimatedTokens
                            ? "~\(estimatedTokens) tokens"
                            : "Catalog: ~\(catalogTokens), Full: ~\(estimatedTokens) tokens"
                    )
            }
        }
        .padding(.leading, 32)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            if !isAgentRestricted { onToggle() }
        }
        .modifier(HoverRowStyle(isHovered: isHovered, showAccent: enabled && !isAgentRestricted))
        .help(
            isAgentRestricted
                ? "Available in Chat Mode only. Work Mode includes equivalent built-in tools."
                : ""
        )
    }
}

/// Skill row cell rendered in the NSTableView.
private struct SkillRowCell: View {
    let name: String
    let description: String
    let enabled: Bool
    let isBuiltIn: Bool
    let isFromPlugin: Bool
    let estimatedTokens: Int
    let isHovered: Bool
    let onToggle: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { enabled }, set: { _ in onToggle() }))
                .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                .scaleEffect(0.7)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(enabled ? theme.primaryText : theme.secondaryText)
                        .lineLimit(1)

                    if isBuiltIn {
                        SmallCapsuleBadge(text: "Built-in")
                    } else if isFromPlugin {
                        SmallCapsuleBadge(text: "Plugin", icon: "puzzlepiece.extension")
                    }
                }
                Text(description)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(2)
            }

            Spacer()

            TokenBadge(count: estimatedTokens)
                .help("~\(estimatedTokens) tokens")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        .modifier(HoverRowStyle(isHovered: isHovered, showAccent: enabled))
    }
}

/// Compound plugin row cell rendered in the NSTableView.
private struct CompoundPluginRowCell: View {
    let name: String
    let toolCount: Int
    let skillCount: Int
    let isActive: Bool
    let isHovered: Bool
    let onToggle: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { isActive }, set: { _ in onToggle() }))
                .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                .scaleEffect(0.7)
                .frame(width: 36)

            // Plugin icon with sparkle overlay
            ZStack {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 14))
                    .foregroundColor(isActive ? theme.accentColor : theme.tertiaryText)

                Image(systemName: "sparkle")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(isActive ? theme.accentColor : theme.tertiaryText)
                    .offset(x: 8, y: -8)
            }
            .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isActive ? theme.primaryText : theme.secondaryText)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    HStack(spacing: 2) {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.system(size: 8))
                        Text("\(toolCount)")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundColor(theme.tertiaryText)

                    Text("+")
                        .font(.system(size: 8))
                        .foregroundColor(theme.tertiaryText)

                    HStack(spacing: 2) {
                        Image(systemName: "lightbulb")
                            .font(.system(size: 8))
                        Text("\(skillCount)")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundColor(theme.tertiaryText)
                }
            }

            Spacer()

            // Active/inactive badge
            Text(isActive ? "Active" : "Inactive")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(isActive ? theme.accentColor : theme.tertiaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(isActive ? theme.accentColor.opacity(0.15) : theme.secondaryBackground.opacity(0.5))
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    isActive ? theme.accentColor.opacity(0.2) : theme.primaryBorder.opacity(0.1),
                                    lineWidth: 1
                                )
                        )
                )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        .modifier(HoverRowStyle(isHovered: isHovered, showAccent: isActive))
    }
}

// MARK: - Shared Components (Internal to this file)

/// Hover background + border applied to row items and group headers.
private struct HoverRowStyle: ViewModifier {
    let isHovered: Bool
    let showAccent: Bool

    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? theme.secondaryBackground.opacity(0.7) : Color.clear)
                    .overlay(
                        isHovered && showAccent
                            ? RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [theme.accentColor.opacity(0.06), Color.clear],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                            : nil
                    )
            )
            .overlay(
                isHovered
                    ? RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    theme.glassEdgeLight.opacity(0.12),
                                    theme.primaryBorder.opacity(0.08),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                    : nil
            )
    }
}

/// Token count badge (e.g. "~42 tokens").
private struct TokenBadge: View {
    let count: Int

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            Text("~\(count)").font(.system(size: 10, weight: .medium, design: .monospaced))
            Text("tokens").font(.system(size: 9)).opacity(0.6)
        }
        .foregroundColor(theme.tertiaryText)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(theme.secondaryBackground.opacity(0.5)))
    }
}

/// Small capsule label (e.g. "Built-in", "Chat Mode only", "Plugin").
private struct SmallCapsuleBadge: View {
    let text: String
    var icon: String? = nil

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 3) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 7))
            }
            Text(text)
                .font(.system(size: 8, weight: .medium))
        }
        .foregroundColor(theme.secondaryText)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(theme.secondaryBackground)
                .overlay(Capsule().strokeBorder(theme.primaryBorder.opacity(0.1), lineWidth: 1))
        )
    }
}

/// Enabled/total count badge (e.g. "3/5").
private struct CountBadge: View {
    let enabled: Int
    let total: Int

    @Environment(\.theme) private var theme

    var body: some View {
        Text("\(enabled)/\(total)")
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(enabled > 0 ? theme.accentColor : theme.tertiaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(enabled > 0 ? theme.accentColor.opacity(0.15) : theme.primaryBackground)
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                enabled > 0 ? theme.accentColor.opacity(0.2) : theme.primaryBorder.opacity(0.1),
                                lineWidth: 1
                            )
                    )
            )
    }
}
