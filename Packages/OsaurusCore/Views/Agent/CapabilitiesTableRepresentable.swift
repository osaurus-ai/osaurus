//
//  CapabilitiesTableRepresentable.swift
//  osaurus
//
//  NSViewRepresentable wrapping an NSTableView for the capabilities
//  selector item list. Provides true cell reuse and efficient diffing
//  for large tool/skill lists.
//
//  Key design decisions:
//  - NSDiffableDataSource with row IDs for efficient structural updates.
//  - Manual row heights via `tableView(_:heightOfRow:)` to avoid the
//    expensive Auto Layout measurement that `usesAutomaticRowHeights`
//    forces through NSHostingView on every cell appearance.
//  - Three update paths:
//      1. No-change early return (skip if rows are identical).
//      2. Content-only update (reconfigure visible cells in place).
//      3. Full snapshot (apply diff via diffable data source).
//  - Single NSTrackingArea for hover instead of per-row SwiftUI trackers.
//  - Targeted hover reconfigure: only the old and new hovered cells
//    are reconfigured when hover changes, avoiding broadcast updates.
//

import AppKit
import SwiftUI

// MARK: - Supporting Types

enum CapabilitySection: Hashable {
    case main
}

/// Flattened row model for the unified capabilities list.
enum CapabilityRow: Equatable, Identifiable {
    case groupHeader(
        id: String,
        name: String,
        icon: String,
        enabledCount: Int,
        totalCount: Int,
        isExpanded: Bool,
        toolCount: Int,
        skillCount: Int,
        hasRoutes: Bool
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

    var id: String {
        switch self {
        case .groupHeader(let id, _, _, _, _, _, _, _, _): return "gh-\(id)"
        case .tool(let id, _, _, _, _, _, _): return "tool-\(id)"
        case .skill(let id, _, _, _, _, _, _): return "skill-\(id)"
        }
    }
}

/// Bundles all per-render context the coordinator needs to configure cells.
struct CapabilityRenderingContext {
    let theme: ThemeProtocol

    let onToggleGroup: ((String) -> Void)?
    let onEnableAllInGroup: ((String) -> Void)?
    let onDisableAllInGroup: ((String) -> Void)?

    let onToggleTool: ((String, Bool) -> Void)?
    let onToggleSkill: ((String) -> Void)?
}

// MARK: - CapabilitiesTableRepresentable

struct CapabilitiesTableRepresentable: NSViewRepresentable {

    let rows: [CapabilityRow]
    let theme: ThemeProtocol

    var onToggleGroup: ((String) -> Void)?
    var onEnableAllInGroup: ((String) -> Void)?
    var onDisableAllInGroup: ((String) -> Void)?

    var onToggleTool: ((String, Bool) -> Void)?
    var onToggleSkill: ((String) -> Void)?

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

        coordinator.applyRows(rows, context: renderingContext(coordinator: coordinator))
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.applyRows(rows, context: renderingContext(coordinator: context.coordinator))
    }

    // MARK: - View Factory Helpers

