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
        estimatedTokens: Int
    )

    var id: String {
        switch self {
        case .groupHeader(let id, _, _, _, _, _, _): return "gh-\(id)"
        case .tool(let id, _, _, _, _, _, _, _): return "tool-\(id)"
        }
    }
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
                    let estimatedTokens
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
            if let theme = ctx?.theme {
                let padding = theme.catalogMetric("padding", fallback: theme.space.s10)
                let label = theme.assignedLineHeight("component.library.48.label", fallback: 18)
                let text = theme.assignedLineHeight("component.library.48.text", fallback: 16)
                let gap = theme.catalogMetric("gap", fallback: theme.space.s2)
                let content: CGFloat
                switch rowData {
                case .groupHeader: content = max(label, 26)
                case .tool: content = max(label + gap + text * 2, theme.assignedMetric("component.library.48.switchHeight", fallback: 24))
                }
                let outlineSpace: CGFloat
                if case .groupHeader = rowData { outlineSpace = capabilityHeaderFocusSpace(theme) } else { outlineSpace = 0 }
                return max(theme.catalogMetric("height", fallback: 44), content + padding * 2) + outlineSpace * 2
            }
            return Self.estimatedHeight(for: rowData)
        }

        // MARK: - Row Height Estimation

        private static func estimatedHeight(for row: CapabilityRow) -> CGFloat {
            switch row {
            case .groupHeader: return 44
            // name row (~15) + spacing + 2-line description (~24) + 20pt
            // vertical padding. The former third line (availability detail)
            // moved into the tooltip.
            case .tool: return 62
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

/// Group header cell: chevron + icon tile + name, with the assignment
/// cluster (count badge + tri-state master checkbox) on the trailing edge.
struct GroupHeaderCell: View {
    let name: String
    let icon: String
    let enabledCount: Int
    let totalCount: Int
    let isExpanded: Bool
    var status: CapabilityGroupStatus?
    let isHovered: Bool
    let onToggle: () -> Void
    let onEnableAll: () -> Void
    let onDisableAll: () -> Void
    var onStatusTap: () -> Void = {}
    var groupFocusRequest = 0
    var masterFocusRequest = 0
    var onKeyboardFocusRequest: (Bool) -> Void = { _ in }
    var onKeyboardFocusRestored: () -> Void = {}

    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(48, enabled: inspectionEnabled) }
    @Environment(\.isEnabled) private var componentEnabled

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
        if !componentEnabled { return theme.text.disabled }
        if noneEnabled { return theme.text.tertiary }
        return theme.action.primary.default.background
    }

    var body: some View {
        Group {

        HStack(spacing: theme.catalogLayoutMetric("component.library.48.elements.layout.groupHeaderCell.body.horizontalGap", inheriting: theme.catalogMetric("gap", fallback: theme.space.s10))) {
            Image(systemName: "chevron.right")
                .glyphSize(.micro, weight: .semibold)
                .foregroundColor(theme.text.tertiary)
                .frame(width: 12)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))

            // Rounded-square icon tile — same tile language as the Tools
            // manager's plugin cards and the Abilities overview cards.
            Image(systemName: icon)
                .glyphSize(.footnote, weight: .semibold)
                .foregroundColor(isHovered || enabledCount > 0 ? theme.text.link : theme.text.secondary)
                .frame(width: 26, height: 26)
                .settingsChrome(enabledCount > 0 ? .selected : .inset)

            Text(name)
                .assignedTypography("component.library.48.label", fallback: SettingsFont.compactLabel)
                .foregroundColor(theme.text.primary)
                .lineLimit(1)

            Spacer()

            if let status {
                GroupStatusBadge(status: status, onTap: onStatusTap)
            }

            // Assignment cluster: the badge says how many are on, the
            // checkbox right next to it acts on exactly that set — trailing
            // placement keeps the two visually paired.
            CapabilityCountBadge(enabled: enabledCount, total: totalCount)

            // Tri-state master toggle. Tap = enable-all when none/some are on,
            // disable-all when all are on. Acts on the FULL group (registry),
            // matching the badge, even while search or filters hide rows.
            Button {
                if allEnabled {
                    onDisableAll()
                } else {
                    onEnableAll()
                }
            } label: {
                Image(systemName: masterIcon)
                    .glyphSize(points: NativeComponentInspectionStyle.metric(48, "indicatorSize", 22, theme) * 14 / 22, weight: .medium)
                    .foregroundColor(masterIconColor)
                    .frame(width: NativeComponentInspectionStyle.metric(48, "indicatorSize", 22, theme), height: NativeComponentInspectionStyle.metric(48, "indicatorSize", 22, theme))
                    .contentShape(Rectangle())
            }
            .assignedBasePlainButtonStyle()
            .assignedBaseKeyboardButton(48, focusRequest: masterFocusRequest,
                onFocusRequestHandled: onKeyboardFocusRestored) {
                onKeyboardFocusRequest(true)
                if allEnabled { onDisableAll() } else { onEnableAll() }
            }
            .help(allEnabled ? Text(localized: "Disable all") : Text(localized: "Enable all"))
            .accessibilityLabel(
                allEnabled
                    ? Text(localized: "Disable all") : Text(localized: "Enable all")
            )
            .accessibilityAddTraits(allEnabled ? [.isSelected] : [])
        }.catalogLayoutTarget("component.library.48.elements.layout.groupHeaderCell.body.horizontalGap")
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.48.elements.layout.groupHeaderCell.body.paddingX", inheriting: theme.catalogMetric("padding", fallback: theme.space.s12))).catalogLayoutTarget("component.library.48.elements.layout.groupHeaderCell.body.paddingX")
        .padding(.vertical, theme.catalogLayoutMetric("component.library.48.elements.layout.groupHeaderCell.body.paddingY", inheriting: theme.catalogMetric("padding", fallback: theme.space.s8))).catalogLayoutTarget("component.library.48.elements.layout.groupHeaderCell.body.paddingY")
        .contentShape(Rectangle())
        // Tap on the row body (outside the master button) toggles expansion only;
        // the master button has its own hit area for select-all-or-none.
        .onTapGesture { onToggle() }
        .assignedBaseKeyboardButton(48, focusRequest: groupFocusRequest,
            onFocusRequestHandled: onKeyboardFocusRestored) {
                onKeyboardFocusRequest(false); onToggle()
            }
        .modifier(HoverRowStyle(isHovered: isHovered, showAccent: true))
        // Outer gutter: insets the hover wash from the table edges so the
        // row content aligns with the header's 24pt gutter.
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.48.elements.layout.groupHeaderCell.body.paddingX2", inheriting: theme.catalogMetric("padding", fallback: theme.space.s12))).catalogLayoutTarget("component.library.48.elements.layout.groupHeaderCell.body.paddingX2")
        .padding(.vertical, capabilityHeaderFocusSpace(theme))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isExpanded ? Text("Expanded", bundle: .module) : Text("Collapsed", bundle: .module))
        .accessibilityAction(.default) { if componentEnabled { onToggle() } }
    
        }.environment(\.theme, theme)
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

