//
//  SettingsFilters.swift
//  osaurus
//
//  `FilterChip` is the only selectable filter pill (category, source,
//  kind, toggle). `FilterChipRow` lays a set of them out in one scrolling
//  row with an optional "All" chip; `FilterChipScroller` is that row's
//  scrolling container for chips laid out by hand. `FilterTokenChip` is the removable
//  applied-filter token. Pages put these in `SettingsPageHeader.toolbar`
//  or directly above the list they filter.
//

import AppKit
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
        FilterChipScroller(reveal: selection.map { AnyHashable($0) } ?? AnyHashable(Self.allID)) {
            if let allTitle {
                FilterChip(allTitle, count: allCount, isSelected: selection == nil) {
                    select(nil)
                }
                .id(AnyHashable(Self.allID))
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
                .id(AnyHashable(item))
            }
        }
    }

    private func select(_ item: Item?) {
        withAnimation(theme.motion.quick) { selection = item }
    }
}

// MARK: - Filter Chip Scroller

/// One horizontal row of chips that may be wider than the page. Every chip
/// row goes through this so the outer chips keep their whole border and
/// focus ring, and chips past either edge stay reachable without a trackpad:
/// a cut-off edge fades and shows a chevron that pages the row, and a
/// vertical mouse wheel over the row scrolls it sideways. `reveal` is the
/// `.id` of a chip to scroll into view whenever it changes.
struct FilterChipScroller<Content: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var spacing: CGFloat?
    var reveal: AnyHashable?
    @ViewBuilder let content: () -> Content

    @State private var position = ScrollPosition(point: .zero)
    @State private var metrics = ChipRowMetrics()
    @State private var chevronWidth: CGFloat = 0

    init(spacing: CGFloat? = nil, reveal: AnyHashable? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.reveal = reveal
        self.content = content
    }

    /// Room past each outer chip for its stroke and keyboard focus ring,
    /// both of which draw outside the chip's frame. The extra slack keeps
    /// the ring's anti-aliased outer edge off the clip line when the row
    /// lands on a fractional pixel.
    private var bleed: CGFloat {
        theme.assignedMetric("component.focus.offset", fallback: theme.focusOffset)
            + theme.assignedMetric("component.focus.width", fallback: theme.stroke.focus)
            + theme.space.s2
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: spacing ?? theme.space.s6) { content() }
                    .padding(bleed)
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: ChipRowMetrics.self) { geo in
                ChipRowMetrics(
                    offset: geo.contentOffset.x,
                    visibleWidth: geo.containerSize.width,
                    contentWidth: geo.contentSize.width
                )
            } action: { old, new in
                if old.overflow != new.overflow {
                    withAnimation(motion(theme.motion.quick)) { metrics = new }
                } else {
                    metrics = new
                }
            }
            // The bleed sits outside the row so the first chip still lines
            // up with the content above and below it.
            .padding(.horizontal, -bleed)
            .mask {
                HStack(spacing: theme.space.s0) {
                    edgeFade(fading: metrics.overflow.leading, toward: .leading)
                    Rectangle()
                    edgeFade(fading: metrics.overflow.trailing, toward: .trailing)
                }
            }
            .overlay(alignment: .leading) {
                if metrics.overflow.leading {
                    chevron("chevron.left", help: "Scroll left") { page(by: -1) }
                }
            }
            .overlay(alignment: .trailing) {
                if metrics.overflow.trailing {
                    chevron("chevron.right", help: "Scroll right") { page(by: 1) }
                }
            }
            .background {
                HorizontalWheelScroll(isActive: metrics.overflow.any) { delta in
                    scroll(by: delta)
                }
            }
            .onChange(of: reveal) { _, id in
                guard let id else { return }
                withAnimation(motion(theme.motion.quick)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func chevron(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        SettingsIconButton(icon, help: help, size: .compact, action: action)
            .padding(.horizontal, bleed)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chevronWidth = $0 }
            .transition(.opacity)
    }

    /// Opaque while nothing is past that edge. Once chips are hidden there,
    /// it is clear under the chevron and fades in beside it. The solid
    /// layer's opacity is what animates, since gradient stops do not
    /// interpolate.
    private func edgeFade(fading: Bool, toward end: Edge) -> some View {
        let fade = LinearGradient(
            colors: [.black, .clear],
            startPoint: end == .leading ? .trailing : .leading,
            endPoint: end == .leading ? .leading : .trailing
        )
        .frame(width: theme.space.s32)
        let clearWidth = fading ? chevronWidth : 0
        let underChevron = Color.clear.frame(width: clearWidth)
        return ZStack {
            HStack(spacing: theme.space.s0) {
                if end == .leading { underChevron; fade } else { fade; underChevron }
            }
            Rectangle().opacity(fading ? 0 : 1)
        }
        // The solid layer is flexible; without a fixed width each edge
        // would take a third of the row and mask out the chips inside it.
        .frame(width: clearWidth + theme.space.s32)
    }

    /// Moves most of a visible width, keeping a chip's worth of overlap so
    /// the reader can tell where they were.
    private func page(by direction: CGFloat) {
        let step = max(metrics.visibleWidth - 2 * (chevronWidth + theme.space.s32), metrics.visibleWidth / 2)
        withAnimation(motion(theme.motion.standard)) { scroll(to: metrics.offset + direction * step) }
    }

    /// Returns whether the row moved, so a wheel at either end can scroll
    /// the page instead.
    private func scroll(by delta: CGFloat) -> Bool {
        let before = metrics.offset
        scroll(to: before + delta)
        return clamped(before + delta) != clamped(before)
    }

    private func scroll(to x: CGFloat) {
        position.scrollTo(x: clamped(x))
    }

    private func clamped(_ x: CGFloat) -> CGFloat {
        min(max(x, 0), max(metrics.contentWidth - metrics.visibleWidth, 0))
    }

    private func motion(_ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }
}

/// Where a horizontal chip row is scrolled and which ends still hide chips.
private struct ChipRowMetrics: Equatable {
    var offset: CGFloat = 0
    var visibleWidth: CGFloat = 0
    var contentWidth: CGFloat = 0

    var overflow: (leading: Bool, trailing: Bool, any: Bool) {
        let leading = offset > 1
        let trailing = offset + visibleWidth < contentWidth - 1
        return (leading, trailing, leading || trailing)
    }
}

/// Sends a vertical mouse wheel over this view to `onScroll` as a
/// horizontal distance while `isActive`. Trackpads already scroll
/// sideways, so only wheel events with whole-line deltas are taken, and
/// only while `onScroll` reports the row moved; otherwise the page under
/// the row scrolls as usual.
private struct HorizontalWheelScroll: NSViewRepresentable {
    @Environment(\.theme) private var theme
    let isActive: Bool
    let onScroll: (CGFloat) -> Bool

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onScroll = onScroll
        view.lineDistance = theme.space.s32
        view.setActive(isActive)
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.setActive(false)
    }

    final class MonitorView: NSView {
        var onScroll: (CGFloat) -> Bool = { _ in false }
        var lineDistance: CGFloat = 0
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { setActive(false) }
        }

        func setActive(_ active: Bool) {
            if active, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    let consumed = MainActor.assumeIsolated { self?.consumes(event) ?? false }
                    return consumed ? nil : event
                }
            } else if !active, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func consumes(_ event: NSEvent) -> Bool {
            guard let window, event.window === window, !event.hasPreciseScrollingDeltas,
                abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
                bounds.contains(convert(event.locationInWindow, from: nil))
            else { return false }
            return onScroll(-event.scrollingDeltaY * lineDistance)
        }
    }
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