    private func renderingContext(coordinator: Coordinator) -> CapabilityRenderingContext {
        CapabilityRenderingContext(
            theme: theme,
            onToggleGroup: onToggleGroup,
            onEnableAllInGroup: onEnableAllInGroup,
            onDisableAllInGroup: onDisableAllInGroup,
            onToggleTool: onToggleTool,
            onToggleSkill: onToggleSkill
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

        private(set) var rowIds: [String] = []
        private(set) var rowLookup: [String: CapabilityRow] = [:]

        // MARK: Rendering Context

        private var ctx: CapabilityRenderingContext?

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

            if newIds == rowIds, !hasContentChanges(newLookup: newLookup) {
                return
            }

            if newIds == rowIds {
                rowLookup = newLookup
                reconfigureVisibleCells()
                return
            }

            applyFullSnapshot(newIds: newIds, newLookup: newLookup)
        }

        // MARK: - Update Paths (Private)

        private func hasContentChanges(newLookup: [String: CapabilityRow]) -> Bool {
            for id in rowIds {
                if newLookup[id] != rowLookup[id] { return true }
            }
            return false
        }

        private func reconfigureVisibleCells() {
            for row in visibleRowIndices() {
                reconfigureCell(at: row)
            }
        }

        /// Indices of rows currently inside the visible rect, clamped to
        /// `rowIds`. Returns an empty range if the table isn't installed
        /// or the visible rect doesn't intersect any rows yet (initial
        /// layout / detached state).
        private func visibleRowIndices() -> Range<Int> {
            guard let tableView else { return 0 ..< 0 }
            let range = tableView.rows(in: tableView.visibleRect)
            let upperBound = min(range.location + range.length, rowIds.count)
            let lowerBound = max(range.location, 0)
            guard lowerBound < upperBound else { return 0 ..< 0 }
            return lowerBound ..< upperBound
        }

        private func setHoveredRow(_ newId: String?) {
            let oldId = hoveredRowId
            guard newId != oldId else { return }
            hoveredRowId = newId

            if let oldId, let row = rowIds.firstIndex(of: oldId) {
                reconfigureCell(at: row)
            }
            if let newId, let row = rowIds.firstIndex(of: newId) {
                reconfigureCell(at: row)
            }
        }

        private func reconfigureCell(at row: Int) {
            guard let tableView, row < rowIds.count else { return }
            let rowId = rowIds[row]
            guard let rowData = rowLookup[rowId] else { return }
            let isHovered = hoveredRowId == rowId

            switch rowData {
            case .groupHeader:
                guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? HeaderCell,
                    let content = makeHeaderContent(rowData, isHovered: isHovered)
                else { return }
                cell.configure(id: rowData.id, content: content)

            case .tool:
                guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ToolCell,
                    let content = makeToolContent(rowData, isHovered: isHovered)
                else { return }
                cell.configure(id: rowData.id, content: content)

            case .skill:
                guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SkillCell,
                    let content = makeSkillContent(rowData, isHovered: isHovered)
                else { return }
                cell.configure(id: rowData.id, content: content)
            }
        }

        private func applyFullSnapshot(
            newIds: [String],
            newLookup: [String: CapabilityRow]
        ) {
            // Capture the on-screen ids BEFORE we swap the row state so we
            // can tell which cells were already visible (and therefore
            // retained by the diff) versus freshly inserted by the data
            // source.
            let previouslyVisibleIds = Set(visibleRowIndices().map { rowIds[$0] })

            rowLookup = newLookup
            rowIds = newIds

            var snapshot = NSDiffableDataSourceSnapshot<CapabilitySection, String>()
            snapshot.appendSections([.main])
            snapshot.appendItems(newIds, toSection: .main)

            dataSource?.apply(snapshot, animatingDifferences: false)

            // `NSTableViewDiffableDataSource.apply` only invokes the cell
            // provider for inserted items. Items whose id is unchanged but
            // whose payload changed (e.g. a group header that just flipped
            // `isExpanded`, or a row whose enabled count shifted) are left
            // alone, which is what produced the stale chevron / count badge
            // in #1003. Reconfigure any rows that were on-screen before the
            // diff so their cached payload matches `newLookup`.
            for row in visibleRowIndices() where previouslyVisibleIds.contains(rowIds[row]) {
                reconfigureCell(at: row)
            }
        }

        // MARK: - Reuse Identifiers

        private static let headerReuseId = NSUserInterfaceItemIdentifier("CapabilityGroupHeaderCell")
        private static let toolReuseId = NSUserInterfaceItemIdentifier("CapabilityToolRowCell")
        private static let skillReuseId = NSUserInterfaceItemIdentifier("CapabilitySkillRowCell")

        private typealias HeaderCell = TypedHostingCellView<ThemedContent<GroupHeaderCell>>
        private typealias ToolCell = TypedHostingCellView<ThemedContent<ToolRowCell>>
        private typealias SkillCell = TypedHostingCellView<ThemedContent<SkillRowCell>>

        // MARK: - Cell Content Builders

        private func makeHeaderContent(
            _ row: CapabilityRow,
            isHovered: Bool
        ) -> ThemedContent<GroupHeaderCell>? {
            guard
                case .groupHeader(
                    let id,
                    let name,
                    let icon,
                    let enabledCount,
                    let totalCount,
                    let isExpanded,
                    let toolCount,
                    let skillCount,
                    let hasRoutes
                ) = row, let theme = ctx?.theme
            else { return nil }
            return ThemedContent(
                theme: theme,
                content: GroupHeaderCell(
                    name: name,
                    icon: icon,
                    enabledCount: enabledCount,
                    totalCount: totalCount,
                    isExpanded: isExpanded,
                    toolCount: toolCount,
                    skillCount: skillCount,
                    hasRoutes: hasRoutes,
                    isHovered: isHovered,
                    onToggle: { [weak self] in self?.ctx?.onToggleGroup?(id) },
                    onEnableAll: { [weak self] in self?.ctx?.onEnableAllInGroup?(id) },
                    onDisableAll: { [weak self] in self?.ctx?.onDisableAllInGroup?(id) }
                )
            )
        }

        private func makeToolContent(
            _ row: CapabilityRow,
            isHovered: Bool
        ) -> ThemedContent<ToolRowCell>? {
            guard
                case .tool(
                    let id,
                    let name,
                    let description,
                    let enabled,
                    let isAgentRestricted,
                    let catalogTokens,
                    let estimatedTokens
                ) = row, let theme = ctx?.theme
            else { return nil }
            return ThemedContent(
                theme: theme,
                content: ToolRowCell(
                    name: name,
                    description: description,
                    enabled: enabled,
                    isAgentRestricted: isAgentRestricted,
                    catalogTokens: catalogTokens,
                    estimatedTokens: estimatedTokens,
                    isHovered: isHovered,
                    onToggle: { [weak self] in self?.ctx?.onToggleTool?(id, enabled) }
                )
            )
        }

        private func makeSkillContent(
            _ row: CapabilityRow,
            isHovered: Bool
        ) -> ThemedContent<SkillRowCell>? {
            guard
                case .skill(
                    let id,
                    let name,
                    let description,
                    let enabled,
                    let isBuiltIn,
                    let isFromPlugin,
                    let estimatedTokens
                ) = row, let theme = ctx?.theme
            else { return nil }
            return ThemedContent(
                theme: theme,
                content: SkillRowCell(
                    name: name,
                    description: description,
                    enabled: enabled,
                    isBuiltIn: isBuiltIn,
                    isFromPlugin: isFromPlugin,
                    estimatedTokens: estimatedTokens,
                    isHovered: isHovered,
                    onToggle: { [weak self] in self?.ctx?.onToggleSkill?(id) }
                )
            )
        }

        // MARK: - Cell Factory

        private func dequeueAndConfigure(tableView: NSTableView, row: Int, rowId: String) -> NSView {
            guard let rowData = rowLookup[rowId] else { return NSView() }
            let isHovered = hoveredRowId == rowId

            switch rowData {
            case .groupHeader:
                let cell =
                    tableView.makeView(withIdentifier: Self.headerReuseId, owner: nil) as? HeaderCell
                    ?? {
                        let c = HeaderCell(frame: .zero); c.identifier = Self.headerReuseId; return c
                    }()
                if let content = makeHeaderContent(rowData, isHovered: isHovered) {
                    cell.configure(id: rowData.id, content: content)
                }
                return cell

            case .tool:
                let cell =
                    tableView.makeView(withIdentifier: Self.toolReuseId, owner: nil) as? ToolCell
                    ?? {
                        let c = ToolCell(frame: .zero); c.identifier = Self.toolReuseId; return c
                    }()
                if let content = makeToolContent(rowData, isHovered: isHovered) {
                    cell.configure(id: rowData.id, content: content)
                }
                return cell

            case .skill:
                let cell =
                    tableView.makeView(withIdentifier: Self.skillReuseId, owner: nil) as? SkillCell
                    ?? {
                        let c = SkillCell(frame: .zero); c.identifier = Self.skillReuseId; return c
                    }()
                if let content = makeSkillContent(rowData, isHovered: isHovered) {
                    cell.configure(id: rowData.id, content: content)
                }
                return cell
            }
        }

        // MARK: - Hover Tracking

        private func handleMouseMoved(with event: NSEvent) {
            guard !isScrolling else { return }
            guard let tableView else {
                setHoveredRow(nil)
                return
            }
            let point = tableView.convert(event.locationInWindow, from: nil)
            let row = tableView.row(at: point)

            guard row >= 0, row < rowIds.count else {
                setHoveredRow(nil)
                return
            }
            setHoveredRow(rowIds[row])
        }

        // MARK: - NSTableViewDelegate

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row < rowIds.count, let rowData = rowLookup[rowIds[row]] else { return 44 }
            return Self.estimatedHeight(for: rowData)
        }

