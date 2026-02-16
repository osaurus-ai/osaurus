//
//  ModelPickerTableRepresentable.swift
//  osaurus
//
//  NSViewRepresentable wrapping an NSTableView for the model picker
//  list. Provides true cell reuse and efficient diffing for large
//  model lists (e.g. OpenRouter with thousands of models).
//
//  Key design decisions:
//  - NSDiffableDataSource with row IDs for efficient structural updates.
//  - Manual row heights via `tableView(_:heightOfRow:)` to avoid the
//    expensive Auto Layout measurement that `usesAutomaticRowHeights`
//    forces through NSHostingView on every cell appearance.
//  - Two update paths: no-change early return, full snapshot.
//  - Single NSTrackingArea for hover instead of per-row SwiftUI trackers.
//  - Keyboard highlight scroll via `scrollRowToVisible`.
//

import AppKit
import SwiftUI

// MARK: - Supporting Types

/// Single-section identifier for the diffable data source.
enum ModelPickerSection: Hashable {
    case main
}

/// Flattened row model for the model picker.
enum ModelPickerRow: Equatable, Identifiable {
    case groupHeader(
        sourceKey: String,
        displayName: String,
        sourceType: ModelOption.Source,
        count: Int,
        isExpanded: Bool
    )
    case model(
        id: String,
        displayName: String,
        description: String?,
        parameterCount: String?,
        quantization: String?,
        isVLM: Bool,
        isSelected: Bool,
        isHighlighted: Bool
    )

    var id: String {
        switch self {
        case .groupHeader(let sourceKey, _, _, _, _): return "gh-\(sourceKey)"
        case .model(let id, _, _, _, _, _, _, _): return "model-\(id)"
        }
    }
}

/// Bundles all per-render context the coordinator needs to configure cells.
struct ModelPickerRenderingContext {
    let theme: ThemeProtocol
    let onToggleGroup: ((String) -> Void)?
    let onSelectModel: ((String) -> Void)?
}

// MARK: - ModelPickerTableRepresentable

struct ModelPickerTableRepresentable: NSViewRepresentable {

    let rows: [ModelPickerRow]
    let theme: ThemeProtocol

    /// The model ID to scroll to (for keyboard navigation).
    var scrollToModelId: String?

    var onToggleGroup: ((String) -> Void)?
    var onSelectModel: ((String) -> Void)?

    // MARK: - NSViewRepresentable Lifecycle

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let tableView = Self.makeTableView()
        let scrollView = Self.makeScrollView(documentView: tableView)

        coordinator.tableView = tableView
        coordinator.setupDataSource(for: tableView)
        coordinator.setupHoverTracking(on: tableView)

        coordinator.applyRows(rows, context: renderingContext)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.applyRows(rows, context: renderingContext)

