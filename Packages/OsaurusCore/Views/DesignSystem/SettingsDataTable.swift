//
//  SettingsDataTable.swift
//  osaurus
//
//  A sortable, selectable table for a collection people compare across
//  columns (models by fit, memory and size). Columns declare a width, an
//  optional sort key and a hide priority: when the table is narrow (a detail
//  panel is open beside it) the highest-priority columns drop out first
//  instead of squeezing every cell. Rows open on click; inner buttons and
//  menus keep their own clicks.
//
//  Put it inside the page's `ScrollView`; the header pins while scrolling.
//

import SwiftUI

struct SettingsDataTableColumn<SortKey: Hashable>: Identifiable {
    enum Width {
        /// Takes the remaining width, never narrower than `min`.
        case flexible(min: CGFloat)
        case fixed(CGFloat)

        var minimum: CGFloat {
            switch self {
            case .flexible(let min): min
            case .fixed(let width): width
            }
        }
    }

    let id: String
    /// Catalog key; empty for an untitled column (row actions).
    let title: String
    var width: Width
    var alignment: HorizontalAlignment = .leading
    /// Nil for a column that does not sort.
    var sortKey: SortKey?
    /// Direction of the first click on this header (dates read newest first).
    var initialAscending: Bool = true
    /// 0 never hides; higher values hide first when the table is narrow.
    var hidePriority: Int = 0
}

struct SettingsDataTableSort<Key: Hashable>: Equatable {
    var key: Key
    var ascending: Bool

    /// Header click cycle: unsorted → the column's first direction → the
    /// other direction → unsorted (the caller's default order).
    static func next(
        after current: SettingsDataTableSort?,
        key: Key,
        initialAscending: Bool
    ) -> SettingsDataTableSort? {
        guard let current, current.key == key else {
            return SettingsDataTableSort(key: key, ascending: initialAscending)
        }
        if current.ascending == initialAscending {
            return SettingsDataTableSort(key: key, ascending: !initialAscending)
        }
        return nil
    }
}

enum SettingsDataTableLayout {
    /// The columns that fit `width`, dropping the highest `hidePriority`
    /// first (later columns first among equals). Columns at priority 0 always
    /// stay, even when they overflow.
    static func visibleColumns<Key: Hashable>(
        _ columns: [SettingsDataTableColumn<Key>],
        width: CGFloat,
        spacing: CGFloat,
        insets: CGFloat
    ) -> [SettingsDataTableColumn<Key>] {
        guard width > 0 else { return columns }
        var visible = columns
        func required() -> CGFloat {
            visible.reduce(0) { $0 + $1.width.minimum }
                + spacing * CGFloat(max(visible.count - 1, 0)) + insets
        }
        while required() > width {
            let hideable = visible.enumerated().filter { $0.element.hidePriority > 0 }
            guard
                let victim = hideable.max(by: { lhs, rhs in
                    lhs.element.hidePriority == rhs.element.hidePriority
                        ? lhs.offset < rhs.offset
                        : lhs.element.hidePriority < rhs.element.hidePriority
                })
            else { break }
            visible.remove(at: victim.offset)
        }
        return visible
    }
}

struct SettingsDataTable<Row: Identifiable, SortKey: Hashable, Cell: View>: View {
    @Environment(\.theme) private var theme

    let columns: [SettingsDataTableColumn<SortKey>]
    let rows: [Row]
    @Binding var sort: SettingsDataTableSort<SortKey>?
    @Binding var selection: Row.ID?
    var isLoading: Bool
    /// Catalog key read by VoiceOver for a row's open action.
    var rowActionLabel: String
    @ViewBuilder let cell: (Row, SettingsDataTableColumn<SortKey>) -> Cell

    @State private var width: CGFloat = 0
    @FocusState private var isFocused: Bool

    init(
        columns: [SettingsDataTableColumn<SortKey>],
        rows: [Row],
        sort: Binding<SettingsDataTableSort<SortKey>?>,
        selection: Binding<Row.ID?>,
        isLoading: Bool = false,
        rowActionLabel: String = "Show details",
        @ViewBuilder cell: @escaping (Row, SettingsDataTableColumn<SortKey>) -> Cell
    ) {
        self.columns = columns
        self.rows = rows
        self._sort = sort
        self._selection = selection
        self.isLoading = isLoading
        self.rowActionLabel = rowActionLabel
        self.cell = cell
    }

    private var visibleColumns: [SettingsDataTableColumn<SortKey>] {
        SettingsDataTableLayout.visibleColumns(
            columns,
            width: width,
            spacing: theme.settingsInlineGap,
            insets: theme.space.s12 * 2
        )
    }