        // MARK: - Row Height Estimation

        private static func estimatedHeight(for row: CapabilityRow) -> CGFloat {
            switch row {
            case .groupHeader: return 44
            case .tool: return 56
            case .skill: return 56
            }
        }
    }
}

// MARK: - Themed Wrapper

/// Wraps a SwiftUI view with a theme environment value, giving a concrete
/// nameable type for use with TypedHostingCellView generic parameter.
struct ThemedContent<C: View>: View {
    let theme: ThemeProtocol
    let content: C

    var body: some View {
        content.environment(\.theme, theme)
    }
}

// MARK: - Cell SwiftUI Views

/// Group header cell with tool+skill breakdown, expand/collapse, and All/None controls.
struct GroupHeaderCell: View {
    let name: String
    let icon: String
    let enabledCount: Int
    let totalCount: Int
    let isExpanded: Bool
    let toolCount: Int
    let skillCount: Int
    let hasRoutes: Bool
    let isHovered: Bool
    let onToggle: () -> Void
    let onEnableAll: () -> Void
    let onDisableAll: () -> Void

    @Environment(\.theme) private var theme

    private var allEnabled: Bool { totalCount > 0 && enabledCount == totalCount }
    private var noneEnabled: Bool { enabledCount == 0 }
    private var partialEnabled: Bool { !allEnabled && !noneEnabled }

