//
//  AgentDataGridView.swift
//  osaurus
//
//  NSViewRepresentable wrapping an NSTableView for the Database
//  workspace's row browser and saved-view previews. Replaces the old
//  eager `ScrollView + VStack + ForEach` grid, which built every loaded
//  row's view tree up front and froze the UI on large tables.
//
//  Key design decisions (mirrors `ModelPickerTableRepresentable`):
//  - True cell reuse via `makeView(withIdentifier:)` with pure AppKit
//    labels (no NSHostingView) for smooth scrolling.
//  - Fixed 28px row height; native resizable column headers.
//  - Append-aware updates: incremental page loads insert rows instead
//    of reloading the whole table, preserving scroll position.
//  - Near-bottom scroll observation drives incremental page fetches.
//  - Selection checkboxes for bulk actions, double-click / Return to
//    open a row, and a trailing per-row open button so the affordance
//    stays discoverable without knowing the gesture.
//

import AppKit
import SwiftUI

// MARK: - Row / Column models

struct DataGridColumn: Equatable {
    let title: String
    let width: CGFloat

    /// Default width heuristics shared by the browser and previews.
    static func preferredWidth(forColumnNamed name: String) -> CGFloat {
        switch name {
        case "id": return 260
        case "_created_at", "_updated_at", "_deleted_at": return 170
        default: return 160
        }
    }
}

struct DataGridRowData: Equatable {
    /// Stable identity for selection bookkeeping. Rows without an
    /// addressable id get an index-derived key and are not selectable.
    let key: String
    let cells: [String]
    let isDeleted: Bool
    let selectable: Bool
}

// MARK: - Representable

struct AgentDataGridRepresentable: NSViewRepresentable {
    @Environment(\.isEnabled) private var inspectionEnabled
    let columns: [DataGridColumn]
    let rows: [DataGridRowData]
    let showsSelectionColumn: Bool
    let showsStatusColumn: Bool
    let showsOpenColumn: Bool
    @Binding var selectedRowKeys: Set<String>
    let theme: ThemeProtocol
    var onRowOpen: ((Int) -> Void)? = nil
    var onNeedsMoreRows: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let tableView = DataGridTableView()
        tableView.style = .plain
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = 28
        tableView.usesAutomaticRowHeights = false
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.allowsColumnReordering = false
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        tableView.target = coordinator
        tableView.doubleAction = #selector(Coordinator.didDoubleClickRow(_:))
        tableView.onReturnKey = { [weak coordinator] in
            coordinator?.openHighlightedRow()
        }

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false

        coordinator.tableView = tableView
        coordinator.installScrollObservation(on: scrollView)