/// Tool row cell rendered in the NSTableView.
struct ToolRowCell: View {
    let name: String
    let description: String
    let enabled: Bool
    let availability: ToolAvailability
    let groupToggleLabel: String?
    let catalogTokens: Int
    let estimatedTokens: Int
    let isHovered: Bool
    let onToggle: () -> Void

    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(48, enabled: inspectionEnabled) }

    private var nameColor: Color {
        enabled ? theme.text.primary : theme.text.secondary
    }

    var body: some View {
        Group {

        HStack(spacing: theme.catalogLayoutMetric("component.library.48.elements.layout.toolRowCell.body.horizontalGap", inheriting: theme.catalogMetric("gap", fallback: theme.space.s12))) {
            CapabilitySwitch(
                isOn: enabled,
                tint: theme.action.primary.default.background,
                onToggle: onToggle
            )

            VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.48.elements.layout.toolRowCell.body.verticalGap", inheriting: theme.catalogMetric("gap", fallback: theme.space.s2))) {
                HStack(spacing: theme.catalogLayoutMetric("component.library.48.elements.layout.toolRowCell.body.horizontalGap2", inheriting: NativeComponentInspectionStyle.metric(48, "gap", theme.space.s6, theme))) {
                    Text(name)
                        .assignedTypography("component.library.48.label", fallback: SettingsFont.compactLabel)
                        .foregroundColor(nameColor)
                        .lineLimit(1)

                    if let groupToggleLabel {
                        SmallCapsuleBadge(text: groupToggleLabel, icon: "square.stack")
                    }

                    ToolAvailabilityBadge(availability: availability)
                }.catalogLayoutTarget("component.library.48.elements.layout.toolRowCell.body.horizontalGap2")
                Text(description)
                    .assignedTypography("component.library.48.text", fallback: SettingsFont.footnote)
                    .foregroundColor(theme.text.tertiary)
                    .lineLimit(2)
            }.catalogLayoutTarget("component.library.48.elements.layout.toolRowCell.body.verticalGap")

            Spacer()

            TokenBadge(count: catalogTokens)
                .help(
                    catalogTokens == estimatedTokens
                        ? "~\(estimatedTokens) tokens"
                        : "Catalog: ~\(catalogTokens), Full: ~\(estimatedTokens) tokens"
                )
        }.catalogLayoutTarget("component.library.48.elements.layout.toolRowCell.body.horizontalGap")
        .padding(.leading, theme.catalogLayoutMetric("component.library.48.elements.layout.toolRowCell.body.paddingX", inheriting: theme.catalogMetric("padding", fallback: theme.space.s32))).catalogLayoutTarget("component.library.48.elements.layout.toolRowCell.body.paddingX")
        .padding(.trailing, theme.catalogLayoutMetric("component.library.48.elements.layout.toolRowCell.body.paddingX2", inheriting: theme.catalogMetric("padding", fallback: theme.space.s12))).catalogLayoutTarget("component.library.48.elements.layout.toolRowCell.body.paddingX2")
        .padding(.vertical, theme.catalogLayoutMetric("component.library.48.elements.layout.toolRowCell.body.paddingY", inheriting: theme.catalogMetric("padding", fallback: theme.space.s10))).catalogLayoutTarget("component.library.48.elements.layout.toolRowCell.body.paddingY")
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        .modifier(HoverRowStyle(isHovered: isHovered, showAccent: enabled))
        // Outer gutter: matches the group header inset so hover washes and
        // content share one gutter with the sticky header above.
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.48.elements.layout.toolRowCell.body.paddingX3", inheriting: theme.catalogMetric("padding", fallback: theme.space.s12))).catalogLayoutTarget("component.library.48.elements.layout.toolRowCell.body.paddingX3")
        // The availability detail used to be a third text line on every row;
        // it's tooltip-only now, keeping the row to name + description.
        .help(
            groupToggleLabel != nil
                ? "\(availability.displayDetail) These tools turn on and off together with their app."
                : availability.displayDetail
        )
    
        }.environment(\.theme, theme)
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