        // Scroll to highlighted model for keyboard navigation
        if let modelId = scrollToModelId,
            scrollToModelId != coordinator.lastScrolledToModelId
        {
            coordinator.lastScrolledToModelId = modelId
            let targetId = "model-\(modelId)"
            if let rowIndex = coordinator.rowIds.firstIndex(of: targetId) {
                coordinator.tableView?.scrollRowToVisible(rowIndex)
            }
        }
    }

    // MARK: - View Factory Helpers

    private var renderingContext: ModelPickerRenderingContext {
        ModelPickerRenderingContext(
            theme: theme,
            onToggleGroup: onToggleGroup,
            onSelectModel: onSelectModel
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

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ModelPickerColumn"))
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

extension ModelPickerTableRepresentable {

    @MainActor
    final class Coordinator: NSObject, NSTableViewDelegate {

        // MARK: AppKit References

        weak var tableView: NSTableView?
        private(set) var dataSource: NSTableViewDiffableDataSource<ModelPickerSection, String>?

        // MARK: Row State

        private(set) var rowIds: [String] = []
        private(set) var rowLookup: [String: ModelPickerRow] = [:]

        // MARK: Rendering Context

        private var ctx = ModelPickerRenderingContext(
            theme: LightTheme(),
            onToggleGroup: nil,
            onSelectModel: nil
        )

        // MARK: Hover

        private var hoveredRowId: String?

        // MARK: Scroll

        var lastScrolledToModelId: String?

        // MARK: - Setup

        func setupDataSource(for tableView: NSTableView) {
            dataSource = NSTableViewDiffableDataSource<ModelPickerSection, String>(
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

        // MARK: - Apply Rows

        func applyRows(
            _ rows: [ModelPickerRow],
            context: ModelPickerRenderingContext
        ) {
            ctx = context

            let newIds = rows.map(\.id)
            let newLookup = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })

            // No-change early return
            if newIds == rowIds, !hasContentChanges(newLookup: newLookup) {
                return
            }

            // Content changed but IDs unchanged — update visible cells in place
            if newIds == rowIds {
                rowLookup = newLookup
                reconfigureVisibleCells()
                return
            }

            // Full snapshot
            applyFullSnapshot(newIds: newIds, newLookup: newLookup)
        }

        // MARK: - Update Paths (Private)

        private func hasContentChanges(newLookup: [String: ModelPickerRow]) -> Bool {
            for id in rowIds {
                if newLookup[id] != rowLookup[id] { return true }
            }
            return false
        }

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

        private func applyFullSnapshot(
            newIds: [String],
            newLookup: [String: ModelPickerRow]
        ) {
            rowLookup = newLookup
            rowIds = newIds

            var snapshot = NSDiffableDataSourceSnapshot<ModelPickerSection, String>()
            snapshot.appendSections([.main])
            snapshot.appendItems(newIds, toSection: .main)

            dataSource?.apply(snapshot, animatingDifferences: false)
        }

        // MARK: - Cell Factory

        private func dequeueAndConfigure(tableView: NSTableView, row: Int, rowId: String) -> NSView {
            let cell: TableHostingCellView
            if let reused = tableView.makeView(
                withIdentifier: TableHostingCellView.reuseIdentifier,
                owner: nil
            ) as? TableHostingCellView {
                cell = reused
            } else {
                cell = TableHostingCellView(frame: .zero)
                cell.identifier = TableHostingCellView.reuseIdentifier
            }

            if let rowData = rowLookup[rowId] {
                configureCell(cell, with: rowData)
            }
            return cell
        }

        private func configureCell(_ cell: TableHostingCellView, with row: ModelPickerRow) {
            let isHovered = hoveredRowId == row.id
            let theme = ctx.theme

            switch row {
            case .groupHeader(let sourceKey, let displayName, let sourceType, let count, let isExpanded):
                cell.configure(id: row.id, content:
                    ModelGroupHeaderCell(
                        displayName: displayName,
                        sourceType: sourceType,
                        count: count,
                        isExpanded: isExpanded,
                        isHovered: isHovered,
                        onToggle: { [weak self] in self?.ctx.onToggleGroup?(sourceKey) }
                    )
                    .environment(\.theme, theme)
                )

            case .model(let id, let displayName, let description, let parameterCount, let quantization, let isVLM, let isSelected, let isHighlighted):
                cell.configure(id: row.id, content:
                    ModelRowCell(
                        displayName: displayName,
                        description: description,
                        parameterCount: parameterCount,
                        quantization: quantization,
                        isVLM: isVLM,
                        isSelected: isSelected,
                        isHighlighted: isHighlighted,
                        isHovered: isHovered,
                        onSelect: { [weak self] in self?.ctx.onSelectModel?(id) }
                    )
                    .environment(\.theme, theme)
                )
            }
        }

        // MARK: - Hover Tracking

        private func handleMouseMoved(with event: NSEvent) {
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
        private static func estimatedHeight(for row: ModelPickerRow) -> CGFloat {
            switch row {
            case .groupHeader:
                // 12pt padding top + ~16pt content + 12pt padding bottom
                return 44

            case .model(_, _, let description, let parameterCount, let quantization, _, _, _):
                // 10pt padding top/bottom + ~16pt display name line
                var height: CGFloat = 36
                if let description, !description.isEmpty {
                    // +3pt spacing + ~14pt description text
                    height += 17
                }
                if parameterCount != nil || quantization != nil {
                    // +3pt spacing + ~14pt metadata badges
                    height += 17
                }
                return height
            }
        }
    }
}

// MARK: - Cell SwiftUI Views

/// Group header cell for the model picker.
private struct ModelGroupHeaderCell: View {
    let displayName: String
    let sourceType: ModelOption.Source
    let count: Int
    let isExpanded: Bool
    let isHovered: Bool
    let onToggle: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
                .frame(width: 12)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))

            sourceIcon
                .font(.system(size: 11))
                .foregroundColor(isHovered ? theme.accentColor : theme.secondaryText)

            Text(displayName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)

            Spacer()

            Text("\(count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.tertiaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(theme.secondaryBackground)
                        .overlay(Capsule().strokeBorder(theme.primaryBorder.opacity(0.1), lineWidth: 1))
                )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        .modifier(ModelHoverRowStyle(isHovered: isHovered, showAccent: true))
    }

    @ViewBuilder
    private var sourceIcon: some View {
        switch sourceType {
        case .foundation: Image(systemName: "apple.logo")
        case .local: Image(systemName: "internaldrive")
        case .remote: Image(systemName: "cloud")
        }
    }
}