        apply(to: coordinator)
        coordinator.rebuildColumnsIfNeeded(columns: effectiveColumns)
        coordinator.applyRows(rows)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        apply(to: coordinator)
        coordinator.rebuildColumnsIfNeeded(columns: effectiveColumns)
        coordinator.applyRows(rows)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.removeScrollObservation()
    }

    private func apply(to coordinator: Coordinator) {
        coordinator.isInteractionEnabled = inspectionEnabled
        coordinator.tableView?.isEnabled = inspectionEnabled
        let palette = DataGridThemeColors(theme: theme)
        let changed = coordinator.theme?.renderFingerprint != palette.renderFingerprint
        coordinator.theme = palette
        if let table = coordinator.tableView, changed {
            let scoped = palette.resolvedTheme
            table.rowHeight = max(scoped.assignedMetric("component.library.53.height", fallback: 28), max(scoped.assignedLineHeight("component.library.53.text", fallback: 16), scoped.assignedLineHeight("component.library.53.caption", fallback: 14)) + 2 * palette.padding)
            table.intercellSpacing = NSSize(width: scoped.assignedMetric("component.library.53.gap", fallback: scoped.space.s0), height: 0)
            table.backgroundColor = NSColor(scoped.surface.raised)
            if let scroll = table.enclosingScrollView {
                scroll.wantsLayer = true
                scroll.layer?.cornerRadius = scoped.assignedMetric("component.library.53.radius", fallback: 0)
                scroll.layer?.borderWidth = scoped.assignedMetric("component.library.53.borderWidth", fallback: 0)
                scroll.layer?.borderColor = NSColor(scoped.border.default).cgColor
                scroll.layer?.masksToBounds = true
            }
            for column in table.tableColumns { coordinator.styleHeader(column) }
            if let header = table.headerView {
                header.frame.size.height = max(17, scoped.assignedLineHeight("component.library.53.label", fallback: 14) + 2 * palette.padding)
                header.needsDisplay = true
            }
            // Style-only updates must repaint existing rows even when data is unchanged.
            table.reloadData()
        }
        coordinator.onRowOpen = onRowOpen
        coordinator.onNeedsMoreRows = onNeedsMoreRows
        coordinator.showsSelectionColumn = showsSelectionColumn
        coordinator.showsStatusColumn = showsStatusColumn
        coordinator.showsOpenColumn = showsOpenColumn
        coordinator.selectedKeys = selectedRowKeys
        coordinator.onSelectionChanged = { keys in
            selectedRowKeys = keys
        }
    }

    /// Data columns plus the synthetic leading/trailing columns in
    /// display order.
    private var effectiveColumns: [GridColumnSpec] {
        var specs: [GridColumnSpec] = []
        if showsSelectionColumn {
            let width = max(30, theme.assignedMetric("component.library.4.indicatorSize", fallback: 24) + 8)
            specs.append(GridColumnSpec(id: Coordinator.selectionColumnId, title: "", width: width, resizable: false))
        }
        if showsStatusColumn {
            let scoped = theme
            let font = scoped.assignedNativeFont("component.library.53.caption", fallback: scoped.nsFont(.caption))
            let textWidth = (L("Deleted") as NSString).size(withAttributes: [.font: font]).width
            let width = max(70, ceil(textWidth) + 2 * scoped.assignedMetric("component.library.53.padding", fallback: scoped.space.s8)
                + scoped.assignedMetric("component.library.53.gap", fallback: scoped.space.s0))
            specs.append(GridColumnSpec(id: Coordinator.statusColumnId, title: "", width: width, resizable: false))
        }
        for (index, column) in columns.enumerated() {
            specs.append(
                GridColumnSpec(
                    id: "data-\(index)",
                    title: column.title,
                    width: column.width,
                    resizable: true
                )
            )
        }
        if showsOpenColumn {
            specs.append(GridColumnSpec(id: Coordinator.openColumnId, title: "", width: 44, resizable: false))
        }
        return specs
    }
}

// MARK: - Column spec

struct GridColumnSpec: Equatable {
    let id: String
    let title: String
    let width: CGFloat
    let resizable: Bool
}

// MARK: - Theme cache

/// Pre-converted NSColors, rebuilt only when the theme changes, so cell
/// configuration stays cheap.
struct DataGridThemeColors: Equatable {
    let resolvedTheme: any ThemeProtocol
    let padding: CGFloat
    let textPrimary: NSColor
    let textTertiary: NSColor
    let accent: NSColor
    let zebra: NSColor
    let headerBackground: NSColor
    let warning: NSColor
    let codeFont: NSFont
    let headerFont: NSFont
    let captionFont: NSFont
    let renderFingerprint: Int

    init(theme: ThemeProtocol) {
        resolvedTheme = theme
        padding = theme.assignedMetric("component.library.53.padding", fallback: theme.space.s8)
        codeFont = theme.assignedNativeFont("component.library.53.text", fallback: theme.nsFont(.footnote, family: .code))
        headerFont = theme.assignedNativeFont("component.library.53.label", fallback: theme.nsFont(.micro, weight: .semibold, family: .code))
        captionFont = theme.assignedNativeFont("component.library.53.caption", fallback: theme.nsFont(.micro, weight: .semibold))
        renderFingerprint = theme.renderFingerprint
        textPrimary = NSColor(theme.text.primary)
        textTertiary = NSColor(theme.text.tertiary)
        accent = NSColor(theme.text.link)
        zebra = NSColor(theme.surface.subtle)
        headerBackground = NSColor(theme.surface.hover)
        warning = NSColor(theme.status.warning.foreground)
    }

