//
//  TakeoverViews.swift
//  OsaurusCore — Computer Use
//
//  The visible half of a takeover: a tinted, glowing shield over the window
//  being driven (with the agent's cursor), and a status pill with Stop.
//

import AppKit
import SwiftUI

@MainActor
final class TakeoverViewState: ObservableObject {
    @Published var appName: String = ""
    @Published var confirmPending = false
    @Published var stopping = false
    /// Agent cursor position, local to the shield (top-left origin).
    @Published var cursorPoint: CGPoint?
    @Published var locksTarget = true
    @Published var targetIsFrontmost = false
}

struct TakeoverShieldView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var state: TakeoverViewState
    let onReview: () -> Void

    @State private var glowPhase = false

    var body: some View {
        let ring = theme.border.focus
        let shape = RoundedRectangle(cornerRadius: theme.radius.large, style: .continuous)
        ZStack(alignment: .topLeading) {
            shape
                .fill(state.confirmPending ? theme.status.warning.background : theme.selection.background)
                .opacity(state.confirmPending ? 1 : 0.5)
            shape
                .strokeBorder(ring, lineWidth: theme.stroke.focus)
                .shadow(color: ring, radius: glowPhase ? 14 : 8)
                .opacity(glowPhase ? 1 : 0.6)
                .blur(radius: 0.5)
            if let point = state.cursorPoint, !state.confirmPending {
                AgentCursorView(ink: ring)
                    .position(x: point.x + 7, y: point.y + 10)
                    .animation(.easeInOut(duration: 0.35), value: point)
            }
            if state.confirmPending {
                ConfirmPendingBadge(onReview: onReview)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if state.confirmPending { onReview() } }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { glowPhase = true }
        }
        .accessibilityHidden(true)
    }
}

private struct AgentCursorView: View {
    @Environment(\.theme) private var theme
    let ink: Color

    var body: some View {
        Image(systemName: "cursorarrow")
            .glyphSize(.xlarge, weight: .semibold)
            .foregroundStyle(theme.surface.raised)
            .shadow(color: ink, radius: 6)
            .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
    }
}

private struct ConfirmPendingBadge: View {
    @Environment(\.theme) private var theme
    let onReview: () -> Void

    var body: some View {
        Button(action: onReview) {
            HStack(spacing: theme.space.s8) {
                Image(systemName: "hand.raised.fill")
                Text(L("Waiting for your approval"))
            }
            .font(theme.font(size: theme.pointSize(.body), weight: .semibold))
            .foregroundColor(theme.text.primary)
            .padding(.horizontal, theme.space.s14)
            .padding(.vertical, theme.space.s8)
            .background(theme.surface.raised, in: Capsule())
            .overlay(Capsule().strokeBorder(theme.border.default, lineWidth: theme.stroke.default))
        }
        .buttonStyle(.plain)
    }
}

struct TakeoverStatusPillView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var state: TakeoverViewState
    let onStop: () -> Void
    let onReview: () -> Void

    @State private var pulse = false

    var body: some View {
        HStack(spacing: theme.space.s10) {
            Circle()
                .fill(state.confirmPending ? theme.status.warning.foreground : theme.border.focus)
                .frame(width: 8, height: 8)
                .opacity(pulse ? 1 : 0.4)
            Text(title)
                .font(theme.font(size: theme.pointSize(.bodySmall), weight: .medium))
                .foregroundColor(theme.text.primary)
                .lineLimit(1)
            if state.confirmPending {
                pillButton(L("Review"), action: onReview)
            }
            pillButton(state.stopping ? L("Stopping…") : L("Stop"), action: onStop)
                .disabled(state.stopping)
            if state.locksTarget, state.targetIsFrontmost, !state.stopping {
                Text(L("esc to stop"))
                    .font(theme.font(size: theme.pointSize(.caption)))
                    .foregroundColor(theme.text.secondary)
            }
        }
        .padding(.horizontal, theme.space.s14)
        .padding(.vertical, theme.space.s8)
        .background(theme.surface.raised, in: Capsule())
        .overlay(Capsule().strokeBorder(theme.border.focus, lineWidth: theme.stroke.default))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        .fixedSize()
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    private var title: String {
        if state.confirmPending { return L("Waiting for your approval") }
        return state.appName.isEmpty
            ? L("Osaurus is using your computer")
            : String(format: L("Osaurus is using %@"), state.appName)
    }

    private func pillButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(theme.font(size: theme.pointSize(.caption), weight: .semibold))
                .foregroundColor(theme.text.primary)
                .padding(.horizontal, theme.space.s10)
                .padding(.vertical, theme.space.s4)
                .background(theme.surface.subtle, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Borderless, non-activating, capture-excluded panel.
final class TakeoverPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false
        sharingType = .none
        collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .transient]
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
