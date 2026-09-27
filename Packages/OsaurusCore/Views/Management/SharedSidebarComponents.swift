//
//  SharedSidebarComponents.swift
//  osaurus
//
//  Shared components for chat session sidebars.
//

import SwiftUI

// MARK: - Sidebar Style Constants

/// Centralized styling constants for sidebar components (similar to ToastStyle).
enum SidebarStyle {
    // MARK: Layout
    static let width: CGFloat = 240
    static let cornerRadius: CGFloat = 14
    static let rowCornerRadius: CGFloat = 8
    static let searchFieldCornerRadius: CGFloat = 8
    static let actionButtonSize: CGFloat = 24
    static let actionButtonCornerRadius: CGFloat = 5

    // MARK: Glass Background
    static let glassOpacityDark: Double = 0.82
    static let glassOpacityLight: Double = 0.90

    // MARK: Accent Gradient
    static let accentGradientOpacityDark: Double = 0.06
    static let accentGradientOpacityLight: Double = 0.04

    // MARK: Border
    static let edgeLightOpacityDark: Double = 0.18
    static let edgeLightOpacityLight: Double = 0.28
    static let borderOpacityDark: Double = 0.14
    static let borderOpacityLight: Double = 0.22

    // MARK: Accent Edge
    static let accentEdgeHoverOpacity: Double = 0.18
    static let accentEdgeNormalOpacity: Double = 0.10
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

    @ViewBuilder let content: () -> Content
    @Environment(\.theme) private var theme