    static func == (lhs: DataGridThemeColors, rhs: DataGridThemeColors) -> Bool {
        lhs.renderFingerprint == rhs.renderFingerprint
    }
}

// MARK: - Table view (Return-key handling)

final class DataGridTableView: NSTableView {
    var onReturnKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // Return / Enter opens the highlighted row (mirrors the tip
        // caption's "open" affordance for keyboard users).
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturnKey?()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Coordinator

extension AgentDataGridRepresentable {
    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let selectionColumnId = "sel"
        static let statusColumnId = "status"
        static let openColumnId = "open"

        weak var tableView: NSTableView?
        var theme: DataGridThemeColors?
        var onRowOpen: ((Int) -> Void)?
        var onNeedsMoreRows: (() -> Void)?
        var onSelectionChanged: ((Set<String>) -> Void)?
        var showsSelectionColumn = false
        var showsStatusColumn = false
        var showsOpenColumn = false
        var selectedKeys: Set<String> = []
        var isInteractionEnabled = true

        private var rows: [DataGridRowData] = []
        private var columnSpecs: [GridColumnSpec] = []
        private var scrollObserver: NSObjectProtocol?
        private weak var observedScrollView: NSScrollView?

        // MARK: Column management

        func rebuildColumnsIfNeeded(columns: [GridColumnSpec]) {
            guard let tableView else { return }
            let currentIds = tableView.tableColumns.map { $0.identifier.rawValue }
            let targetIds = columns.map(\.id)
            let currentTitles = tableView.tableColumns.map(\.title)
            let targetTitles = columns.map(\.title)
            guard currentIds != targetIds || currentTitles != targetTitles else {
                for (column, spec) in zip(tableView.tableColumns, columns) where !spec.resizable {
                    column.minWidth = 0
                    column.maxWidth = spec.width
                    column.width = spec.width
                    column.minWidth = spec.width
                }
                columnSpecs = columns
                return
            }
            for column in tableView.tableColumns.reversed() {
                tableView.removeTableColumn(column)
            }
            for spec in columns {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
                column.title = spec.title
                column.width = spec.width
                column.minWidth = spec.resizable ? 60 : spec.width
                column.maxWidth = spec.resizable ? 800 : spec.width
                column.resizingMask = spec.resizable ? .userResizingMask : []
                // Match the monospaced cell text so column names read as
                // part of the data, and keep truncated titles hoverable.
                column.headerCell.font = theme?.headerFont
                styleHeader(column)
                if !spec.title.isEmpty {
                    column.headerToolTip = spec.title
                }
                tableView.addTableColumn(column)
            }
            columnSpecs = columns
            tableView.reloadData()
        }

        func styleHeader(_ column: NSTableColumn) {
            guard let palette = theme else { return }
            let cell = (column.headerCell as? DataGridInspectionHeaderCell) ?? DataGridInspectionHeaderCell(textCell: column.title)
            cell.palette = palette
            cell.font = palette.headerFont
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            paragraph.minimumLineHeight = palette.resolvedTheme.assignedLineHeight("component.library.53.label", fallback: 14)
            cell.attributedStringValue = NSAttributedString(string: column.title, attributes: [.font: palette.headerFont, .foregroundColor: palette.textPrimary, .kern: palette.resolvedTheme.assignedTracking("component.library.53.label") ?? 0, .paragraphStyle: paragraph])
            column.headerCell = cell
        }

        // MARK: Row application (append-aware)

        func applyRows(_ newRows: [DataGridRowData]) {
            guard let tableView else { return }
            defer { refreshVisibleSelectionCheckboxes() }
            let old = rows
            rows = newRows
            // Incremental page append: old rows form a prefix of the new
            // list. Insert only the new tail so scroll position holds.
            if !old.isEmpty,
                newRows.count > old.count,
                old.first?.key == newRows.first?.key,
                old.last?.key == newRows[old.count - 1].key
            {
                let range = old.count ..< newRows.count
                tableView.insertRows(at: IndexSet(integersIn: range), withAnimation: [])
                return
            }
            if old != newRows {
                tableView.reloadData()
            }
        }

