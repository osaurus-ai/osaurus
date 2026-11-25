//
//  CapabilitiesTableRepresentable.swift
//  osaurus
//
//  NSViewRepresentable wrapping an NSTableView for the agent tool
//  selector item list. Provides true cell reuse and efficient diffing
//  for large tool lists.
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

/// Trailing status badge on a group header (e.g. "Permission needed" on an
/// Apple app whose macOS grant is missing). Tapping it fires
/// `onGroupStatusTap(groupId)` when `isActionable`.
struct CapabilityGroupStatus: Equatable {
    let text: String
    let icon: String
    let isWarning: Bool
    let isActionable: Bool
    /// Tooltip / accessibility hint.
    let detail: String
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
        status: CapabilityGroupStatus?
    )
    case tool(
        id: String,
        name: String,
        description: String,
        enabled: Bool,
        availability: ToolAvailability,
        /// Non-nil when the row's switch acts on its whole group (built-in
        /// Apple apps turn on and off per app). Rendered as a small badge
        /// with this label; the toggle callback still fires per row and the
        /// host maps it onto the group.
        groupToggleLabel: String?,
        catalogTokens: Int,
        estimatedTokens: Int,
        /// The agent's policy menu; nil hides it (tool off, draft agent, or
        /// built-in agent).
        policy: CapabilityToolPolicy? = nil
    )

    var id: String {
        switch self {
        case .groupHeader(let id, _, _, _, _, _, _): return "gh-\(id)"
        case .tool(let id, _, _, _, _, _, _, _, _): return "tool-\(id)"
        }
    }
}

/// A custom agent's own policy for one enabled tool, as the row shows it.
/// Carried by value so a policy change re-renders the row.
struct CapabilityToolPolicy: Equatable {
    let agentId: UUID
    /// The agent's override; nil is Default.
    let override: ToolPermissionPolicy?
    let effective: ToolPermissionPolicy
}

/// Bundles all per-render context the coordinator needs to configure cells.
struct CapabilityRenderingContext {
    let theme: ThemeProtocol
    let isEnabled: Bool

    let onToggleGroup: ((String) -> Void)?
    let onEnableAllInGroup: ((String) -> Void)?
    let onDisableAllInGroup: ((String) -> Void)?
    let onGroupStatusTap: ((String) -> Void)?

    let onToggleTool: ((String, Bool) -> Void)?
}

// MARK: - CapabilitiesTableRepresentable

struct CapabilitiesTableRepresentable: NSViewRepresentable {

    @Environment(\.isEnabled) private var isEnabled
    let rows: [CapabilityRow]
    let theme: ThemeProtocol

    var onToggleGroup: ((String) -> Void)?
    var onEnableAllInGroup: ((String) -> Void)?
    var onDisableAllInGroup: ((String) -> Void)?
    var onGroupStatusTap: ((String) -> Void)?

    var onToggleTool: ((String, Bool) -> Void)?

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
            theme: theme.catalogFamily(48, enabled: isEnabled),
            isEnabled: isEnabled,
            onToggleGroup: onToggleGroup,
            onEnableAllInGroup: onEnableAllInGroup,
            onDisableAllInGroup: onDisableAllInGroup,
            onGroupStatusTap: onGroupStatusTap,
            onToggleTool: onToggleTool
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
        sv.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
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
            let appearanceChanged = ctx?.theme.inspectionRevision != context.theme.inspectionRevision
                || ctx?.theme.renderFingerprint != context.theme.renderFingerprint
                || ctx?.isEnabled != context.isEnabled
            ctx = context