    init(
        attachedEdge: Edge? = nil,
        topPadding: CGFloat = 0,
        width: CGFloat = SidebarStyle.width,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.attachedEdge = attachedEdge
        self.topPadding = topPadding
        self.width = width
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .padding(.top, topPadding)
        .frame(width: width, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .background { SidebarBackground() }
        .clipShape(containerShape)
        .overlay(SidebarBorder(attachedEdge: attachedEdge))
    }

    private var containerShape: UnevenRoundedRectangle {
        let radius = SidebarStyle.cornerRadius
        switch attachedEdge {
        case .leading:
            // Attached to leading edge - round only leading corners
            return UnevenRoundedRectangle(
                topLeadingRadius: radius,
                bottomLeadingRadius: radius,
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

/// Glass-based background for sidebar with accent gradient (similar to ToastBackground).
struct SidebarBackground: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            // Layer 0: NSVisualEffectView-backed glass, only when the
            // sidebar's own glass toggle is on. Outer container clips to
            // the sidebar's rounded shape, so a plain rectangle is fine here.
            if theme.glassSidebarEnabled {
                ThemedGlassSurface(cornerRadius: SidebarStyle.cornerRadius)
            }

            // Layer 1: Semi-transparent card background. Lower opacity when
            // the sidebar's own glass toggle is on so the behind-window
            // material shows through.
            theme.cardBackground.opacity(
                theme.glassSidebarEnabled
                    ? (theme.isDark ? SidebarStyle.glassOpacityDark : SidebarStyle.glassOpacityLight)
                    : 1.0
            )

            // Layer 2: Accent gradient for visual polish
            LinearGradient(
                colors: [
                    theme.accentColor.opacity(
                        theme.isDark ? SidebarStyle.accentGradientOpacityDark : SidebarStyle.accentGradientOpacityLight
                    ),
                    Color.clear,
                    theme.primaryBackground.opacity(theme.isDark ? 0.06 : 0.03),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

// MARK: - Sidebar Border

/// Gradient border with accent edge highlight for sidebar (similar to ToastBorder)
struct SidebarBorder: View {
    @Environment(\.theme) private var theme

    let attachedEdge: Edge?

    init(attachedEdge: Edge? = nil) {
        self.attachedEdge = attachedEdge
    }

    var body: some View {
        borderShape
            .strokeBorder(
                LinearGradient(
                    colors: [
                        theme.glassEdgeLight.opacity(
                            theme.isDark ? SidebarStyle.edgeLightOpacityDark : SidebarStyle.edgeLightOpacityLight
                        ),
                        theme.primaryBorder.opacity(
                            theme.isDark ? SidebarStyle.borderOpacityDark : SidebarStyle.borderOpacityLight
                        ),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
            .overlay(accentEdge)
    }

    private var borderShape: UnevenRoundedRectangle {
        let radius = SidebarStyle.cornerRadius
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

    private var accentEdge: some View {
        borderShape
            .strokeBorder(
                theme.accentColor.opacity(SidebarStyle.accentEdgeNormalOpacity),
                lineWidth: 1
            )
            .mask(
                LinearGradient(
                    colors: [Color.white, Color.white.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }
}

// MARK: - Sidebar Lens Bar

/// Equal-width segmented lens switcher that opens every rail (Agents |
/// Projects on the left, File Changes | History on the right). Each
/// segment is the whole padded rectangle as a hit target, accent-tinted
/// when selected, with an optional count badge. Views within a pane use
/// `SidebarFilterChip`s, one level below.
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

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                segmentButton(segment)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.secondaryBackground.opacity(theme.isDark ? 0.4 : 0.5))
        )
    }

    private func segmentButton(_ segment: Segment) -> some View {
        let isSelected = selection == segment.value
        return Button {
            withAnimation(theme.animationQuick()) {
                selection = segment.value
            }
        } label: {
            HStack(spacing: 5) {
                if let icon = segment.icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(segment.label, bundle: .module)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                if let badge = segment.badge, badge > 0 {
                    Text(badge > 99 ? "99+" : "\(badge)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(
                                (isSelected ? theme.accentColor : theme.secondaryText)
                                    .opacity(theme.isDark ? 0.22 : 0.14))
                        )
                        .accessibilityHidden(true)
                }
            }
            .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? theme.accentColor.opacity(theme.isDark ? 0.28 : 0.18) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .accessibilityLabel(segment.accessibilityLabel ?? Text(segment.label, bundle: .module))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: size, weight: .medium))
                if let label {
                    Text(label, bundle: .module)
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .foregroundColor(tint ?? theme.secondaryText)
            .opacity(isEnabled ? 1 : 0.45)
            // Pad the hit target beyond the glyph without adding chrome.
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .localizedHelp(help)
    }
}

// MARK: - Sidebar Filter Chip

/// Pane-level toggle in the rails' chip idiom: a capsule, ghost when off
/// (hover tints it), accent-tinted when on. One level below the lens bar:
/// lenses change what a rail lists, chips narrow or re-sort it.
struct SidebarFilterChip: View {
    let label: LocalizedStringKey
    var icon: String? = nil
    var iconOn: String? = nil
    let isOn: Bool
    var help: LocalizedStringKey? = nil
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        let shape = Capsule(style: .continuous)
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: isOn ? (iconOn ?? icon) : icon)
                        .font(.system(size: 9.5, weight: .semibold))
                }
                Text(label, bundle: .module)
                    .font(.system(size: 11, weight: isOn ? .semibold : .medium))
            }
            .foregroundColor(isOn ? theme.accentColor : theme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                shape.fill(
                    isOn
                        ? theme.accentColor.opacity(theme.isDark ? 0.28 : 0.18)
                        : (isHovered ? theme.secondaryBackground.opacity(0.5) : Color.clear)
                )
            )
            .contentShape(shape)
            .pointingHandCursor()
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .modifier(OptionalHelp(help: help))
    }

    private struct OptionalHelp: ViewModifier {
        let help: LocalizedStringKey?
        func body(content: Content) -> some View {
            if let help { content.localizedHelp(help) } else { content }
        }
    }
}

// MARK: - Sidebar Empty State

/// The rails' one empty-state idiom: a light symbol, a short title and an
/// optional one-line hint, centred in the space the list would fill.
struct SidebarEmptyState: View {
    let icon: String
    let title: LocalizedStringKey
    var hint: LocalizedStringKey? = nil

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundColor(theme.secondaryText.opacity(0.5))
            Text(title, bundle: .module)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
            if let hint {
                Text(hint, bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }
}

// MARK: - Sidebar Header Row

/// The row under a rail's lens bar: an optional one-line summary on the
/// left ("2 files changed · 3 changes", "Content Writer · 12 chats") and
/// the pane's `SidebarHeaderIconButton`s on the right. Same paddings as
/// the left rail's header so the two rails line up.
struct SidebarHeaderRow<Actions: View>: View {
    var summary: String? = nil
    @ViewBuilder let actions: () -> Actions

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            if let summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Optically aligned with the lens bar's inner edge.
                    .padding(.leading, 4)
            }
            Spacer(minLength: 8)
            actions()
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 8)
        // Constant height whether or not a pane has actions, so the list
        // below starts at the same y on every pane.
        .frame(minHeight: 32)
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

    @Environment(\.theme) private var theme

    init(_ title: LocalizedStringKey, @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }) {
        self.title = title
        self.actions = actions
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(title, bundle: .module)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)
                .padding(.leading, 4)
            Spacer(minLength: 8)
            actions()
        }
        .frame(minHeight: 30)
        .padding(.horizontal, 12)
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
    /// Which edge of the rail this handle sits on.
    let edge: HorizontalEdge
    /// Allowed rail widths.
    let range: ClosedRange<Double>
    /// Persisted width; committed on release.
    @Binding var storedWidth: Double
    /// Width while a drag is in flight (nil at rest).
    @Binding var liveWidth: Double?

    @Environment(\.theme) private var theme
    @State private var dragAnchor: Double?

    private func clamp(_ raw: Double) -> Double {
        min(max(raw, range.lowerBound), range.upperBound)
    }

    var body: some View {
        // An 11pt-wide interactive strip; the offset pushes half of it past
        // the border so the seam is grabbable right at the boundary. The
        // visible seam is a 1pt line at the strip's center.
        Color.clear
            .frame(width: 11)
            .frame(maxHeight: .infinity)
            .overlay {
                Rectangle()
                    .fill(theme.secondaryText.opacity(liveWidth != nil ? 0.55 : 0.12))
                    .frame(width: 1)
            }
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .offset(x: edge == .trailing ? 5 : -5)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        // Anchor to the width at gesture start so the rail
                        // tracks the cursor 1:1 without accumulating drift.
                        let anchor = dragAnchor ?? clamp(liveWidth ?? storedWidth)
                        if dragAnchor == nil {
                            dragAnchor = anchor
                        }
                        let delta = Double(value.translation.width)
                        liveWidth = clamp(anchor + (edge == .trailing ? delta : -delta))
                    }
                    .onEnded { _ in
                        if let final = liveWidth {
                            storedWidth = clamp(final)
                        }
                        liveWidth = nil
                        dragAnchor = nil
                    }
            )
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

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            searchIcon
            searchTextField
            if isSearching {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 12, height: 12)
                    .transition(.opacity)
            }
            clearButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(fieldBackground)
        .overlay(focusBorder)
        .animation(theme.animationQuick(), value: isFocused.wrappedValue)
        .animation(theme.animationQuick(), value: text.isEmpty)
        .animation(theme.animationQuick(), value: isSearching)
    }

    private var searchIcon: some View {
        Image(systemName: "magnifyingglass")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(isFocused.wrappedValue ? theme.primaryText : theme.secondaryText.opacity(0.7))
    }

    private var searchTextField: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty {
                Text(localized: placeholder)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText.opacity(0.7))
            }
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(theme.primaryText)
                .focused(isFocused)
        }
    }

    @ViewBuilder
    private var clearButton: some View {
        if !text.isEmpty {
            Button {
                withAnimation(theme.animationQuick()) {
                    text = ""
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText.opacity(0.7))
            }
            .buttonStyle(.plain)
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: SidebarStyle.searchFieldCornerRadius, style: .continuous)
            .fill(theme.isDark ? theme.primaryBackground.opacity(0.5) : theme.tertiaryBackground.opacity(0.8))
    }

    private var focusBorder: some View {
        RoundedRectangle(cornerRadius: SidebarStyle.searchFieldCornerRadius, style: .continuous)
            .stroke(
                isFocused.wrappedValue
                    ? theme.accentColor.opacity(0.3)
                    : (showsRestingBorder ? theme.secondaryText.opacity(0.15) : .clear),
                lineWidth: 1)
    }
}

