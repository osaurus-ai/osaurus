//
//  SettingsProgressChecklist.swift
//  osaurus
//
//  A short list of things being done for the person, each ticking off as
//  it finishes: waiting, working (spinner), done (a check that pops in),
//  or failed. Rows arrive with the onboarding entrance cascade. Under
//  Reduce Motion every change is a plain fade.
//
//  `SettingsCompletionMark` is the large check a finished process ends
//  on: the circle settles in and the tick draws once.
//

import SwiftUI

struct SettingsChecklistItem: Identifiable, Equatable {
    enum State: Equatable {
        case waiting
        case working
        case done
        case failed
    }

    let id: String
    /// Already localized.
    let title: String
    /// Already localized: a size, or what went wrong.
    var detail: String?
    var state: State
}

struct SettingsProgressChecklist: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let items: [SettingsChecklistItem]
    /// Cascade the rows in when the list first appears.
    var entrance = true

    private let marker: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s10) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if entrance {
                    row(item).onboardingEntrance(index)
                } else {
                    row(item)
                }
            }
        }
        .animation(reduceMotion ? theme.motion.quick : OnboardingMotion.snappy, value: items)
        .accessibilityElement(children: .contain)
    }

    private func row(_ item: SettingsChecklistItem) -> some View {
        HStack(alignment: .center, spacing: theme.space.s10) {
            markerView(item.state)
            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text(verbatim: item.title)
                    .textStyle(.body, weight: item.state == .working ? 600 : 400)
                    .foregroundColor(item.state == .waiting ? theme.text.secondary : theme.text.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = item.detail {
                    Text(verbatim: detail)
                        .textStyle(.caption)
                        .foregroundColor(item.state == .failed ? theme.status.error.foreground : theme.text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: theme.space.s0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [item.title, item.detail].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityValue(Text(accessibilityState(item.state), bundle: .module))
    }

    @ViewBuilder
    private func markerView(_ state: SettingsChecklistItem.State) -> some View {
        ZStack {
            switch state {
            case .waiting:
                Circle().strokeBorder(theme.border.default, lineWidth: theme.stroke.focus)
            case .working:
                SettingsSpinner(size: .small)
            case .done:
                ZStack {
                    Circle().fill(theme.status.success.foreground)
                    Image(systemName: "checkmark")
                        .glyphSize(.micro, weight: .bold)
                        .foregroundColor(theme.surface.canvas)
                }
                .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
            case .failed:
                ZStack {
                    Circle().fill(theme.status.error.background)
                    Circle().strokeBorder(theme.status.error.foreground, lineWidth: theme.stroke.focus)
                    Image(systemName: "exclamationmark")
                        .glyphSize(.micro, weight: .bold)
                        .foregroundColor(theme.status.error.foreground)
                }
                .transition(.opacity)
            }
        }
        .frame(width: marker, height: marker)
    }

    private func accessibilityState(_ state: SettingsChecklistItem.State) -> LocalizedStringKey {
        switch state {
        case .waiting: "Not started"
        case .working: "In progress"
        case .done: "Done"
        case .failed: "Failed"
        }
    }
}

// MARK: - Completion mark

struct SettingsCompletionMark: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var size: CGFloat = 56

    @State private var settled = false
    @State private var drawn = false

    var body: some View {
        ZStack {
            Circle()
                .fill(theme.status.success.background)
            Circle()
                .strokeBorder(theme.status.success.foreground, lineWidth: theme.stroke.focus)
            SettingsCheckShape()
                .trim(from: 0, to: drawn ? 1 : 0)
                .stroke(
                    theme.status.success.foreground,
                    style: StrokeStyle(lineWidth: size * 0.08, lineCap: .round, lineJoin: .round))
                .padding(size * 0.3)
        }
        .frame(width: size, height: size)
        .scaleEffect(settled || reduceMotion ? 1 : 0.6)
        .opacity(settled ? 1 : 0)
        .onAppear {
            guard !settled else { return }
            if reduceMotion {
                withAnimation(theme.motion.standard) {
                    settled = true
                    drawn = true
                }
                return
            }
            withAnimation(OnboardingMotion.bouncy) { settled = true }
            withAnimation(theme.motion.slow.delay(0.15)) { drawn = true }
        }
        .accessibilityHidden(true)
    }
}

/// A tick drawn left to right, so `trim` reads as a pen stroke.
private struct SettingsCheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY - rect.height * 0.1))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.12))
        return path
    }
}