/// Model row cell for the model picker.
private struct ModelRowCell: View {
    let displayName: String
    let description: String?
    let parameterCount: String?
    let quantization: String?
    let isVLM: Bool
    let isSelected: Bool
    let isHighlighted: Bool
    let isHovered: Bool
    let onSelect: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(displayName)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .foregroundColor(isSelected ? theme.primaryText : theme.secondaryText)
                        .lineLimit(1)

                    if isVLM {
                        ModelSmallBadge(text: "Vision", icon: "eye")
                    }
                }

                if let description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(2)
                }

                if parameterCount != nil || quantization != nil {
                    HStack(spacing: 4) {
                        if let params = parameterCount {
                            ModelMetadataBadge(text: params, style: .accent)
                        }
                        if let quant = quantization {
                            ModelMetadataBadge(text: quant, style: .subtle)
                        }
                    }
                }
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.accentColor)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .modifier(ModelHoverRowStyle(isHovered: isHovered || isHighlighted || isSelected, showAccent: isSelected))
    }
}

// MARK: - Shared Components

/// Hover background + border for model picker rows.
private struct ModelHoverRowStyle: ViewModifier {
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
                                    showAccent ? theme.accentColor.opacity(0.2) : theme.glassEdgeLight.opacity(0.12),
                                    showAccent ? theme.accentColor.opacity(0.08) : theme.primaryBorder.opacity(0.08),
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

/// Theme-aware metadata badge for parameter count and quantization.
private struct ModelMetadataBadge: View {
    enum Style {
        case accent, subtle
    }

    let text: String
    let style: Style

    @Environment(\.theme) private var theme

    private var badgeColor: Color {
        switch style {
        case .accent: return theme.accentColor
        case .subtle: return theme.secondaryText
        }
    }

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(badgeColor.opacity(0.9))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(badgeColor.opacity(0.12))
            )
    }
}

/// Small capsule badge with optional icon (e.g. "Vision" with eye icon).
private struct ModelSmallBadge: View {
    let text: String
    var icon: String? = nil

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 8))
            }
            Text(text)
                .font(.system(size: 8, weight: .medium))
        }
        .foregroundColor(theme.accentColor)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(theme.accentColor.opacity(0.12))
                .overlay(Capsule().strokeBorder(theme.accentColor.opacity(0.15), lineWidth: 1))
        )
    }
}