            let newIds = rows.map(\.id)
            let newLookup = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })

            if newIds == rowIds, !appearanceChanged, !hasContentChanges(newLookup: newLookup) {
                return
            }

            if newIds == rowIds {
                rowLookup = newLookup
                if appearanceChanged, let tableView {
                    tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rowIds.count))
                }
                if appearanceChanged {
                    // The table may be outside a parent ScrollView's viewport.
                    // Its retained hosting cells still need the new theme and
                    // enabled environment, even when visibleRect is empty.
                    for row in rowIds.indices { reconfigureCell(at: row) }
                } else {
                    reconfigureVisibleCells()
                }
                return
            }

            applyFullSnapshot(newIds: newIds, newLookup: newLookup)
        }

        // MARK: - Update Paths (Private)

        private func hasContentChanges(newLookup: [String: CapabilityRow]) -> Bool {
            for id in rowIds where newLookup[id] != rowLookup[id] {
                return true
            }
            return false
        }

        /// Bounded retry for reconfigures that land before the table's first
        /// in-window layout. The Capabilities tab hydrates its enabled-state
        /// sets synchronously in `onAppear`, which fires before AppKit lays
        /// the table out — at that instant `visibleRowIndices()` is empty, so
        /// without a retry the correction is silently dropped and cells keep
        /// their stale all-off payload until scrolling re-dequeues them.
        private var pendingReconfigureRetries = 0

        private func reconfigureVisibleCells() {
            let visible = visibleRowIndices()
            guard !visible.isEmpty else {
                if pendingReconfigureRetries < 5 {
                    pendingReconfigureRetries += 1
                    DispatchQueue.main.async { [weak self] in
                        self?.reconfigureVisibleCells()
                    }
                }
                return
            }
            pendingReconfigureRetries = 0
            for row in visible {
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
                allowAssignedFocusOverflow(cell)

            case .tool:
                guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ToolCell,
                    let content = makeToolContent(rowData, isHovered: isHovered)
                else { return }
                cell.configure(id: rowData.id, content: content)
                allowAssignedFocusOverflow(cell)
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

        private var focusRequests: [String: (epoch: Int, master: Bool)] = [:]
        private var focusEpoch = 0
        private func requestKeyboardFocus(_ id: String, master: Bool) {
            focusEpoch += 1
            focusRequests[id] = (focusEpoch, master)
        }
        private func allowAssignedFocusOverflow(_ cell: NSView) {
            cell.clipsToBounds = false
            for view in cell.subviews { view.clipsToBounds = false }
        }

        // MARK: - Reuse Identifiers

        private static let headerReuseId = NSUserInterfaceItemIdentifier("CapabilityGroupHeaderCell")
        private static let toolReuseId = NSUserInterfaceItemIdentifier("CapabilityToolRowCell")

        private typealias HeaderCell = TypedHostingCellView<ThemedContent<GroupHeaderCell>>
        private typealias ToolCell = TypedHostingCellView<ThemedContent<ToolRowCell>>

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
                    let status
                ) = row, let theme = ctx?.theme
            else { return nil }
            return ThemedContent(
                theme: theme,
                isEnabled: ctx?.isEnabled ?? true,
                content: GroupHeaderCell(
                    name: name,
                    icon: icon,
                    enabledCount: enabledCount,
                    totalCount: totalCount,
                    isExpanded: isExpanded,
                    status: status,
                    isHovered: isHovered,
                    showsDivider: rowIds.first != row.id,
                    onToggle: { [weak self] in self?.ctx?.onToggleGroup?(id) },
                    onEnableAll: { [weak self] in self?.ctx?.onEnableAllInGroup?(id) },
                    onDisableAll: { [weak self] in self?.ctx?.onDisableAllInGroup?(id) },
                    onStatusTap: { [weak self] in self?.ctx?.onGroupStatusTap?(id) },
                    groupFocusRequest: focusRequests[id]?.master == false ? (focusRequests[id]?.epoch ?? 0) : 0,
                    masterFocusRequest: focusRequests[id]?.master == true ? (focusRequests[id]?.epoch ?? 0) : 0,
                    onKeyboardFocusRequest: { [weak self] master in self?.requestKeyboardFocus(id, master: master) },
                    onKeyboardFocusRestored: { [weak self] in self?.focusRequests.removeValue(forKey: id) }
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
                    let availability,
                    let groupToggleLabel,
                    let catalogTokens,
                    let estimatedTokens,
                    let policy
                ) = row, let theme = ctx?.theme
            else { return nil }
            return ThemedContent(
                theme: theme,
                isEnabled: ctx?.isEnabled ?? true,
                content: ToolRowCell(
                    name: name,
                    description: description,
                    enabled: enabled,
                    availability: availability,
                    groupToggleLabel: groupToggleLabel,
                    catalogTokens: catalogTokens,
                    estimatedTokens: estimatedTokens,
                    policy: policy,
                    isHovered: isHovered,
                    onToggle: { [weak self] in self?.ctx?.onToggleTool?(id, enabled) }
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
                allowAssignedFocusOverflow(cell)
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
                allowAssignedFocusOverflow(cell)
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
            guard let theme = ctx?.theme else { return Self.estimatedHeight(for: rowData) }
            switch rowData {
            case .groupHeader:
                return max(theme.settingsRowMinHeight, CapabilityRowMetrics.tileSize + theme.space.s12 * 2)
            case .tool:
                let label = theme.assignedLineHeight("component.library.48.label", fallback: 18)
                let text = theme.assignedLineHeight("component.library.48.text", fallback: 16)
                return label + theme.space.s2 + text * 2 + theme.space.s10 * 2
            }
        }

        // MARK: - Row Height Estimation

        private static func estimatedHeight(for row: CapabilityRow) -> CGFloat {
            switch row {
            case .groupHeader: return 50
            // name row + spacing + 2-line description + vertical padding.
            case .tool: return 72
            }
        }
    }
}

// MARK: - Themed Wrapper

/// Wraps a SwiftUI view with a theme environment value, giving a concrete
/// nameable type for use with TypedHostingCellView generic parameter.
struct ThemedContent<C: View>: View {
    let theme: ThemeProtocol
    var isEnabled = true
    let content: C

    var body: some View {
        Group {

        content.environment(\.theme, theme).disabled(!isEnabled)
    
        }.environment(\.theme, theme)
}
}

// MARK: - Cell SwiftUI Views

/// Group header row: disclosure chevron, icon tile and name, then the
/// group's status, "Turn All On / Off" (while hovered or open) and the
/// assigned count on the trailing edge. Flat, like a `SettingsGroup` row;
/// the table's host draws the card.
struct GroupHeaderCell: View {
    let name: String
    let icon: String
    let enabledCount: Int
    let totalCount: Int
    let isExpanded: Bool
    var status: CapabilityGroupStatus?
    let isHovered: Bool
    var showsDivider = false
    let onToggle: () -> Void
    let onEnableAll: () -> Void
    let onDisableAll: () -> Void
    var onStatusTap: () -> Void = {}
    var groupFocusRequest = 0
    var masterFocusRequest = 0
    var onKeyboardFocusRequest: (Bool) -> Void = { _ in }
    var onKeyboardFocusRestored: () -> Void = {}

    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var componentEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(48, enabled: componentEnabled) }

    private var allEnabled: Bool { totalCount > 0 && enabledCount == totalCount }
    private var showsBulkAction: Bool { isHovered || isExpanded }

    var body: some View {
        HStack(spacing: theme.space.s10) {
            Image(systemName: "chevron.right")
                .glyphSize(.micro, weight: .semibold)
                .foregroundColor(theme.text.tertiary)
                .frame(width: CapabilityRowMetrics.disclosureWidth)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))

            SettingsIconTile(
                icon: icon,
                size: CapabilityRowMetrics.tileSize,
                tint: enabledCount > 0 ? nil : theme.text.tertiary
            )

            Text(name)
                .font(SettingsFont.rowTitle)
                .foregroundColor(theme.text.primary)
                .lineLimit(1)

            Spacer(minLength: theme.space.s8)

            if let status {
                GroupStatusBadge(status: status, onTap: onStatusTap)
            }

            // All-or-nothing for the FULL group (registry), matching the
            // count, even while search or filters hide rows. Some on counts
            // as off, so the first click turns the rest on.
            Button {
                if allEnabled { onDisableAll() } else { onEnableAll() }
            } label: {
                Text(allEnabled ? L("Turn All Off") : L("Turn All On"))
            }
            .assignedSettingsButtonStyle(.tertiary, size: .compact)
            .assignedBaseKeyboardButton(48, focusRequest: masterFocusRequest,
                onFocusRequestHandled: onKeyboardFocusRestored) {
                onKeyboardFocusRequest(true)
                if allEnabled { onDisableAll() } else { onEnableAll() }
            }
            .help(
                allEnabled
                    ? Text(localized: "Turn off every tool in this group")
                    : Text(localized: "Turn on every tool in this group")
            )
            .opacity(showsBulkAction ? 1 : 0)
            .allowsHitTesting(showsBulkAction)

            Text(L("\(enabledCount) of \(totalCount)"))
                .font(SettingsFont.rowDescription)
                .monospacedDigit()
                .foregroundColor(enabledCount > 0 ? theme.text.secondary : theme.text.tertiary)
                .fixedSize()
        }
        .padding(.horizontal, theme.space.s16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // Tap on the row body (outside the button) toggles expansion only.
        .onTapGesture { onToggle() }
        .assignedBaseKeyboardButton(48, focusRequest: groupFocusRequest,
            onFocusRequestHandled: onKeyboardFocusRestored) {
                onKeyboardFocusRequest(false); onToggle()
            }
        .background(isHovered ? theme.surface.hover : Color.clear)
        .overlay(alignment: .top) {
            if showsDivider { SettingsGroupDivider() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isExpanded ? Text("Expanded", bundle: .module) : Text("Collapsed", bundle: .module))
        .accessibilityAction(.default) { if componentEnabled { onToggle() } }
        .environment(\.theme, theme)
    }
}