// MARK: - Sidebar No Results View

/// View displayed when search yields no results.
struct SidebarNoResultsView: View {
    let searchQuery: String
    let onClear: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "magnifyingglass")
                .font(.system(size: 24, weight: .light))
                .foregroundColor(theme.secondaryText.opacity(0.4))

            VStack(spacing: 4) {
                Text("No matches found", bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.secondaryText.opacity(0.8))

                Text("for \"\(searchQuery)\"", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Button(action: onClear) {
                Text("Clear search", bundle: .module)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.accentColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(theme.accentColor.opacity(0.1))
                    )
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
    }
}

// MARK: - Sidebar Row Action Button

/// Small action button for sidebar rows (delete, rename, etc.).
struct SidebarRowActionButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isHovered ? theme.accentColor : theme.secondaryText)
                .frame(width: SidebarStyle.actionButtonSize, height: SidebarStyle.actionButtonSize)
                .background(
                    RoundedRectangle(cornerRadius: SidebarStyle.actionButtonCornerRadius, style: .continuous)
                        .fill(isHovered ? theme.accentColor.opacity(0.1) : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: SidebarStyle.actionButtonCornerRadius, style: .continuous)
                        .strokeBorder(
                            isHovered ? theme.accentColor.opacity(0.2) : .clear,
                            lineWidth: 1
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(LocalizedStringKey(help), bundle: .module))
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}

