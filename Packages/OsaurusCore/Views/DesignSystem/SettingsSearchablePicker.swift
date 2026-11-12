//
//  SettingsSearchablePicker.swift
//  osaurus
//
//  A value picked from a list too long for `SettingsMenuPicker`: a field
//  that opens a popover with a search box over a grouped list. Typing
//  filters, ↑ / ↓ move, Return picks, Escape closes.
//

import SwiftUI

struct SettingsSearchablePicker: View {
    /// `.field` fills a form column; `.compact` sits trailing in a row.
    enum Style { case field, compact }

    /// A way out under the list ("Add a provider"). Runs once the popover
    /// has closed.
    struct Action: Identifiable {
        let id: String
        /// Already localized.
        let title: String
        let icon: String
        let handler: () -> Void
    }

    struct Option: Identifiable, Equatable {
        let id: String
        /// Already localized.
        let title: String
        /// Already localized; trails the title.
        var detail: String? = nil
        /// The section the option is listed under, in first-seen order.
        var group: String? = nil
        /// More text the search matches, such as an identifier.
        var keywords: String? = nil
    }

    @Environment(\.theme) private var theme

    let options: [Option]
    @Binding var selection: String?
    /// The field's text. Already localized.
    let label: String
    var icon: String? = nil
    /// A first row that picks nil ("Default model"). Already localized.
    var noneTitle: String? = nil
    var searchPlaceholder: LocalizedStringKey = "Search"
    /// Shows the field's text in the warning tone.
    var isInvalid: Bool = false
    var style: Style = .field
    var actions: [Action] = []

    @State private var isOpen = false

    var body: some View {
        trigger
            .help(label)
            .popover(isPresented: $isOpen, arrowEdge: .bottom) {
                SettingsSearchablePickerList(
                    options: options, selection: selection, noneTitle: noneTitle,
                    searchPlaceholder: searchPlaceholder, actions: actions,
                    onPick: { picked in
                        isOpen = false
                        if picked != selection { selection = picked }
                    },
                    onAction: { action in
                        isOpen = false
                        Task { @MainActor in
                            try? await Task.sleepForPopoverDismiss()
                            action.handler()
                        }
                    },
                    onCancel: { isOpen = false }
                )
                .environment(\.theme, theme)
            }
    }

    @ViewBuilder private var trigger: some View {
        switch style {
        case .field:
            SettingsPopUpButton(style: .field, isActive: isOpen) { isOpen.toggle() } label: { labelContent }
        case .compact:
            SettingsPopUpButton(style: .compact, isActive: isOpen) { isOpen.toggle() } label: {
                labelContent.frame(maxWidth: Self.compactMaxWidth, alignment: .leading)
            }
        }
    }

    private static let compactMaxWidth: CGFloat = 240

