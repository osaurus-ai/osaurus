//
//  ChatMinimap.swift
//  osaurus
//
//  Thin vertical minimap showing one row per user message. Collapsed,
//  each row is a short horizontal tick. On hover, the container grows
//  and each tick morphs into a vertical handle paired with a number
//  and single-line preview of the user message. Clicking a row scrolls
//  the thread to that turn.
//
//  Long conversations are height-capped in both states. The same rows are
//  kept across the hover so the tick-to-row morph survives: collapsed, the
//  ticks pack tighter to fit the cap; expanded, the list scrolls and opens
//  on the active row. Only past the densest legible tick spacing does each
//  collapsed tick stand for a group of messages (with a crossfade).
//

import SwiftUI

struct ChatMinimap: View {
    struct Marker: Identifiable, Equatable {
        /// Turn ID of the user message.
        let id: UUID
        let preview: String
    }

    let markers: [Marker]
    let activeMarkerId: UUID?
    /// Height of the area the minimap floats in. Both states cap to it
    /// (minus margins that keep clear of the top chrome and the
    /// scroll-to-bottom button).
    var availableHeight: CGFloat = .infinity
    let onSelect: (UUID) -> Void

    @Environment(\.theme) private var theme
    @State private var isExpanded: Bool = false

    private let expandAnimation = Animation.spring(response: 0.36, dampingFraction: 0.86)

    // MARK: - Metrics

    private enum Metrics {
        /// Space kept free above and below the minimap inside `availableHeight`.
        static let reservedVertical: CGFloat = 120
        static let collapsedMaxHeight: CGFloat = 280
        static let expandedMaxHeight: CGFloat = 460
        static let minHeight: CGFloat = 80

        static let collapsedPadding: CGFloat = 10
        static let collapsedSpacing: CGFloat = 6
        static let tickHeight: CGFloat = 2
        /// Densest collapsed rail that still reads as separate ticks.
        static let denseTickHeight: CGFloat = 1
        static let denseMinSpacing: CGFloat = 1

        static let expandedPadding: CGFloat = 6
        static let expandedSpacing: CGFloat = 1
        /// Row height: 14 pt handle / 12 pt text line plus 4 pt vertical
        /// padding each side. Only decides whether the list must scroll.
        static let expandedRowHeight: CGFloat = 23
    }

    /// How the rows are hosted. Chosen from the marker count and space only
    /// (never from `isExpanded`), so hovering keeps the same views and the
    /// tick-to-row morph animates instead of swapping subtrees.
    private enum Layout {
        /// Everything fits expanded: the original plain stack.
        case plain
        /// Expanded overflows: one scroll view hosts the rows in both
        /// states, ticks packed to fit the collapsed cap.
        case scrolling(tickHeight: CGFloat, spacing: CGFloat)
        /// Too many messages for one tick each: collapsed ticks stand for
        /// groups, crossfading to the scrolling list on hover.
        case grouped
    }

    private var heightBudget: CGFloat {
        max(availableHeight - Metrics.reservedVertical, Metrics.minHeight)
    }

    private var collapsedCap: CGFloat { min(Metrics.collapsedMaxHeight, heightBudget) }
    private var expandedCap: CGFloat { min(Metrics.expandedMaxHeight, heightBudget) }

    private var layout: Layout {
        let count = CGFloat(markers.count)
        let gaps = max(count - 1, 0)
        let expandedHeight =
            count * Metrics.expandedRowHeight + gaps * Metrics.expandedSpacing + Metrics.expandedPadding * 2
        if expandedHeight <= expandedCap { return .plain }

        let usable = collapsedCap - Metrics.collapsedPadding * 2
        for tick in [Metrics.tickHeight, Metrics.denseTickHeight] {
            let spacing = gaps > 0 ? (usable - count * tick) / gaps : 0
            if spacing >= Metrics.denseMinSpacing {
                return .scrolling(tickHeight: tick, spacing: min(spacing, Metrics.collapsedSpacing))
            }
        }
        return .grouped
    }

    // MARK: - Body

    var body: some View {
        content
            .padding(.horizontal, isExpanded ? 6 : 7)
            .frame(width: isExpanded ? 240 : 24, alignment: .trailing)
            .background(containerBackground)
            .animation(expandAnimation, value: isExpanded)
            .onHover { hovering in
                isExpanded = hovering
            }
    }

    @ViewBuilder
    private var content: some View {
        switch layout {
        case .plain:
            plainList
        case let .scrolling(tickHeight, spacing):
            scrollingList(collapsedTickHeight: tickHeight, collapsedSpacing: spacing)
        case .grouped:
            groupedContent
        }
    }

    /// Original layout: every marker as a row in a plain stack.
    private var plainList: some View {
        VStack(alignment: .leading, spacing: isExpanded ? Metrics.expandedSpacing : Metrics.collapsedSpacing) {
            ForEach(markers) { m in
                row(for: m, collapsedTickHeight: Metrics.tickHeight)
            }
        }
        .padding(.vertical, isExpanded ? Metrics.expandedPadding : Metrics.collapsedPadding)
    }