    var body: some View {
        let visible = visibleColumns
        LazyVStack(alignment: .leading, spacing: theme.space.s0, pinnedViews: [.sectionHeaders]) {
            Section {
                if isLoading && rows.isEmpty {
                    ForEach(0 ..< 5, id: \.self) { index in
                        if index > 0 { SettingsGroupDivider() }
                        skeletonRow(visible, index: index)
                    }
                } else {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { SettingsGroupDivider() }
                        SettingsDataTableRow(
                            isSelected: selection == row.id,
                            actionLabel: rowActionLabel,
                            action: {
                                selection = row.id
                                isFocused = true
                            }
                        ) {
                            cells(for: row, visible)
                        }
                        .id(row.id)
                    }
                }
            } header: {
                header(visible)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: theme.radius.large, style: .continuous))
        .settingsChrome(.surface)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { moveSelection(by: -1) }
        .onKeyPress(.downArrow) { moveSelection(by: 1) }
    }

    // MARK: Header

    private func header(_ visible: [SettingsDataTableColumn<SortKey>]) -> some View {
        VStack(spacing: theme.space.s0) {
            HStack(spacing: theme.settingsInlineGap) {
                ForEach(visible) { column in
                    headerCell(column)
                        .modifier(SettingsDataTableCellFrame(width: column.width, alignment: column.alignment))
                }
            }
            .padding(.horizontal, theme.space.s12)
            .padding(.vertical, theme.space.s8)
            ThemeHairlineDivider(color: theme.rowRule)
        }
        .background(theme.surface.raised)
    }

    @ViewBuilder
    private func headerCell(_ column: SettingsDataTableColumn<SortKey>) -> some View {
        let label = Text(LocalizedStringKey(column.title), bundle: .module)
        if let key = column.sortKey {
            let active = sort?.key == key ? sort : nil
            Button {
                withAnimation(theme.motion.quick) {
                    sort = .next(after: sort, key: key, initialAscending: column.initialAscending)
                }
            } label: {
                HStack(spacing: theme.space.s4) {
                    label
                        .font(SettingsFont.compactLabel)
                        .foregroundColor(active == nil ? theme.text.tertiary : theme.text.primary)
                        .lineLimit(1)
                    if let active {
                        Image(systemName: active.ascending ? "chevron.up" : "chevron.down")
                            .glyphSize(.tiny, weight: .bold)
                            .foregroundColor(theme.text.primary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .accessibilityLabel(Text("Sort by \(Text(LocalizedStringKey(column.title), bundle: .module))", bundle: .module))
            .accessibilityAddTraits(active == nil ? [] : .isSelected)
        } else {
            label
                .font(SettingsFont.compactLabel)
                .foregroundColor(theme.text.tertiary)
                .lineLimit(1)
        }
    }

    // MARK: Rows

    private func cells(for row: Row, _ visible: [SettingsDataTableColumn<SortKey>]) -> some View {
        HStack(spacing: theme.settingsInlineGap) {
            ForEach(visible) { column in
                cell(row, column)
                    .modifier(SettingsDataTableCellFrame(width: column.width, alignment: column.alignment))
            }
        }
    }

    private func skeletonRow(_ visible: [SettingsDataTableColumn<SortKey>], index: Int) -> some View {
        HStack(spacing: theme.settingsInlineGap) {
            ForEach(visible) { column in
                SettingsSkeletonBar(height: theme.space.s12)
                    .modifier(SettingsDataTableCellFrame(width: column.width, alignment: column.alignment))
            }
        }
        .padding(.horizontal, theme.space.s12)
        .padding(.vertical, theme.space.s16)
        .settingsShimmer(delay: Double(index) * 0.1)
    }

    private func moveSelection(by step: Int) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        let current = selection.flatMap { id in rows.firstIndex { $0.id == id } }
        let next = current.map { min(max($0 + step, 0), rows.count - 1) } ?? (step > 0 ? 0 : rows.count - 1)
        selection = rows[next].id
        return .handled
    }
}

/// One table row: hover and selection wash, click to open.
private struct SettingsDataTableRow<Content: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    let isSelected: Bool
    let actionLabel: String
    let action: () -> Void
    @ViewBuilder let content: Content

    @State private var isHovered = false

    var body: some View {
        content
            .padding(.horizontal, theme.space.s12)
            .padding(.vertical, theme.space.s8)
            .frame(maxWidth: .infinity, minHeight: theme.space.s32 + theme.space.s16, alignment: .leading)
            .background(isSelected ? theme.surface.selected : isHovered ? theme.surface.hover : .clear)
            .overlay(Rectangle().strokeBorder(isSelected ? theme.selectionBorder : .clear, lineWidth: theme.selectionStroke))
            .contentShape(Rectangle())
            .onTapGesture { if isEnabled { action() } }
            .onHover { hovering in
                withAnimation(theme.motion.quick) { isHovered = hovering }
            }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(named: Text(LocalizedStringKey(actionLabel), bundle: .module)) { action() }
    }
}

/// Column sizing shared by the header, rows and skeleton so they line up.
private struct SettingsDataTableCellFrame: ViewModifier {
    let width: SettingsDataTableColumn<AnyHashable>.Width
    let alignment: HorizontalAlignment

    init<Key: Hashable>(width: SettingsDataTableColumn<Key>.Width, alignment: HorizontalAlignment) {
        switch width {
        case .fixed(let value): self.width = .fixed(value)
        case .flexible(let min): self.width = .flexible(min: min)
        }
        self.alignment = alignment
    }

    func body(content: Content) -> some View {
        let frameAlignment = Alignment(horizontal: alignment, vertical: .center)
        switch width {
        case .fixed(let value):
            content.frame(width: value, alignment: frameAlignment)
        case .flexible(let min):
            content.frame(minWidth: min, maxWidth: .infinity, alignment: frameAlignment)
        }
    }
}