/// Shared geometry: tool rows start under their group's name.
enum CapabilityRowMetrics {
    static let disclosureWidth: CGFloat = 12
    static let tileSize: CGFloat = 26

    static func toolIndent(_ theme: any ThemeProtocol) -> CGFloat {
        theme.space.s16 + disclosureWidth + tileSize + theme.space.s10 * 2
    }
}

/// Pure-SwiftUI switch for rows hosted inside the capabilities NSTableView.
/// The stock `SwitchToggleStyle` is backed by an AppKit `NSSwitch`, which
/// renders as a knobless solid capsule whenever its hosting view is created
/// before the table's first layout or re-attached by a row diff (group
/// expand/collapse), and only heals when different content is dequeued into
/// the cell. Drawing the switch with shapes sidesteps the AppKit control
/// entirely, so it renders correctly at any point in the cell lifecycle.
struct CapabilitySwitch: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(48, enabled: inspectionEnabled) }
    let isOn: Bool
    let tint: Color
    var disabled: Bool = false
    let onToggle: () -> Void

    @ViewBuilder var body: some View {
        Group {

        Toggle("Enable tool", isOn: Binding(get: { isOn }, set: { _ in onToggle() }))
            .settingsSwitch().disabled(disabled)
    
        }.environment(\.theme, theme)
}
}

