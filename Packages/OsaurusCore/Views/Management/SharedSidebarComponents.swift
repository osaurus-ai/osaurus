//
//  SharedSidebarComponents.swift
//  osaurus
//
//  Shared components for chat session sidebars.
//

import AppKit
import SwiftUI

// MARK: - Sidebar Style Constants

/// Centralized styling constants for sidebar components (similar to ToastStyle).
enum SidebarStyle {
    // MARK: Layout
    static let width: CGFloat = 240
    static let actionButtonSize: CGFloat = 24
}

// MARK: - Sidebar Container

/// Container with consistent sidebar styling and glass background support.
/// Supports edge-attached mode for seamless integration with parent views.
struct SidebarContainer<Content: View>: View {
    /// The edge this sidebar is attached to (affects corner radius)
    let attachedEdge: Edge?
    /// Top padding for the content (useful for window control clearance)
    let topPadding: CGFloat
    /// Fixed width of the container. Defaults to the shared constant; callers
    /// that support a user-resizable rail pass a live width instead.
    let width: CGFloat
    let roundBottomCorners: Bool
    let showsBorder: Bool

    @ViewBuilder let content: () -> Content
    @Environment(\.theme) private var environmentTheme
    @Environment(\.isEnabled) private var componentEnabled
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(42, enabled: componentEnabled, authoritative: true) }

    init(
        attachedEdge: Edge? = nil,
        topPadding: CGFloat = 0,
        width: CGFloat = SidebarStyle.width,
        roundBottomCorners: Bool = true,
        showsBorder: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.attachedEdge = attachedEdge
        self.topPadding = topPadding
        self.width = width
        self.roundBottomCorners = roundBottomCorners
        self.showsBorder = showsBorder
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .padding(.top, topPadding)
        .frame(width: width, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .environment(\.theme, theme)
        .background { SidebarBackground() }
        .clipShape(containerShape)
        .overlay { if showsBorder { SidebarBorder(attachedEdge: attachedEdge) } }
    }

    private var containerShape: UnevenRoundedRectangle {
        let radius = theme.radius.large
        switch attachedEdge {
        case .leading:
            // Attached to leading edge - round only leading corners
            return UnevenRoundedRectangle(
                topLeadingRadius: radius,
                bottomLeadingRadius: roundBottomCorners ? radius : 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0,
                style: .continuous
            )
        case .trailing:
            // Attached to trailing edge - round only trailing corners
            return UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: radius,
                topTrailingRadius: radius,
                style: .continuous
            )
        case .top, .bottom, .none:
            // Not attached or attached to top/bottom - round all corners
            return UnevenRoundedRectangle(
                topLeadingRadius: radius,
                bottomLeadingRadius: radius,
                bottomTrailingRadius: radius,
                topTrailingRadius: radius,
                style: .continuous
            )
        }
    }
}

// MARK: - Sidebar Background

/// Opaque sidebar surface (color.surface.sidebar). No component glass: the
/// base window material is the only translucent layer in the app.
struct SidebarBackground: View {
    @Environment(\.theme) private var environmentTheme
    @Environment(\.isEnabled) private var componentEnabled
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(42, enabled: componentEnabled, authoritative: true) }

    var body: some View {
        theme.surface.sidebar
    }
}

// MARK: - Sidebar Border

/// Gradient border with accent edge highlight for sidebar (similar to ToastBorder)
struct SidebarBorder: View {
    @Environment(\.theme) private var environmentTheme
    @Environment(\.isEnabled) private var componentEnabled
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(42, enabled: componentEnabled, authoritative: true) }

    let attachedEdge: Edge?

    init(attachedEdge: Edge? = nil) {
        self.attachedEdge = attachedEdge
    }

    var body: some View {
        borderShape
            .strokeBorder(theme.border.subtle, lineWidth: theme.stroke.default)
    }

    private var borderShape: UnevenRoundedRectangle {
        let radius = theme.radius.large
        switch attachedEdge {
        case .leading:
            return UnevenRoundedRectangle(
                topLeadingRadius: radius,
                bottomLeadingRadius: radius,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0,
                style: .continuous
            )
        case .trailing:
            return UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: radius,
                topTrailingRadius: radius,
                style: .continuous
            )
        case .top, .bottom, .none:
            return UnevenRoundedRectangle(
                topLeadingRadius: radius,
                bottomLeadingRadius: radius,
                bottomTrailingRadius: radius,
                topTrailingRadius: radius,
                style: .continuous
            )
        }
    }

}

// MARK: - Sidebar Scroll Edge Fade

/// Which ends of a vertical scroll view still hide content.
struct SidebarScrollOverflow: Equatable {
    var above = false
    var below = false