    /// Tri-state master glyph: filled when every child is on, dashed when some are
    /// on, empty when all are off. Tap toggles all-or-nothing (mixed -> all on).
    private var masterIcon: String {
        if allEnabled { return "checkmark.square.fill" }
        if partialEnabled { return "minus.square.fill" }
        return "square"
    }

    private var masterIconColor: Color {
        if noneEnabled { return theme.tertiaryText }
        return theme.accentColor
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
                .frame(width: 12)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))

            // Tri-state master toggle. Tap = enable-all when none/some are on,
            // disable-all when all are on. Larger hit target via padding so users
            // can hit it without precision.
            Button {
                if allEnabled {
                    onDisableAll()
                } else {
                    onEnableAll()
                }
            } label: {
                Image(systemName: masterIcon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(masterIconColor)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(allEnabled ? "Disable all" : "Enable all")

            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(isHovered ? theme.accentColor : theme.secondaryText)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if toolCount > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "wrench.and.screwdriver")
                                .font(.system(size: 8))
                            Text("\(toolCount)", bundle: .module)
                                .font(.system(size: 9, weight: .medium))
                        }
                        .foregroundColor(theme.tertiaryText)
                    }

                    if toolCount > 0 && (skillCount > 0 || hasRoutes) {
                        Text("+")
                            .font(.system(size: 8))
                            .foregroundColor(theme.tertiaryText)
                    }

                    if skillCount > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "lightbulb")
                                .font(.system(size: 8))
                            Text("\(skillCount)", bundle: .module)
                                .font(.system(size: 9, weight: .medium))
                        }
                        .foregroundColor(theme.tertiaryText)
                    }

                    if hasRoutes {
                        if skillCount > 0 || toolCount > 0 {
                            Text("+")
                                .font(.system(size: 8))
                                .foregroundColor(theme.tertiaryText)
                        }
                        HStack(spacing: 2) {
                            Image(systemName: "network")
                                .font(.system(size: 8))
                            Text("Routes", bundle: .module)
                                .font(.system(size: 9, weight: .medium))
                        }
                        .foregroundColor(theme.tertiaryText)
                    }
                }
            }

            Spacer()

            CountBadge(enabled: enabledCount, total: totalCount)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        // Tap on the row body (outside the master button) toggles expansion only;
        // the master button has its own hit area for select-all-or-none.
        .onTapGesture { onToggle() }
        .modifier(HoverRowStyle(isHovered: isHovered, showAccent: true))
    }
}

/// Tool row cell rendered in the NSTableView.
struct ToolRowCell: View {
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
                ? "Restricted for this agent."
                : ""
        )
    }
}

/// Skill row cell rendered in the NSTableView.
struct SkillRowCell: View {
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
                    Image(systemName: "lightbulb")
                        .font(.system(size: 9))
                        .foregroundColor(enabled ? theme.accentColor : theme.tertiaryText)

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
                .help(Text("~\(estimatedTokens) tokens", bundle: .module))
        }
        .padding(.leading, 32)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        .modifier(HoverRowStyle(isHovered: isHovered, showAccent: enabled))
    }
}

// MARK: - Shared Components (Internal to this file)

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

private struct TokenBadge: View {
    let count: Int

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            Text("~\(count)", bundle: .module).font(.system(size: 10, weight: .medium, design: .monospaced))
            Text("tokens", bundle: .module).font(.system(size: 9)).opacity(0.6)
        }
        .foregroundColor(theme.tertiaryText)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(theme.secondaryBackground.opacity(0.5)))
    }
}

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

private struct CountBadge: View {
    let enabled: Int
    let total: Int

    @Environment(\.theme) private var theme

    var body: some View {
        Text("\(enabled)/\(total)", bundle: .module)
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
