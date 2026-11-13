//
//  SettingsFilters.swift
//  osaurus
//
//  `FilterChip` is the only selectable filter pill (category, source,
//  kind, toggle). `FilterChipRow` lays a set of them out in one scrolling
//  row with an optional "All" chip. `FilterTokenChip` is the removable
//  applied-filter token. Pages put these in `SettingsPageHeader.toolbar`
//  or directly above the list they filter.
//

import SwiftUI

// MARK: - Filter Chip

struct FilterChip: View {
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var baseComponentEnabled
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(10, enabled: baseComponentEnabled) }
    @State private var isHovered = false

    /// Already-localized title (rendered verbatim).
    let title: String
    var icon: String?
    var count: Int?
    let isSelected: Bool
    /// Selected tint; defaults to the theme accent.
    var tint: Color?
    /// Already-localized tooltip.
    var help: String?
    let action: () -> Void

    init(
        _ title: String,
        icon: String? = nil,
        count: Int? = nil,
        isSelected: Bool,
        tint: Color? = nil,
        help: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.count = count
        self.isSelected = isSelected
        self.tint = tint
        self.help = help
        self.action = action
    }

    var body: some View {
        // Selected chips read the selection roles; a data-driven `tint`
        // (agent colour) only recolours the glyph/text when selected.
        let selectedForeground = baseComponentEnabled ? (tint ?? theme.text.primary) : theme.text.disabled
        Button(action: action) {
            SharedChipContent(spacing: theme.catalogMetric("gap", fallback: theme.space.s4)) {
                if let icon {
                    Image(systemName: icon)
                        .glyphSize(.tiny, weight: .semibold)
                }
                Text(verbatim: title)
                    .lineLimit(1)
                if let count {
                    Text(verbatim: "\(count)")
                        .monospacedDigit()
                        .composerChipInk("secondary", fallback: isSelected ? theme.text.secondary : theme.text.tertiary)
                }
            }
            .composerChipTextStyle(.label)
            .composerChipInk("foreground", fallback: isSelected ? selectedForeground : theme.text.secondary)
            .fixedSize()
            .composerChipInk("foreground", fallback: theme.text.primary)
            .composerChipSurface(selected: isSelected)
            .environment(\.sharedChipVariant, .filter)
            .contentShape(Capsule())
        }
        .assignedBasePlainButtonStyle()
        .assignedBaseKeyboardButton(10, action: action)
        .onHover { isHovered = $0 }
        .animation(theme.motion.quick, value: isHovered)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(help ?? "")
    }
}

// MARK: - Filter Chip Row

/// Single-select filter over `items`. `nil` selection is the "All" chip
/// when `allTitle` is set. Re-tapping a selected chip clears it when
/// `allowsDeselect` is on (and there is an "All" state to fall back to).
struct FilterChipRow<Item: Hashable>: View {
    @Environment(\.theme) private var theme
    let items: [Item]
    @Binding var selection: Item?
    var allTitle: String?
    var allCount: Int?
    var allowsDeselect: Bool
    let title: (Item) -> String
    var icon: ((Item) -> String?)?
    var count: ((Item) -> Int?)?
    var tint: ((Item) -> Color?)?

    private static var allID: String { "__filter_all__" }

    @State private var overflow = ChipRowOverflow()