// MARK: - Sidebar Row Background

/// Enhanced row background with glass effects and gradient borders (similar to ToastBackground styling).
struct SidebarRowBackground: View {
    let isSelected: Bool
    let isHovered: Bool

    @Environment(\.theme) private var theme

    private var cornerRadius: CGFloat { SidebarStyle.rowCornerRadius }

    var body: some View {
        ZStack {
            // Layer 1: Background fill with glass effect
            if isSelected || isHovered {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(backgroundColor)
            }

            // Layer 2: Accent gradient overlay for selected/hovered states
            if isSelected {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.accentColor.opacity(theme.isDark ? 0.12 : 0.08),
                                theme.accentColor.opacity(theme.isDark ? 0.04 : 0.02),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            } else if isHovered {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.primaryBackground.opacity(theme.isDark ? 0.08 : 0.04),
                                Color.clear,
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
        .overlay(borderOverlay)
    }

    private var backgroundColor: Color {
        if isSelected {
            return theme.accentColor.opacity(theme.isDark ? 0.15 : 0.12)
        } else if isHovered {
            return theme.secondaryBackground.opacity(theme.isDark ? 0.5 : 0.6)
        }
        return .clear
    }

    @ViewBuilder
    private var borderOverlay: some View {
        if isSelected {
            // Selected state: gradient border with accent highlight
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            theme.accentColor.opacity(theme.isDark ? 0.35 : 0.28),
                            theme.accentColor.opacity(theme.isDark ? 0.15 : 0.12),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
                .overlay(selectedAccentEdge)
        } else if isHovered {
            // Hovered state: subtle gradient border
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            theme.glassEdgeLight.opacity(theme.isDark ? 0.12 : 0.18),
                            theme.primaryBorder.opacity(theme.isDark ? 0.08 : 0.12),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
    }

    private var selectedAccentEdge: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
                theme.accentColor.opacity(SidebarStyle.accentEdgeHoverOpacity),
                lineWidth: 1
            )
            .mask(
                LinearGradient(
                    colors: [Color.white, Color.white.opacity(0)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
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