/// Tool row: name, badges and description under the group's name, then
/// the policy menu, token estimate and switch on the trailing edge, like
/// every other settings row.
struct ToolRowCell: View {
    let name: String
    let description: String
    let enabled: Bool
    let availability: ToolAvailability
    let groupToggleLabel: String?
    let catalogTokens: Int
    let estimatedTokens: Int
    var policy: CapabilityToolPolicy? = nil
    let isHovered: Bool
    let onToggle: () -> Void

    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(48, enabled: inspectionEnabled) }

    var body: some View {
        HStack(spacing: theme.space.s12) {
            VStack(alignment: .leading, spacing: theme.space.s2) {
                HStack(spacing: theme.space.s6) {
                    Text(name)
                        .font(SettingsFont.compactLabel)
                        .foregroundColor(enabled ? theme.text.primary : theme.text.secondary)
                        .lineLimit(1)
                    if let groupToggleLabel {
                        StatusChip(groupToggleLabel)
                    }
                    ToolAvailabilityBadge(availability: availability)
                }
                Text(description)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
                    .lineLimit(2)
            }

            Spacer(minLength: theme.space.s8)

            if let policy, let info = ToolRegistry.shared.policyInfo(for: name, agentId: policy.agentId) {
                ToolPolicyMenu(toolName: name, info: info, scope: .agent(policy.agentId), onChange: {})
            }

            Text("~\(catalogTokens) \(L("tokens"))")
                .font(SettingsFont.monoSmall)
                .foregroundColor(theme.text.tertiary)
                .fixedSize()
                .help(
                    catalogTokens == estimatedTokens
                        ? "~\(estimatedTokens) tokens"
                        : "Catalog: ~\(catalogTokens), Full: ~\(estimatedTokens) tokens"
                )

            CapabilitySwitch(
                isOn: enabled,
                tint: theme.action.primary.default.background,
                onToggle: onToggle
            )
        }
        .padding(.leading, CapabilityRowMetrics.toolIndent(theme))
        .padding(.trailing, theme.space.s16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        .background(isHovered ? theme.surface.hover : Color.clear)
        .overlay(alignment: .top) {
            SettingsGroupDivider()
                .padding(.leading, CapabilityRowMetrics.toolIndent(theme) - theme.space.s16)
        }
        // The availability detail is tooltip-only, keeping the row to name
        // + description.
        .help(
            groupToggleLabel != nil
                ? "\(availability.displayDetail) These tools turn on and off together with their app."
                : availability.displayDetail
        )
        .environment(\.theme, theme)
    }
}

/// Trailing status capsule on a group header ("Permission needed"). Acts as
/// a button when the status is actionable so the fix is one click away.
private struct GroupStatusBadge: View {
    let status: CapabilityGroupStatus
    let onTap: () -> Void

    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(48, enabled: inspectionEnabled) }

    var body: some View {
        Group {

        Button(action: { if status.isActionable { onTap() } }) {
            StatusChip(status.text, tone: status.isWarning ? .warning : .neutral, icon: status.icon)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!status.isActionable)
        .help(status.detail)
        .accessibilityLabel(Text(status.text))
        .accessibilityHint(Text(status.detail))
    
        }.environment(\.theme, theme)
}
}