    init(
        _ items: [Item],
        selection: Binding<Item?>,
        allTitle: String? = L("All"),
        allCount: Int? = nil,
        allowsDeselect: Bool = true,
        title: @escaping (Item) -> String,
        icon: ((Item) -> String?)? = nil,
        count: ((Item) -> Int?)? = nil,
        tint: ((Item) -> Color?)? = nil
    ) {
        self.items = items
        self._selection = selection
        self.allTitle = allTitle
        self.allCount = allCount
        self.allowsDeselect = allowsDeselect
        self.title = title
        self.icon = icon
        self.count = count
        self.tint = tint
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: theme.space.s6) {
                    if let allTitle {
                        FilterChip(allTitle, count: allCount, isSelected: selection == nil) {
                            select(nil)
                        }
                        .id(Self.allID)
                    }
                    ForEach(items, id: \.self) { item in
                        FilterChip(
                            title(item),
                            icon: icon?(item),
                            count: count?(item),
                            isSelected: selection == item,
                            tint: tint?(item)
                        ) {
                            select(selection == item && allowsDeselect && allTitle != nil ? nil : item)
                        }
                        .id(item)
                    }
                }
                .padding(.vertical, theme.space.s2)
            }
            // Fades a cut-off edge so the hidden chips read as scrollable.
            .onScrollGeometryChange(for: ChipRowOverflow.self) { geo in
                ChipRowOverflow(
                    leading: geo.visibleRect.minX > 1,
                    trailing: geo.visibleRect.maxX < geo.contentSize.width - 1
                )
            } action: { _, new in
                withAnimation(theme.motion.quick) { overflow = new }
            }
            .mask {
                HStack(spacing: theme.space.s0) {
                    edgeFade(fading: overflow.leading, toward: .leading)
                    Rectangle()
                    edgeFade(fading: overflow.trailing, toward: .trailing)
                }
            }
            .onChange(of: selection) { _, newValue in
                withAnimation(theme.motion.quick) {
                    if let newValue {
                        proxy.scrollTo(newValue, anchor: .center)
                    } else {
                        proxy.scrollTo(Self.allID, anchor: .center)
                    }
                }
            }
        }
    }

    private func select(_ item: Item?) {
        withAnimation(theme.motion.quick) { selection = item }
    }

    /// Opaque while nothing is past that edge. The solid layer's opacity is
    /// what animates, since gradient stops do not interpolate.
    private func edgeFade(fading: Bool, toward end: UnitPoint) -> some View {
        ZStack {
            LinearGradient(colors: [.black, .clear], startPoint: end == .leading ? .trailing : .leading, endPoint: end)
            Rectangle().opacity(fading ? 0 : 1)
        }
        .frame(width: theme.space.s32)
    }
}

/// Which ends of a horizontal chip row still hide chips.
private struct ChipRowOverflow: Equatable {
    var leading = false
    var trailing = false
}

// MARK: - Filter Token Chip

/// An applied filter ("Kind: Tool calls") with a remove button.
struct FilterTokenChip: View {
    @Environment(\.theme) private var baseTheme
    @Environment(\.isEnabled) private var baseComponentEnabled
    private var theme: any ThemeProtocol { baseTheme.catalogFamily(10, enabled: baseComponentEnabled) }

    /// Already-localized kind prefix ("Kind", "Source").
    let prefix: String?
    /// Already-localized value.
    let label: String
    let onRemove: () -> Void

    init(prefix: String? = nil, _ label: String, onRemove: @escaping () -> Void) {
        self.prefix = prefix
        self.label = label
        self.onRemove = onRemove
    }

    var body: some View {
        SharedChipContent(spacing: theme.catalogMetric("gap", fallback: theme.space.s4)) {
            if let prefix {
                Text(verbatim: prefix)
                    .composerChipTextStyle(.caption)
                    .composerChipInk("secondary", fallback: theme.text.tertiary)
            }
            SettingsHuggingLayout(maximumWidth: 220) {
                Text(verbatim: label)
                    .composerChipTextStyle(.label)
                    .composerChipInk("foreground", fallback: theme.text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(label)
            }
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .glyphSize(.tiny, weight: .bold)
                    .composerChipInk("secondary", fallback: theme.text.tertiary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .assignedBasePlainButtonStyle()
            .assignedBaseKeyboardButton(10, action: onRemove)
            .accessibilityLabel(Text("Remove \(label)", bundle: .module))
            .settingsHelp("Remove this filter")
        }
        .composerChipInk("foreground", fallback: theme.text.primary)
        .composerChipSurface(selected: true)
        .environment(\.sharedChipVariant, .removable)
    }
}
