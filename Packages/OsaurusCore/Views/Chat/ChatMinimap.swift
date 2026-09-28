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
//  Long conversations are height-capped in both states: collapsed, the
//  ticks pack tighter and, past that, each tick stands for a small group
//  of messages; expanded, the list scrolls and opens on the active row.
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
        static let collapsedTickHeight: CGFloat = 2
        static let collapsedSpacing: CGFloat = 6
        /// Tightest tick spacing before ticks start standing for groups.
        static let compactSpacing: CGFloat = 2

        static let expandedPadding: CGFloat = 6
        static let expandedSpacing: CGFloat = 1
        /// Row height: 14 pt handle / 12 pt text line plus 4 pt vertical
        /// padding each side. Only decides whether the list must scroll.
        static let expandedRowHeight: CGFloat = 23
    }

    private var heightBudget: CGFloat {
        max(availableHeight - Metrics.reservedVertical, Metrics.minHeight)
    }

    private var collapsedCap: CGFloat { min(Metrics.collapsedMaxHeight, heightBudget) }
    private var expandedCap: CGFloat { min(Metrics.expandedMaxHeight, heightBudget) }

    private func collapsedHeight(spacing: CGFloat, count: Int) -> CGFloat {
        CGFloat(count) * Metrics.collapsedTickHeight
            + CGFloat(max(count - 1, 0)) * spacing
            + Metrics.collapsedPadding * 2
    }

    private var expandedContentHeight: CGFloat {
        CGFloat(markers.count) * Metrics.expandedRowHeight
            + CGFloat(max(markers.count - 1, 0)) * Metrics.expandedSpacing
            + Metrics.expandedPadding * 2
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
        if isExpanded {
            if expandedContentHeight <= expandedCap {
                fullList
            } else {
                scrollingList
            }
        } else if collapsedHeight(spacing: Metrics.collapsedSpacing, count: markers.count) <= collapsedCap {
            fullList
        } else {
            compactRail
        }
    }

    /// Every marker as a row. Used whenever the whole list fits, so short
    /// conversations keep the tick-to-row morph on hover.
    private var fullList: some View {
        VStack(alignment: .leading, spacing: isExpanded ? Metrics.expandedSpacing : Metrics.collapsedSpacing) {
            ForEach(markers) { m in
                row(for: m)
            }
        }
        .padding(.vertical, isExpanded ? Metrics.expandedPadding : Metrics.collapsedPadding)
    }

    /// Expanded list for conversations taller than the cap: scrolls, and
    /// opens centred on the message being read.
    private var scrollingList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: Metrics.expandedSpacing) {
                    ForEach(markers) { m in
                        row(for: m).id(m.id)
                    }
                }
                .padding(.vertical, Metrics.expandedPadding)
            }
            .frame(height: expandedCap)
            .onAppear {
                if let activeMarkerId {
                    proxy.scrollTo(activeMarkerId, anchor: .center)
                }
            }
        }
    }

    /// Collapsed rail for conversations taller than the cap. Ticks pack
    /// down to `compactSpacing`; if they still overflow, each tick stands
    /// for a contiguous group of messages and lights up when the active
    /// one is in its group.
    private var compactRail: some View {
        let count = markers.count
        let usable = collapsedCap - Metrics.collapsedPadding * 2
        let pitchAtCompact = Metrics.collapsedTickHeight + Metrics.compactSpacing
        let maxTicks = max(2, Int((usable + Metrics.compactSpacing) / pitchAtCompact))
        let tickCount = min(count, maxTicks)
        let spacing: CGFloat =
            tickCount > 1
            ? max(
                Metrics.compactSpacing,
                (usable - CGFloat(tickCount) * Metrics.collapsedTickHeight) / CGFloat(tickCount - 1)
            )
            : 0
        let activeIndex = activeMarkerId.flatMap { id in markers.firstIndex { $0.id == id } }
        let activeTick = activeIndex.map { $0 * tickCount / count }

        return VStack(alignment: .trailing, spacing: min(spacing, Metrics.collapsedSpacing)) {
            ForEach(0 ..< tickCount, id: \.self) { i in
                handle(isActive: i == activeTick)
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

    private func row(for marker: Marker) -> some View {
        let isActive = marker.id == activeMarkerId

        return Button {
            guard isExpanded else { return }
            onSelect(marker.id)
        } label: {
            HStack(spacing: 10) {
                handle(isActive: isActive)

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

    private func handle(isActive: Bool) -> some View {
        let color: Color = isActive ? theme.accentColor : theme.secondaryText.opacity(0.5)
        let width: CGFloat = isExpanded ? 3 : (isActive ? 12 : 10)
        let height: CGFloat = isExpanded ? 14 : Metrics.collapsedTickHeight
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