        /// Selection state lives outside the row data (checkbox toggles
        /// shouldn't diff/reload rows), so visible checkboxes are
        /// refreshed in place when the bound selection changes.
        private func refreshVisibleSelectionCheckboxes() {
            guard let tableView, showsSelectionColumn else { return }
            guard let columnIndex = tableView.tableColumns.firstIndex(where: {
                $0.identifier.rawValue == Self.selectionColumnId
            }) else { return }
            let visible = tableView.rows(in: tableView.visibleRect)
            guard visible.length > 0 else { return }
            for row in visible.location ..< (visible.location + visible.length) {
                guard row < rows.count else { continue }
                if let cell = tableView.view(atColumn: columnIndex, row: row, makeIfNecessary: false) as? DataGridCheckboxCell
                {
                    cell.setSelection(selectedKeys.contains(rows[row].key))
                    (tableView.rowView(atRow: row, makeIfNecessary: false) as? DataGridRowView)?.inspectionSelected = selectedKeys.contains(rows[row].key)
                }
            }
        }

        // MARK: NSTableViewDataSource

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        // MARK: NSTableViewDelegate

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let identifier = NSUserInterfaceItemIdentifier("DataGridRow")
            let rowView =
                tableView.makeView(withIdentifier: identifier, owner: nil) as? DataGridRowView
                ?? {
                    let view = DataGridRowView()
                    view.identifier = identifier
                    return view
                }()
            let isDeleted = row < rows.count && rows[row].isDeleted
            rowView.zebraColor = (row % 2 == 1) ? theme?.zebra : nil
            rowView.palette = theme
            rowView.inspectionSelected = row < rows.count && selectedKeys.contains(rows[row].key)
            rowView.alphaValue = isDeleted ? 0.55 : 1
            return rowView
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard row < rows.count, let columnId = tableColumn?.identifier.rawValue else { return nil }
            let rowData = rows[row]

            switch columnId {
            case Self.selectionColumnId:
                let cell = reusableCell(tableView, id: "sel-cell") { DataGridCheckboxCell() }
                guard let checkboxCell = cell as? DataGridCheckboxCell else { return cell }
                checkboxCell.applyInspection(theme)
                checkboxCell.configure(
                    isOn: selectedKeys.contains(rowData.key),
                    enabled: isInteractionEnabled && rowData.selectable,
                    visible: rowData.selectable
                ) { [weak self] isOn in
                    guard let self, self.isInteractionEnabled else { return }
                    if isOn {
                        self.selectedKeys.insert(rowData.key)
                    } else {
                        self.selectedKeys.remove(rowData.key)
                    }
                    self.onSelectionChanged?(self.selectedKeys)
                }
                return checkboxCell
            case Self.statusColumnId:
                let cell = reusableCell(tableView, id: "status-cell") { DataGridTextCell() }
                guard let textCell = cell as? DataGridTextCell else { return cell }
                textCell.configure(
                    text: rowData.isDeleted ? L("Deleted") : "",
                    color: theme?.warning ?? .systemOrange,
                    font: theme?.captionFont ?? CustomizableTheme.light().nsFont(.micro, weight: .semibold)
                )
                textCell.applyInspection(theme, property: "caption")
                return textCell
            case Self.openColumnId:
                let cell = reusableCell(tableView, id: "open-cell") { DataGridOpenButtonCell() }
                guard let openCell = cell as? DataGridOpenButtonCell else { return cell }
                openCell.configure(tint: theme?.accent ?? .linkColor, enabled: isInteractionEnabled) { [weak self] in
                    guard self?.isInteractionEnabled == true else { return }
                    self?.onRowOpen?(row)
                }
                return openCell
            default:
                let cell = reusableCell(tableView, id: "text-cell") { DataGridTextCell() }
                guard let textCell = cell as? DataGridTextCell else { return cell }
                let dataIndex = dataColumnIndex(for: columnId)
                let text = (dataIndex.map { $0 < rowData.cells.count ? rowData.cells[$0] : "" }) ?? ""
                textCell.configure(
                    text: text,
                    color: theme?.textPrimary ?? .labelColor,
                    font: theme?.codeFont ?? CustomizableTheme.light().nsFont(.footnote, family: .code)
                )
                textCell.applyInspection(theme, property: "text")
                return textCell
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {}

        // MARK: Actions

        @objc func didDoubleClickRow(_ sender: Any?) {
            guard isInteractionEnabled, let tableView else { return }
            let row = tableView.clickedRow
            guard row >= 0, row < rows.count else { return }
            onRowOpen?(row)
        }

        func openHighlightedRow() {
            guard isInteractionEnabled, let tableView else { return }
            let row = tableView.selectedRow
            guard row >= 0, row < rows.count else { return }
            onRowOpen?(row)
        }

        // MARK: Scroll observation → incremental loading

        func installScrollObservation(on scrollView: NSScrollView) {
            observedScrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleScrollChange()
                }
            }
        }