// MARK: - Shared Components (Internal to this file)

private struct HoverRowStyle: ViewModifier {
    let isHovered: Bool
    let showAccent: Bool

    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(48, enabled: inspectionEnabled) }

    @ViewBuilder func body(content: Content) -> some View {
        content.assignedBaseChrome(48)
    }
}

private struct TokenBadge: View {
    let count: Int

    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(48, enabled: inspectionEnabled) }

    var body: some View {
        Group {

        StatusChip("~\(count) \(L("tokens"))")
    
        }.environment(\.theme, theme)
}
}

private struct SmallCapsuleBadge: View {
    let text: String
    var icon: String? = nil

    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(48, enabled: inspectionEnabled) }

    var body: some View {
        Group {

        StatusChip(text, icon: icon)
    
        }.environment(\.theme, theme)
}
}

private struct CapabilityCountBadge: View {
    let enabled: Int
    let total: Int

    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(48, enabled: inspectionEnabled) }

    var body: some View {
        Group {

        StatusChip("\(enabled)/\(total)", tone: enabled > 0 ? .accent : .neutral)
    
        }.environment(\.theme, theme)
}
}

/// Space outside the styled header for an assigned outline; the component's
/// visual height/padding stay unchanged and focus never changes row geometry.
private func capabilityHeaderFocusSpace(_ theme: any ThemeProtocol) -> CGFloat {
    max(0, theme.assignedMetric("component.focus.offset", fallback: theme.focusOffset))
        + max(0, theme.assignedMetric("component.focus.width", fallback: theme.stroke.focus)) / 2
}