    /// `visibleRect` is in content coordinates. The tolerance absorbs
    /// rubber-banding and sub-point rounding at rest.
    init(visibleRect: CGRect, contentHeight: CGFloat, tolerance: CGFloat = 1) {
        above = visibleRect.minY > tolerance
        below = visibleRect.maxY < contentHeight - tolerance
    }

    init() {}
}

/// Fades the top or bottom of a vertical scroll view while content runs
/// past that edge. With overlay scrollers hidden at rest, the fade is the
/// only sign that a clipped list continues.
private struct SidebarScrollEdgeFade: ViewModifier {
    let length: CGFloat

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var overflow = SidebarScrollOverflow()
    /// The first sample lands while the window lays out; it is not animated.
    @State private var hasSampled = false

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: SidebarScrollOverflow.self) { geo in
                SidebarScrollOverflow(visibleRect: geo.visibleRect, contentHeight: geo.contentSize.height)
            } action: { _, new in
                withAnimation(reduceMotion || !hasSampled ? nil : theme.motion.quick) { overflow = new }
                hasSampled = true
            }
            .mask {
                VStack(spacing: 0) {
                    edge(fading: overflow.above, toward: .top)
                    Rectangle()
                    edge(fading: overflow.below, toward: .bottom)
                }
            }
    }

    /// Opaque while that edge has nothing past it; a gradient to clear
    /// at the edge while it does. The solid layer's opacity is what
    /// animates, since gradient stops do not interpolate.
    private func edge(fading: Bool, toward end: UnitPoint) -> some View {
        ZStack {
            LinearGradient(colors: [.black, .clear], startPoint: end == .top ? .bottom : .top, endPoint: end)
            Rectangle().opacity(fading ? 0 : 1)
        }
        .frame(height: length)
    }
}

extension View {
    /// Fade a vertical scroll view's edges while it can scroll that way.
    /// Apply to the `ScrollView` itself.
    func sidebarScrollEdgeFade(length: CGFloat = 28) -> some View {
        modifier(SidebarScrollEdgeFade(length: length))
    }
}

// MARK: - Sidebar Lens Bar

/// Equal-width segmented switcher that fills its row (Agents | Projects
/// on the left rail, Timeline | Files in the File Changes pane).
/// Each segment is the whole padded rectangle as a hit target,
/// accent-tinted when selected, with an optional count badge. When every
/// label does not fit with room to spare, unselected segments with an icon
/// shrink to the icon (the label moves to a tooltip); segments still fill
/// the bar, and the selected one is never narrower than its label. Views
/// within a pane use `FilterChipRow`, one level below.
struct SidebarLensBar<Value: Hashable>: View {
    struct Segment {
        let value: Value
        let label: LocalizedStringKey
        var icon: String? = nil
        var badge: Int? = nil
        var accessibilityLabel: Text? = nil
    }

    @Binding var selection: Value
    let segments: [Segment]