        func removeScrollObservation() {
            if let observer = scrollObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            scrollObserver = nil
        }

        private func handleScrollChange() {
            guard let scrollView = observedScrollView,
                let documentView = scrollView.documentView
            else { return }
            let visible = scrollView.contentView.bounds
            let remaining = documentView.frame.height - (visible.origin.y + visible.height)
            // ~20 rows of runway before the end triggers the next page;
            // the model's single-flight guard absorbs repeat calls.
            if remaining < 28 * 20 {
                onNeedsMoreRows?()
            }
        }

        // MARK: Helpers

        private func reusableCell(
            _ tableView: NSTableView,
            id: String,
            make: () -> NSView
        ) -> NSView {
            let identifier = NSUserInterfaceItemIdentifier(id)
            if let cell = tableView.makeView(withIdentifier: identifier, owner: nil) {
                return cell
            }
            let cell = make()
            cell.identifier = identifier
            return cell
        }

        private func dataColumnIndex(for columnId: String) -> Int? {
            guard columnId.hasPrefix("data-") else { return nil }
            return Int(columnId.dropFirst("data-".count))
        }
    }
}

// MARK: - Row view (zebra striping)

private final class DataGridRowView: NSTableRowView {
    var palette: DataGridThemeColors? { didSet { needsDisplay = true } }
    var inspectionSelected = false { didSet { needsDisplay = true } }
    private var inspectionHovered = false { didSet { needsDisplay = true } }
    private var inspectionTracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let inspectionTracking { removeTrackingArea(inspectionTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area); inspectionTracking = area
    }
    override func mouseEntered(with event: NSEvent) { inspectionHovered = true }
    override func mouseExited(with event: NSEvent) { inspectionHovered = false }
    var zebraColor: NSColor? {
        didSet { needsDisplay = true }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        if let palette {
            let t = palette.resolvedTheme
            NSColor(inspectionSelected ? t.surface.selected : inspectionHovered ? t.surface.hover : t.surface.raised).setFill()
            dirtyRect.fill()
            return
        }
        if let zebraColor {
            zebraColor.setFill()
            dirtyRect.fill()
        }
        super.drawSelection(in: dirtyRect)
    }
}

// MARK: - Cells