    /// One scroll view for both states. Collapsed it shows every tick
    /// (scrolling off); expanded the same rows grow into labelled rows, the
    /// frame grows to the expanded cap, and the list centres on the active
    /// row. Collapsing returns to the top so every tick is visible again.
    private func scrollingList(collapsedTickHeight: CGFloat, collapsedSpacing: CGFloat) -> some View {
        let count = CGFloat(markers.count)
        let collapsedHeight =
            count * collapsedTickHeight + max(count - 1, 0) * collapsedSpacing + Metrics.collapsedPadding * 2
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: isExpanded ? Metrics.expandedSpacing : collapsedSpacing) {
                    ForEach(markers) { m in
                        row(for: m, collapsedTickHeight: collapsedTickHeight).id(m.id)
                    }
                }
                .padding(.vertical, isExpanded ? Metrics.expandedPadding : Metrics.collapsedPadding)
            }
            .scrollIndicators(isExpanded ? .automatic : .hidden)
            .scrollDisabled(!isExpanded)
            .frame(height: isExpanded ? expandedCap : collapsedHeight)
            .onChange(of: isExpanded) { _, expanded in
                if expanded {
                    if let activeMarkerId { proxy.scrollTo(activeMarkerId, anchor: .center) }
                } else if let first = markers.first {
                    proxy.scrollTo(first.id, anchor: .top)
                }
            }
        }
    }

    /// Very long conversations: collapsed ticks stand for contiguous groups
    /// of messages (lit when the active one is in the group), crossfading
    /// to the scrolling list on hover.
    @ViewBuilder
    private var groupedContent: some View {
        if isExpanded {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: Metrics.expandedSpacing) {
                        ForEach(markers) { m in
                            row(for: m, collapsedTickHeight: Metrics.denseTickHeight).id(m.id)
                        }
                    }
                    .padding(.vertical, Metrics.expandedPadding)
                }
                .frame(height: expandedCap)
                .onAppear {
                    if let activeMarkerId { proxy.scrollTo(activeMarkerId, anchor: .center) }
                }
            }
            .transition(.opacity)
        } else {
            groupedRail
                .transition(.opacity)
        }
    }

    private var groupedRail: some View {
        let count = markers.count
        let usable = collapsedCap - Metrics.collapsedPadding * 2
        let pitch = Metrics.denseTickHeight + Metrics.denseMinSpacing
        let tickCount = max(2, min(count, Int((usable + Metrics.denseMinSpacing) / pitch)))
        let activeIndex = activeMarkerId.flatMap { id in markers.firstIndex { $0.id == id } }
        let activeTick = activeIndex.map { $0 * tickCount / count }

        return VStack(alignment: .trailing, spacing: Metrics.denseMinSpacing) {
            ForEach(0 ..< tickCount, id: \.self) { i in
                handle(isActive: i == activeTick, collapsedHeight: Metrics.denseTickHeight)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.vertical, Metrics.collapsedPadding)
    }

    // MARK: - Background

    private var containerBackground: some View {
        let shape = RoundedRectangle(cornerRadius: isExpanded ? 10 : 8, style: .continuous)
        return
            shape
            .fill(theme.secondaryBackground.opacity(isExpanded ? 0.96 : 0.70))
            .overlay(
                shape.strokeBorder(
                    theme.secondaryText.opacity(0.14),
                    lineWidth: 1
                )
            )
            .shadow(
                color: theme.shadowColor.opacity(isExpanded ? 0.25 : 0.12),
                radius: isExpanded ? 12 : 5,
                x: 0,
                y: isExpanded ? 3 : 1
            )
    }

    // MARK: - Row

    private func row(for marker: Marker, collapsedTickHeight: CGFloat) -> some View {
        let isActive = marker.id == activeMarkerId

        return Button {
            guard isExpanded else { return }
            onSelect(marker.id)
        } label: {
            HStack(spacing: 10) {
                handle(isActive: isActive, collapsedHeight: collapsedTickHeight)

                if isExpanded {
                    Text(displayText(for: marker))
                        .font(.system(size: 12))
                        .foregroundColor(isActive ? theme.primaryText : theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, isExpanded ? 4 : 0)
            .padding(.horizontal, isExpanded ? 6 : 0)
            .frame(maxWidth: .infinity, alignment: isExpanded ? .leading : .trailing)
            .background(rowBackground(isActive: isActive))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func handle(isActive: Bool, collapsedHeight: CGFloat) -> some View {
        let color: Color = isActive ? theme.accentColor : theme.secondaryText.opacity(0.5)
        let width: CGFloat = isExpanded ? 3 : (isActive ? 12 : 10)
        let height: CGFloat = isExpanded ? 14 : collapsedHeight
        return Capsule(style: .continuous)
            .fill(color)
            .frame(width: width, height: height)
    }

    private func rowBackground(isActive: Bool) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(isExpanded && isActive ? theme.accentColor.opacity(0.16) : Color.clear)
    }

    private func displayText(for marker: Marker) -> String {
        let trimmed = marker.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "(empty message)" }
        return trimmed.replacingOccurrences(of: "\n", with: " ")
    }
}