    @Environment(\.theme) private var environmentTheme
    @Environment(\.isEnabled) private var componentEnabled
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(42, enabled: componentEnabled, authoritative: true) }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(compact: false)
            bar(compact: true)
        }
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.42.elements.layout.sidebarLensBar.body.padding.horizontal", inheriting: NativeComponentInspectionStyle.metric(42, "padding", 3, theme))).padding(.vertical, theme.catalogLayoutMetric("component.library.42.elements.layout.sidebarLensBar.body.padding.vertical", inheriting: NativeComponentInspectionStyle.metric(42, "padding", 3, theme))).catalogLayoutTarget("component.library.42.elements.layout.sidebarLensBar.body.padding.horizontal").catalogLayoutTarget("component.library.42.elements.layout.sidebarLensBar.body.padding.vertical")
        .environment(\.theme, theme)
        .settingsChrome(.inset)
    }

    private func bar(compact: Bool) -> some View {
        SidebarEqualWidthRow(
            spacing: 4,
            wholeIndex: compact ? segments.firstIndex { $0.value == selection } : nil
        ) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                segmentButton(segment, compact: compact)
            }
        }
    }

    private func segmentButton(_ segment: Segment, compact: Bool) -> some View {
        let isSelected = selection == segment.value
        let showsLabel = !compact || isSelected || segment.icon == nil
        return Button {
            withAnimation(theme.motion.quick) {
                selection = segment.value
            }
        } label: {
            HStack(spacing: theme.catalogLayoutMetric("component.library.42.elements.layout.sidebarLensBar.segmentButton.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(42, "gap", 5, theme))) {
                if let icon = segment.icon {
                    Image(systemName: icon)
                        .glyphSize(10, weight: .semibold)
                }
                if showsLabel {
                    Text(segment.label, bundle: .module)
                        .componentInspectionText(42, role: .caption, fallback: .footnote, weight: isSelected ? 600 : 500, theme: theme)
                        .lineLimit(1)
                }
                if let badge = segment.badge, badge > 0 {
                    Text(badge > 99 ? "99+" : "\(badge)")
                        .catalogTypography(.caption, theme: theme, fallback: SettingsFont.chip)
                        .foregroundColor(isSelected ? theme.text.primary : theme.text.secondary)
                        .padding(.horizontal, theme.catalogLayoutMetric("component.library.42.elements.layout.sidebarLensBar.segmentButton.paddingX", inheriting: NativeComponentInspectionStyle.metric(42, "padding", 5, theme))).catalogLayoutTarget("component.library.42.elements.layout.sidebarLensBar.segmentButton.paddingX")
                        .padding(.vertical, 1)
                        .background(Capsule().fill(isSelected ? theme.surface.pressed : theme.surface.subtle))
                        .accessibilityHidden(true)
                }
            }.catalogLayoutTarget("component.library.42.elements.layout.sidebarLensBar.segmentButton.horizontalGap")
            .foregroundColor(isSelected ? theme.text.primary : theme.text.secondary)
            // Breathing room the full labels must also fit, so the bar
            // goes compact before labels touch their neighbours.
            .padding(.horizontal, theme.catalogLayoutMetric("component.library.42.elements.layout.sidebarLensBar.segmentButton.paddingX2", inheriting: NativeComponentInspectionStyle.metric(42, "padding", compact ? 4 : 8, theme))).catalogLayoutTarget("component.library.42.elements.layout.sidebarLensBar.segmentButton.paddingX2")
            .frame(maxWidth: .infinity)
            .padding(.vertical, theme.catalogLayoutMetric("component.library.42.elements.layout.sidebarLensBar.segmentButton.paddingY", inheriting: NativeComponentInspectionStyle.metric(42, "padding", 5, theme))).catalogLayoutTarget("component.library.42.elements.layout.sidebarLensBar.segmentButton.paddingY")
            .background(
                RoundedRectangle(cornerRadius: theme.radius.small, style: .continuous)
                    .fill(isSelected ? theme.surface.selected : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: theme.radius.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(minHeight: NativeComponentInspectionStyle.metric(42, "height", 0, theme))
        .pointingHandCursor()
        .help(showsLabel ? Text(verbatim: "") : Text(segment.label, bundle: .module))
        .accessibilityLabel(segment.accessibilityLabel ?? Text(segment.label, bundle: .module))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Lays its children out in equal-width columns. Its ideal width is the
/// widest child's ideal times the count, so `ViewThatFits` only picks it
/// when every child fits at that shared width. The `wholeIndex` child
/// never gets less than its ideal width; when the equal share is too
/// narrow for it, the others split what is left.
private struct SidebarEqualWidthRow: Layout {
    var spacing: CGFloat
    var wholeIndex: Int? = nil

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let gaps = spacing * CGFloat(subviews.count - 1)
        let ideal = (sizes.map(\.width).max() ?? 0) * CGFloat(subviews.count) + gaps
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? ideal
        return CGSize(width: width, height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let gaps = spacing * CGFloat(subviews.count - 1)
        let available = max(0, bounds.width - gaps)
        let share = available / CGFloat(subviews.count)
        var widths = Array(repeating: share, count: subviews.count)
        if let wholeIndex, subviews.indices.contains(wholeIndex), subviews.count > 1 {
            let whole = min(available, subviews[wholeIndex].sizeThatFits(.unspecified).width)
            if whole > share {
                let rest = (available - whole) / CGFloat(subviews.count - 1)
                widths = widths.indices.map { $0 == wholeIndex ? whole : rest }
            }
        }
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths) {
            subview.place(
                at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}

// MARK: - Sidebar Header Icon Button

/// Plain symbol button for a rail's header row (New Agent, New Project,
/// Import, Revert All): no chrome, `secondaryText` unless a tint is given,
/// pointing-hand cursor and a tooltip. One control on both rails.
struct SidebarHeaderIconButton: View {
    let icon: String
    let help: LocalizedStringKey
    var tint: Color? = nil
    var size: CGFloat = 13
    var label: LocalizedStringKey? = nil
    let action: () -> Void

    @Environment(\.theme) private var environmentTheme
    @Environment(\.isEnabled) private var componentEnabled
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(42, enabled: componentEnabled, authoritative: true) }
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: theme.catalogLayoutMetric("component.library.42.elements.layout.sidebarHeaderIconButton.body.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(42, "gap", 4, theme))) {
                Image(systemName: icon)
                    .glyphSize(size, weight: .medium)
                if let label {
                    Text(label, bundle: .module)
                        .font(SettingsFont.smallLabel)
                }
            }.catalogLayoutTarget("component.library.42.elements.layout.sidebarHeaderIconButton.body.horizontalGap")
            .foregroundColor(tint ?? theme.text.secondary)
            .opacity(isEnabled ? 1 : 0.45)
            // Pad the hit target beyond the glyph without adding chrome.
            .padding(.horizontal, theme.catalogLayoutMetric("component.library.42.elements.layout.sidebarHeaderIconButton.body.paddingX", inheriting: NativeComponentInspectionStyle.metric(42, "padding", 4, theme))).catalogLayoutTarget("component.library.42.elements.layout.sidebarHeaderIconButton.body.paddingX")
            .padding(.vertical, theme.catalogLayoutMetric("component.library.42.elements.layout.sidebarHeaderIconButton.body.paddingY", inheriting: NativeComponentInspectionStyle.metric(42, "padding", 4, theme))).catalogLayoutTarget("component.library.42.elements.layout.sidebarHeaderIconButton.body.paddingY")
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .localizedHelp(help)
    }
}

// MARK: - Sidebar Filter Chip

// MARK: - Sidebar Empty State

/// The rails' one empty-state idiom: a light symbol, a short title and an
/// optional one-line hint, centred in the space the list would fill.
struct SidebarEmptyState: View {
    let icon: String
    let title: LocalizedStringKey
    var hint: LocalizedStringKey? = nil

    @Environment(\.theme) private var environmentTheme
    @Environment(\.isEnabled) private var componentEnabled
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(42, enabled: componentEnabled, authoritative: true) }

    var body: some View {
        VStack(spacing: theme.catalogLayoutMetric("component.library.42.elements.layout.sidebarEmptyState.body.verticalGap", inheriting: NativeComponentInspectionStyle.metric(42, "gap", 8, theme))) {
            Spacer()
            Image(systemName: icon)
                .glyphSize(28, weight: .light)
                .foregroundColor(theme.text.tertiary)
            Text(title, bundle: .module)
                .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                .foregroundColor(theme.text.secondary)
            if let hint {
                Text(hint, bundle: .module)
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                    .foregroundColor(theme.text.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }.catalogLayoutTarget("component.library.42.elements.layout.sidebarEmptyState.body.verticalGap")
        .frame(maxWidth: .infinity)
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.42.elements.layout.sidebarEmptyState.body.paddingX", inheriting: NativeComponentInspectionStyle.metric(42, "padding", 24, theme))).catalogLayoutTarget("component.library.42.elements.layout.sidebarEmptyState.body.paddingX")
    }
}

// MARK: - Sidebar Header Row

/// The row under a rail's lens bar: an optional one-line summary on the
/// left ("2 files changed · 3 changes", "Content Writer · 12 chats") and
/// the pane's `SidebarHeaderIconButton`s on the right. Same paddings as
/// the left rail's header so the two rails line up.
struct SidebarHeaderRow<Actions: View>: View {
    var summary: String? = nil
    var compact: Bool = false
    @ViewBuilder let actions: () -> Actions

    @Environment(\.theme) private var environmentTheme
    @Environment(\.isEnabled) private var componentEnabled
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(42, enabled: componentEnabled, authoritative: true) }

    var body: some View {
        HStack(spacing: theme.catalogLayoutMetric("component.library.42.elements.layout.sidebarHeaderRow.body.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(42, "gap", 4, theme))) {
            if let summary, !summary.isEmpty {
                Text(summary)
                    .catalogTypography(compact ? .caption : .body, theme: theme, fallback: SettingsFont.rowDescription)
                    .foregroundColor(compact ? theme.text.tertiary : theme.text.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Compact agent headers align with the agent row text inset.
                    .padding(.leading, compact ? 0 : 4)
            }
            Spacer(minLength: 8)
            actions()
        }.catalogLayoutTarget("component.library.42.elements.layout.sidebarHeaderRow.body.horizontalGap")
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.42.elements.layout.sidebarHeaderRow.body.paddingX", inheriting: NativeComponentInspectionStyle.metric(42, "padding", 12, theme))).catalogLayoutTarget("component.library.42.elements.layout.sidebarHeaderRow.body.paddingX")
        .padding(.top, compact ? 0 : 2)
        .padding(.bottom, compact ? 0 : 8)
        // Constant height whether or not a pane has actions, so the list
        // below starts at the same y on every pane.
        .frame(minHeight: NativeComponentInspectionStyle.metric(42, "height", 32, theme))
    }
}

// MARK: - Sidebar Title Row

/// The top row of a rail that has one pane rather than lenses ("Project
/// Settings"): a 13pt title where the lens bar would sit, optional actions
/// on the right. Same vertical insets as `SidebarLensBar`'s row so the two
/// kinds of rail start their content at the same y.
struct SidebarTitleRow<Actions: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let actions: () -> Actions

    @Environment(\.theme) private var environmentTheme
    @Environment(\.isEnabled) private var componentEnabled
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(42, enabled: componentEnabled, authoritative: true) }

    init(_ title: LocalizedStringKey, @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }) {
        self.title = title
        self.actions = actions
    }

    var body: some View {
        HStack(spacing: theme.catalogLayoutMetric("component.library.42.elements.layout.sidebarTitleRow.body.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(42, "gap", 4, theme))) {
            Text(title, bundle: .module)
                .catalogTypography(.heading, theme: theme, fallback: SettingsFont.sectionTitle)
                .foregroundColor(theme.text.primary)
                .lineLimit(1)
                .padding(.leading, 4)
            Spacer(minLength: 8)
            actions()
        }.catalogLayoutTarget("component.library.42.elements.layout.sidebarTitleRow.body.horizontalGap")
        .frame(minHeight: NativeComponentInspectionStyle.metric(42, "height", 30, theme))
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.42.elements.layout.sidebarTitleRow.body.paddingX", inheriting: NativeComponentInspectionStyle.metric(42, "padding", 12, theme))).catalogLayoutTarget("component.library.42.elements.layout.sidebarTitleRow.body.paddingX")
        .padding(.top, 16)
        .padding(.bottom, 12)
    }
}

// MARK: - Column Resize Handle

/// Draggable divider on a rail's inner edge. A thin visible seam with a
/// wider invisible hit area straddling the boundary; dragging resizes the
/// rail and the two-headed cursor telegraphs that it's grabbable. The
/// left rail uses `.trailing` (drag right widens), the right rail
/// `.leading` (drag left widens).
struct ColumnResizeHandle: View {
    let edge: HorizontalEdge
    let range: ClosedRange<Double>
    @Binding var storedWidth: Double
    @Binding var liveWidth: Double?
    var accessibilityLabel: String?
    /// Double-clicking the divider calls this, when set.
    var onReset: (() -> Void)?
    @Environment(\.theme) private var theme
    @State private var isHovering = false

    var body: some View {
        // Native cursor rectangles own a stable 16pt grab zone. Drag deltas
        // use window coordinates, independent of the divider's moving frame.
        NativeColumnResizeHandle(edge: edge, range: range,
                                 storedWidth: $storedWidth, liveWidth: $liveWidth, isHovering: $isHovering,
                                 accessibilityLabel: accessibilityLabel, onReset: onReset)
            .frame(width: 16)
            .frame(maxHeight: .infinity)
            .overlay {
                Rectangle()
                    .fill(isHovering || liveWidth != nil ? theme.border.default : .clear)
                    .frame(width: theme.stroke.default)
                    .allowsHitTesting(false)
            }
            .offset(x: edge == .trailing ? 8 : -8)
    }
}

private struct NativeColumnResizeHandle: NSViewRepresentable {
    let edge: HorizontalEdge
    let range: ClosedRange<Double>
    @Binding var storedWidth: Double
    @Binding var liveWidth: Double?
    @Binding var isHovering: Bool
    let accessibilityLabel: String?
    let onReset: (() -> Void)?

    func makeNSView(context: Context) -> ResizeView { ResizeView() }
    func updateNSView(_ view: ResizeView, context: Context) {
        view.width = liveWidth ?? storedWidth
        view.range = range
        view.direction = edge == .trailing ? 1 : -1
        view.onChange = { liveWidth = $0 }
        view.onEnd = { width, moved in
            if moved { storedWidth = width }
            liveWidth = nil
        }
        view.onHover = { isHovering = $0 }
        view.onReset = onReset
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.splitter)
        view.setAccessibilityLabel(accessibilityLabel ?? (edge == .trailing ? "Resize sidebar" : "Resize inspector"))
        view.setAccessibilityValue(NSNumber(value: view.width))
        view.window?.invalidateCursorRects(for: view)
    }

    final class ResizeView: NSView {
        var width: Double = 240
        var range: ClosedRange<Double> = 240...460
        var direction: Double = 1
        var onChange: ((Double) -> Void)?
        /// The width at release, and whether the drag changed it.
        var onEnd: ((Double, Bool) -> Void)?
        var onHover: ((Bool) -> Void)?
        var onReset: (() -> Void)?
        private var hoverArea: NSTrackingArea?
        private var pointerInside = false
        private var anchorX: CGFloat = 0
        private var anchorWidth: Double = 0
        private var dragWidth: Double?
        private weak var draggingWindow: NSWindow?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverArea { removeTrackingArea(hoverArea) }
            let area = NSTrackingArea(rect: .zero,
                options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                owner: self, userInfo: nil)
            addTrackingArea(area)
            hoverArea = area
        }
        private func setHover(_ inside: Bool) {
            guard pointerInside != inside else { return }
            pointerInside = inside
            onHover?(inside)
        }
        override func mouseEntered(with event: NSEvent) {
            setHover(true)
            NSCursor.resizeLeftRight.set()
        }
        override func mouseExited(with event: NSEvent) { setHover(false) }
        override func cursorUpdate(with event: NSEvent) {
            setHover(true)
            NSCursor.resizeLeftRight.set()
        }
        override func mouseDown(with event: NSEvent) {
            setHover(true)
            if event.clickCount == 2, let onReset {
                onReset()
                return
            }
            anchorX = event.locationInWindow.x
            anchorWidth = width
            dragWidth = width
            draggingWindow = window
            window?.disableCursorRects()
            NSCursor.resizeLeftRight.set()
            onChange?(width)
        }
        override func mouseDragged(with event: NSEvent) {
            guard dragWidth != nil else { return }
            let proposed = anchorWidth + direction * Double(event.locationInWindow.x - anchorX)
            let clamped = min(max(proposed, range.lowerBound), range.upperBound)
            dragWidth = clamped
            NSCursor.resizeLeftRight.set()
            onChange?(clamped)
        }
        override func mouseUp(with event: NSEvent) {
            setHover(bounds.contains(convert(event.locationInWindow, from: nil)))
            finishDrag()
        }
        override func cancelOperation(_ sender: Any?) { finishDrag() }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { setHover(false); finishDrag() }
            super.viewWillMove(toWindow: newWindow)
        }
        private func finishDrag() {
            guard let value = dragWidth else { return }
            dragWidth = nil
            draggingWindow?.enableCursorRects()
            draggingWindow?.invalidateCursorRects(for: self)
            draggingWindow = nil
            onEnd?(value, value != anchorWidth)
        }
    }
}

// MARK: - Sidebar Search Field

/// Themed search field for sidebar filtering.
struct SidebarSearchField: View {
    @Binding var text: String
    let placeholder: LocalizedStringKey
    var isFocused: FocusState<Bool>.Binding
    /// Shows a small trailing spinner while an asynchronous search pass
    /// (e.g. the chat sidebar's full-text conversation lookup) is in flight.
    var isSearching: Bool = false
    /// Draw a subtle border while unfocused too (the project page uses this
    /// to match its dropdown chrome); the sidebar keeps the borderless look.
    var showsRestingBorder: Bool = false

    @Environment(\.theme) private var environmentTheme
    @Environment(\.isEnabled) private var componentEnabled
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(42, enabled: componentEnabled, authoritative: true) }

    #if OSAURUS_DESIGN_SYSTEM
    @State private var inspectorComposing = false
    #endif
    var body: some View {
        HStack(spacing: theme.catalogLayoutMetric("component.library.42.elements.layout.sidebarSearchField.body.horizontalGap", inheriting: NativeComponentInspectionStyle.metric(42, "gap", 8, theme))) {
            searchIcon
            searchTextField
            if isSearching {
                ProgressView()
                    .assignedProgressIndicator()
                    .controlSize(.mini)
                    .frame(width: 12, height: 12)
                    .transition(.opacity)
            }
            clearButton
        }.catalogLayoutTarget("component.library.42.elements.layout.sidebarSearchField.body.horizontalGap")
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.42.elements.layout.sidebarSearchField.body.padding.horizontal", inheriting: NativeComponentInspectionStyle.metric(42, "padding", 8, theme))).padding(.vertical, theme.catalogLayoutMetric("component.library.42.elements.layout.sidebarSearchField.body.padding.vertical", inheriting: NativeComponentInspectionStyle.metric(42, "padding", 8, theme))).catalogLayoutTarget("component.library.42.elements.layout.sidebarSearchField.body.padding.horizontal").catalogLayoutTarget("component.library.42.elements.layout.sidebarSearchField.body.padding.vertical")
        .frame(minHeight: NativeComponentInspectionStyle.metric(42, "height", 30, theme))
        .background(fieldBackground)
        .overlay(focusBorder)
        .animation(theme.motion.quick, value: isFocused.wrappedValue)
        .animation(theme.motion.quick, value: text.isEmpty)
        .animation(theme.motion.quick, value: isSearching)
    }

    private var searchIcon: some View {
        Image(systemName: "magnifyingglass")
            .glyphSize(12, weight: .medium)
            .foregroundColor(isFocused.wrappedValue ? theme.text.primary : theme.text.secondary)
    }

    private var searchTextField: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty {
                Text(localized: placeholder)
                    .componentInspectionText(42, role: .label, fallback: .label, theme: theme)
                    .foregroundColor(theme.text.placeholder)
            }
            #if OSAURUS_DESIGN_SYSTEM
            InspectorAssignedTextField(text: $text, isComposing: $inspectorComposing,
                font: theme.assignedNativeFont(NativeComponentInspectionStyle.key(42, "label"), fallback: theme.nsFont(.label)),
                textColor: NSColor(theme.text.primary), onSubmit: nil,
                onFocusChange: { isFocused.wrappedValue = $0 },
                tracking: theme.assignedTracking(NativeComponentInspectionStyle.key(42, "label")),
                editable: componentEnabled, requestedFocus: isFocused.wrappedValue,
                onCommand: { selector in
                    guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
                    clearAndResign()
                    return true
                })
            #else
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .componentInspectionText(42, role: .caption, fallback: .caption, theme: theme)
                .foregroundColor(theme.text.primary)
                .focused(isFocused)
                .onExitCommand(perform: clearAndResign)
            #endif
        }
    }

    /// Escape: empties the query and gives up focus.
    private func clearAndResign() {
        text = ""
        isFocused.wrappedValue = false
    }

    @ViewBuilder
    private var clearButton: some View {
        if !text.isEmpty {
            Button {
                withAnimation(theme.motion.quick) {
                    text = ""
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .glyphSize(12)
                    .foregroundColor(theme.text.secondary)
            }
            .buttonStyle(.plain)
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
            .fill(theme.surface.raised)
    }

    private var focusBorder: some View {
        RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
            .stroke(
                isFocused.wrappedValue
                    ? theme.border.focus
                    : (showsRestingBorder ? theme.border.subtle : .clear),
                lineWidth: isFocused.wrappedValue ? theme.stroke.focus : theme.stroke.default)
    }
}

// MARK: - Sidebar No Results View

/// View displayed when search yields no results.
struct SidebarNoResultsView: View {
    let searchQuery: String
    let onClear: () -> Void

    @Environment(\.theme) private var environmentTheme
    @Environment(\.isEnabled) private var componentEnabled
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(42, enabled: componentEnabled, authoritative: true) }

    var body: some View {
        VStack(spacing: theme.catalogLayoutMetric("component.library.42.elements.layout.sidebarNoResultsView.body.verticalGap", inheriting: NativeComponentInspectionStyle.metric(42, "gap", 12, theme))) {
            Spacer()

            Image(systemName: "magnifyingglass")
                .glyphSize(24, weight: .light)
                .foregroundColor(theme.text.disabled)

            VStack(spacing: theme.catalogLayoutMetric("component.library.42.elements.layout.sidebarNoResultsView.body.verticalGap2", inheriting: NativeComponentInspectionStyle.metric(42, "gap", 4, theme))) {
                Text("No matches found", bundle: .module)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.compactLabel)
                    .foregroundColor(theme.text.secondary)

                Text("for \"\(searchQuery)\"", bundle: .module)
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }.catalogLayoutTarget("component.library.42.elements.layout.sidebarNoResultsView.body.verticalGap2")

            Button(action: onClear) {
                Text("Clear search", bundle: .module)
            }
            .assignedSettingsButtonStyle(.secondary, size: .compact)

            Spacer()
        }.catalogLayoutTarget("component.library.42.elements.layout.sidebarNoResultsView.body.verticalGap")
        .frame(maxWidth: .infinity)
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.42.elements.layout.sidebarNoResultsView.body.paddingX", inheriting: NativeComponentInspectionStyle.metric(42, "padding", 16, theme))).catalogLayoutTarget("component.library.42.elements.layout.sidebarNoResultsView.body.paddingX")
    }
}