private final class DataGridTextCell: NSView {
    private var horizontalInset: CGFloat = 8
    func applyInspection(_ palette: DataGridThemeColors?, property: String) {
        guard let palette else { return }
        horizontalInset = palette.padding
        NativeComponentInspectionStyle.label(label, family: 53, property: property, theme: palette.resolvedTheme)
        needsLayout = true
    }
    private let label: NSTextField = {
        let tf = NSTextField(labelWithString: "")
        tf.isEditable = false
        tf.isSelectable = false
        tf.isBordered = false
        tf.drawsBackground = false
        tf.lineBreakMode = .byTruncatingTail
        tf.maximumNumberOfLines = 1
        return tf
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(text: String, color: NSColor, font: NSFont) {
        if label.stringValue != text { label.stringValue = text }
        label.textColor = color
        label.font = font
        // Grid cells hold user data of arbitrary shape; expose the raw
        // text so VoiceOver reads the cell contents.
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
    }

    override func layout() {
        super.layout()
        let size = label.sizeThatFits(NSSize(width: max(0, bounds.width - 2 * horizontalInset), height: bounds.height))
        label.frame = NSRect(
            x: horizontalInset,
            y: (bounds.height - size.height) / 2,
            width: max(0, bounds.width - 2 * horizontalInset),
            height: size.height
        )
    }
}

private final class DataGridCheckboxCell: NSView {
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    private var palette: DataGridThemeColors?
    private var isOn = false
    private var enabled = true
    private var visible = true
    func applyInspection(_ palette: DataGridThemeColors?) { self.palette = palette }
    private func updateControl() {
        guard let palette else { return }
        let theme = palette.resolvedTheme
        let size = theme.assignedMetric("component.library.4.indicatorSize", fallback: 24)
        hosting.isHidden = !visible
        hosting.rootView = AnyView(Toggle("Select row", isOn: Binding(get: { [weak self] in self?.isOn ?? false },
            set: { [weak self] value in
                guard let self, self.enabled else { return }
                self.isOn = value
                self.onToggle?(value)
                self.updateControl()
            }))
            .settingsCheckbox(showsLabel: false)
            .accessibilityLabel("Select row")
            .environment(\.theme, theme)
            .disabled(!enabled)
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity))
    }
    private var onToggle: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(hosting)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(isOn: Bool, enabled: Bool, visible: Bool = true, onToggle: @escaping (Bool) -> Void) {
        self.onToggle = onToggle
        self.isOn = isOn; self.enabled = enabled; self.visible = visible
        updateControl()
    }

    func setSelection(_ selected: Bool) {
        isOn = selected; updateControl()
    }

    override func layout() {
        super.layout()
        hosting.frame = bounds
    }
}

private final class DataGridOpenButtonCell: NSView {
    private let button: NSButton = {
        let b = NSButton()
        b.bezelStyle = .inline
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.image = NSImage(
            systemSymbolName: "arrow.up.right.square",
            accessibilityDescription: L("Open row")
        )
        b.toolTip = L("Open row")
        return b
    }()
    private var onOpen: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        button.target = self
        button.action = #selector(didTap)
        addSubview(button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(tint: NSColor, enabled: Bool = true, onOpen: @escaping () -> Void) {
        button.contentTintColor = tint
        button.isEnabled = enabled
        self.onOpen = onOpen
    }

    @objc private func didTap() {
        onOpen?()
    }

    override func layout() {
        super.layout()
        let size = NSSize(width: 22, height: 22)
        button.frame = NSRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}

/// Keep native column sizing/accessibility while drawing the assigned opaque header.
private final class DataGridInspectionHeaderCell: NSTableHeaderCell {
    var palette: DataGridThemeColors?
    // NSCell's inherited copy does not safely retain Swift stored properties.
    // AppKit copies header cells during redraw/resize; initialize the palette
    // through Swift assignment rather than copying its existential storage.
    override func copy(with zone: NSZone? = nil) -> Any {
        let cell = DataGridInspectionHeaderCell(textCell: stringValue)
        cell.font = font
        cell.alignment = alignment
        cell.lineBreakMode = lineBreakMode
        cell.attributedStringValue = attributedStringValue
        cell.palette = palette
        return cell
    }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard let palette else { super.draw(withFrame: cellFrame, in: controlView); return }
        let t = palette.resolvedTheme
        NSColor(t.surface.raised).setFill(); cellFrame.fill()
        attributedStringValue.draw(in: cellFrame.insetBy(dx: palette.padding, dy: palette.padding))
        let width = t.assignedMetric("component.library.53.borderWidth", fallback: 1)
        if width > 0 {
            NSColor(t.border.default).setFill()
            NSRect(x: cellFrame.minX, y: cellFrame.maxY - width, width: cellFrame.width, height: width).fill()
        }
    }
}
