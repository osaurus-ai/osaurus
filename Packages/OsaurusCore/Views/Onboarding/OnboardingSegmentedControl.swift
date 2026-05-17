//
//  OnboardingSegmentedControl.swift
//  osaurus
//
//  Generic segmented pill control driven by a `Hashable` tag.
//
//  Two visual densities are supported via `style`:
//   - `.standard`: 30pt segments — the default path-picker density.
//   - `.compact`:  36pt segments — height-matched to
//     `OnboardingTextField`'s chrome for use beside an input
//     (e.g. the HTTP/HTTPS protocol toggle).
//

import SwiftUI

// MARK: - Item

/// One option in an `OnboardingSegmentedControl`. Title is a localized
/// key (`bundle: .module`); icon is optional.
struct OnboardingSegmentItem<Tag: Hashable> {
    let tag: Tag
    let title: LocalizedStringKey
    let icon: String?

    init(tag: Tag, title: LocalizedStringKey, icon: String? = nil) {
        self.tag = tag
        self.title = title
        self.icon = icon
    }
}

// MARK: - Style

enum OnboardingSegmentStyle {
    /// 30pt segment height — the default path-picker density.
    case standard
    /// Form-field-aligned 36pt segments — used beside an input.
    case compact

    var height: CGFloat {
        switch self {
        case .standard: return OnboardingMetrics.segmentHeight
        case .compact: return OnboardingMetrics.protocolToggleHeight
        }
    }
}

// MARK: - Segmented Control

/// Pill segmented control. The selected segment is filled with the theme
/// accent and animated via a localized `.animation(value:)` so segment
/// selection never propagates a transaction to other observers (e.g. the
/// footer CTA).
struct OnboardingSegmentedControl<Tag: Hashable>: View {
    @Binding var selection: Tag
    let items: [OnboardingSegmentItem<Tag>]
    let style: OnboardingSegmentStyle

    @Environment(\.theme) private var theme

    init(
        selection: Binding<Tag>,
        items: [OnboardingSegmentItem<Tag>],
        style: OnboardingSegmentStyle = .standard
    ) {
        self._selection = selection
        self.items = items
        self.style = style
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.tag) { item in
                segment(item)
            }
        }
        .padding(OnboardingMetrics.segmentControlInset)
        .background(
            RoundedRectangle(cornerRadius: OnboardingMetrics.segmentControlRadius, style: .continuous)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: OnboardingMetrics.segmentControlRadius, style: .continuous)
                        .strokeBorder(theme.inputBorder, lineWidth: 1)
                )
        )
    }

    private func segment(_ item: OnboardingSegmentItem<Tag>) -> some View {
        let isSelected = selection == item.tag
        return Button {
            // No `withAnimation` wrapper — selecting a segment otherwise
            // propagates to observers of the bound state (e.g. a footer
            // CTA) and morphs unrelated chrome.
            selection = item.tag
        } label: {
            HStack(spacing: 6) {
                if let icon = item.icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(item.title, bundle: .module)
                    .font(theme.font(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: style.height)
            .foregroundColor(isSelected ? theme.onboardingOnAccent : theme.secondaryText)
            .background(
                RoundedRectangle(cornerRadius: OnboardingMetrics.segmentRadius, style: .continuous)
                    .fill(isSelected ? theme.accentColor : Color.clear)
                    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isSelected)
            )
            // Make the entire segment hit-testable rather than just the
            // drawn icon+label pixels (the `.plain` button style only
            // registers hits on label content otherwise).
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