// MARK: - Sidebar Row Action Button

/// Small action button for sidebar rows (delete, rename, etc.).
struct SidebarRowActionButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    @Environment(\.theme) private var environmentTheme
    @Environment(\.isEnabled) private var componentEnabled
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(41, enabled: componentEnabled, authoritative: true) }
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .glyphSize(12, weight: .semibold)
                .foregroundColor(
                    isHovered ? theme.text.primary : theme.text.secondary
                )
                .frame(width: NativeComponentInspectionStyle.metric(41, "height", SidebarStyle.actionButtonSize, theme), height: NativeComponentInspectionStyle.metric(41, "height", SidebarStyle.actionButtonSize, theme))
                .settingsChrome(isHovered ? .hover : nil)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(LocalizedStringKey(help), bundle: .module))
        .onHover { isHovered = $0 }
        .animation(theme.motion.quick, value: isHovered)
        .environment(\.theme, theme)
    }
}

// MARK: - Sidebar Row Background

/// Flat row background (`component.sidebar.row`): `surface.selected` +
/// `border.default` when selected, `surface.hover` while hovered, nothing at
/// rest. `radius.medium`.
struct SidebarRowBackground: View {
    let isSelected: Bool
    let isHovered: Bool
    var family = 41
    var compactChatStyle = false