    private var labelContent: some View {
        HStack(spacing: theme.space.s8) {
            if let icon {
                Image(systemName: icon)
                    .font(SettingsFont.glyph)
                    .foregroundColor(theme.text.tertiary)
            }
            Text(verbatim: label)
                .foregroundColor(
                    isInvalid
                        ? theme.status.warning.foreground : selection == nil ? theme.text.secondary : theme.text.primary
                )
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// The popover's content: search box and the filtered, grouped list.
struct SettingsSearchablePickerList: View {
    @Environment(\.theme) private var theme

    let options: [SettingsSearchablePicker.Option]
    let selection: String?
    let noneTitle: String?
    let searchPlaceholder: LocalizedStringKey
    var actions: [SettingsSearchablePicker.Action] = []
    let onPick: (String?) -> Void
    var onAction: (SettingsSearchablePicker.Action) -> Void = { _ in }
    let onCancel: () -> Void

    @State private var query = ""
    @State private var highlighted: String?
    /// Set by the keyboard (and on open) so the list scrolls; hovering only
    /// highlights.
    @State private var scrollTarget: String?

    private static let noneID = "\u{1}none"
    private static let width: CGFloat = 360
    private static let maxListHeight: CGFloat = 320
    private static let rowHeight: CGFloat = 30
    private static let headerHeight: CGFloat = 28

    private struct Row: Identifiable {
        let id: String
        let value: String?
        let title: String
        let detail: String?
    }

    private struct Section: Identifiable {
        let id: String
        let title: String?
        var rows: [Row]
    }

    private var sections: [Section] {
        let prepared = SearchService.PreparedQuery(query)
        func matches(_ texts: String?...) -> Bool {
            prepared.tokens.isEmpty || texts.compactMap { $0 }.contains { SearchService.matches(prepared, in: $0) }
        }
        var out: [Section] = []
        if let noneTitle, matches(noneTitle) {
            out.append(Section(id: Self.noneID, title: nil, rows: [Row(id: Self.noneID, value: nil, title: noneTitle, detail: nil)]))
        }
        for option in options where matches(option.title, option.detail, option.group, option.keywords) {
            let row = Row(id: option.id, value: option.id, title: option.title, detail: option.detail)
            let key = option.group ?? ""
            if let index = out.firstIndex(where: { $0.id == "group:" + key }) {
                out[index].rows.append(row)
            } else {
                out.append(Section(id: "group:" + key, title: option.group, rows: [row]))
            }
        }
        return out
    }

    var body: some View {
        let sections = sections
        let rowIDs = sections.flatMap { $0.rows.map(\.id) }
        VStack(spacing: theme.space.s0) {
            SearchField(
                text: $query, placeholder: searchPlaceholder, fillsAvailableWidth: true,
                onSubmit: { pick(highlighted ?? rowIDs.first) },
                onMove: { move($0, in: rowIDs) },
                onCancel: onCancel,
                autofocus: true
            )
            .padding(theme.space.s8)
            Divider()
            if rowIDs.isEmpty {
                Text("No matches", bundle: .module)
                    .font(SettingsFont.caption)
                    .foregroundColor(theme.text.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, theme.space.s24)
            } else {
                list(sections)
                    .frame(height: listHeight(sections))
            }
            if !actions.isEmpty {
                Divider()
                VStack(spacing: theme.space.s0) {
                    ForEach(actions) { action in actionRow(action) }
                }
                .padding(theme.space.s6)
            }
        }
        .frame(width: Self.width)
        .onAppear {
            let current = selection ?? (noneTitle == nil ? nil : Self.noneID)
            highlighted = current ?? rowIDs.first
            scrollTarget = highlighted
        }
        .onChange(of: query) { _, _ in
            highlighted = self.sections.first?.rows.first?.id
            scrollTarget = highlighted
        }
    }

    private func list(_ sections: [Section]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: theme.space.s0) {
                    ForEach(sections) { section in
                        if let title = section.title {
                            Text(verbatim: title)
                                .font(SettingsFont.caption.weight(.semibold))
                                .foregroundColor(theme.text.tertiary)
                                .lineLimit(1)
                                .padding(.horizontal, theme.space.s8)
                                .frame(maxWidth: .infinity, minHeight: Self.headerHeight, alignment: .bottomLeading)
                                .padding(.bottom, theme.space.s2)
                        }
                        ForEach(section.rows) { row in
                            rowView(row).id(row.id)
                        }
                    }
                }
                .padding(theme.space.s6)
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                proxy.scrollTo(target)
                scrollTarget = nil
            }
            .onAppear {
                if let target = scrollTarget {
                    DispatchQueue.main.async { proxy.scrollTo(target, anchor: .center) }
                }
            }
        }
    }

    private func rowView(_ row: Row) -> some View {
        let isSelected = row.value == selection
        return Button {
            onPick(row.value)
        } label: {
            HStack(spacing: theme.space.s8) {
                Text(verbatim: row.title)
                    .font(SettingsFont.body)
                    .foregroundColor(row.value == nil ? theme.text.secondary : theme.text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = row.detail {
                    Text(verbatim: detail)
                        .font(SettingsFont.caption)
                        .foregroundColor(theme.text.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: theme.space.s8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(SettingsFont.glyphSmall.weight(.semibold))
                        .foregroundColor(theme.text.link)
                }
            }
            .padding(.horizontal, theme.space.s8)
            .frame(height: Self.rowHeight)
            .settingsChrome(highlighted == row.id ? .hover : nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { highlighted = row.id } }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func actionRow(_ action: SettingsSearchablePicker.Action) -> some View {
        let id = "action:" + action.id
        return Button {
            onAction(action)
        } label: {
            HStack(spacing: theme.space.s8) {
                Image(systemName: action.icon)
                    .font(SettingsFont.glyph)
                    .frame(width: theme.space.s16)
                Text(verbatim: action.title)
                    .font(SettingsFont.body)
                Spacer(minLength: 0)
            }
            .foregroundColor(theme.text.link)
            .padding(.horizontal, theme.space.s8)
            .frame(height: Self.rowHeight)
            .settingsChrome(highlighted == id ? .hover : nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { highlighted = id } }
    }

    private func listHeight(_ sections: [Section]) -> CGFloat {
        let rows = sections.reduce(0) { $0 + $1.rows.count }
        let headers = sections.filter { $0.title != nil }.count
        let content = CGFloat(rows) * Self.rowHeight + CGFloat(headers) * (Self.headerHeight + theme.space.s2)
            + theme.space.s6 * 2
        return min(content, Self.maxListHeight)
    }

    private func move(_ delta: Int, in ids: [String]) {
        guard !ids.isEmpty else { return }
        let next: Int
        if let current = highlighted.flatMap({ ids.firstIndex(of: $0) }) {
            next = max(0, min(ids.count - 1, current + delta))
        } else {
            next = delta > 0 ? 0 : ids.count - 1
        }
        highlighted = ids[next]
        scrollTarget = ids[next]
    }

    private func pick(_ id: String?) {
        guard let id else { return }
        onPick(id == Self.noneID ? nil : id)
    }
}