    @Environment(\.theme) private var environmentTheme
    @Environment(\.isEnabled) private var componentEnabled
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(family, enabled: componentEnabled, authoritative: true) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
        shape
            .fill(fill)
            .overlay(shape.strokeBorder(isSelected && !compactChatStyle ? theme.border.default : .clear, lineWidth: theme.stroke.default))
    }

    private var fill: Color {
        if !componentEnabled { return theme.surface.disabled }
        if compactChatStyle { return isSelected || isHovered ? theme.surface.hover : .clear }
        if isSelected { return theme.surface.selected }
        if isHovered { return theme.surface.hover }
        return theme.assignedColor(NativeComponentInspectionStyle.key(family, "background"), fallback: .clear)
    }
}

/// Paints `SidebarRowBackground` behind a row and clips + hit-tests the row
/// to `radius.medium`. No gesture of its own: a press-tracking gesture here
/// swallows the clicks of the row's tap handler and of buttons inside it.
private struct SidebarRowChromeModifier: ViewModifier {
    @Environment(\.theme) private var environmentTheme
    @Environment(\.isEnabled) private var componentEnabled
    private var theme: any ThemeProtocol { environmentTheme.catalogFamily(family, enabled: componentEnabled, authoritative: true) }
    let isSelected: Bool
    let isHovered: Bool
    var family = 41
    var compactChatStyle = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
        content
            .background(SidebarRowBackground(isSelected: isSelected, isHovered: isHovered, family: family, compactChatStyle: compactChatStyle))
            .clipShape(shape)
            .contentShape(shape)
    }
}

extension View {
    /// The sidebar row surface with hover and selected states.
    func sidebarRowChrome(isSelected: Bool, isHovered: Bool, family: Int = 41, compactChatStyle: Bool = false) -> some View {
        modifier(SidebarRowChromeModifier(isSelected: isSelected, isHovered: isHovered, family: family, compactChatStyle: compactChatStyle))
    }
}

// MARK: - Utilities

// shared instance — initialised once; only localizedString(for:relativeTo:) is called on it,
// which does not mutate the formatter. nonisolated(unsafe) silences the Sendable warning.
nonisolated(unsafe) private let _sharedRelativeDateFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f
}()

/// Formats a date as a relative time string (e.g., "2h ago", "yesterday").
func formatRelativeDate(_ date: Date) -> String {
    _sharedRelativeDateFormatter.localizedString(for: date, relativeTo: Date())
}

nonisolated(unsafe) private let _sharedCompactAgeFormatter = makeCompactAgeFormatter(locale: .current)

private func makeCompactAgeFormatter(locale: Locale) -> DateComponentsFormatter {
    let f = DateComponentsFormatter()
    var calendar = Calendar.current
    calendar.locale = locale
    f.calendar = calendar
    f.unitsStyle = .abbreviated
    f.maximumUnitCount = 1
    f.allowedUnits = [.year, .month, .day, .hour, .minute]
    return f
}

/// Formats a date as the single-unit age a sidebar row has room for
/// ("Now", "5m", "3h", "12d", "3mo"). `locale` is for tests; nil
/// uses the shared current-locale formatter.
func compactRelativeAge(_ date: Date, now: Date = Date(), locale: Locale? = nil) -> String {
    guard now.timeIntervalSince(date) >= 60 else { return L("Now") }
    let formatter = locale.map(makeCompactAgeFormatter) ?? _sharedCompactAgeFormatter
    // The formatter rounds its one unit (80 days reads "3mo"); keep only
    // the largest whole unit so an age never reads older than it is.
    let units: [Calendar.Component] = [.year, .month, .day, .hour, .minute]
    let parts = formatter.calendar!.dateComponents(Set(units), from: date, to: now)
    guard let unit = units.first(where: { (parts.value(for: $0) ?? 0) > 0 }) else { return L("Now") }
    var largest = DateComponents()
    largest.setValue(parts.value(for: unit), for: unit)
    return formatter.string(from: largest) ?? formatRelativeDate(date)
}
