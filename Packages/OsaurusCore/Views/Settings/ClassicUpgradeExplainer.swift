//
//  ClassicUpgradeExplainer.swift
//  osaurus
//
//  "Upgrading from Classic?": the sheet Settings → Devices opens to show someone who paired an iPhone with Classic
//  how Osaurus 1.0 connects devices instead, so they move their iPhone over and the Classic relay can be retired.
//  A five-stage diagram in the manner of the Workspaces explainer (`WorkspacesIntroExplainer`): chips over a canvas
//  drawn at a fixed design size and scaled as one piece, a caption under it, advancing on a timer that restarts when
//  a stage is picked, cuts only under Reduce Motion.
//
//  What it says, as the two work:
//  - Classic: the iPhone reaches the Mac live, over the Classic relay; the chats stay on the Mac, so the iPhone has
//    nothing to show once that link drops.
//  - 1.0 (osaurus-sync): every device keeps its own end-to-end encrypted copy and they sync with each other; the
//    Osaurus servers only pass along what they can't read; on the same network devices reach each other directly.
//  - Only on 1.0: workflows, their Live Activities, and agents calling the iPhone.
//

import SwiftUI

// MARK: - Stages

enum ClassicUpgradeStage: Int, CaseIterable, Identifiable {
    case classic
    case ownCopy
    case private_
    case anywhere
    case onlyOn10

    var id: Int { rawValue }

    var next: ClassicUpgradeStage {
        ClassicUpgradeStage(rawValue: (rawValue + 1) % Self.allCases.count) ?? .classic
    }

    var chipLabel: LocalizedStringKey {
        switch self {
        case .classic: return "Classic"
        case .ownCopy: return "Every device"
        case .private_: return "Encrypted"
        case .anywhere: return "Anywhere"
        case .onlyOn10: return "Only on 1.0"
        }
    }

    var holdDuration: Duration { self == .classic ? .seconds(3.5) : .seconds(3) }

    var caption: LocalizedStringKey {
        switch self {
        case .classic:
            return "With Classic, your iPhone borrows the Mac's chats over a live link. When it drops, there's nothing."
        case .ownCopy:
            return "With 1.0, every device keeps its own copy of your chats, so they open even when the Mac sleeps."
        case .private_:
            return "It's end-to-end encrypted. Osaurus servers only pass along data they can't read."
        case .anywhere:
            return "On the same network your devices talk directly, and through Osaurus servers anywhere else."
        case .onlyOn10:
            return "Workflows, Live Activities and agent calls work only on 1.0. Classic pairing is going away."
        }
    }
}

// MARK: - Sheet

struct ClassicUpgradeSheet: View {
    /// Connect iPhone Now: closes this, and Devices opens Add iPhone or iPad.
    let onConnect: () -> Void
    let onClose: () -> Void

    var body: some View {
        SettingsSheet(
            icon: "arrow.triangle.2.circlepath",
            title: "Upgrading from Classic?",
            subtitle: "Osaurus 1.0 connects your devices in a new way. Here's what changes.",
            width: SettingsSheetWidth.wide,
            primary: .init(label: "Connect iPhone Now", handler: onConnect),
            secondary: .init(label: "Got It", handler: onClose),
            onClose: onClose
        ) {
            ClassicUpgradeExplainer()
        }
    }
}

// MARK: - Explainer

struct ClassicUpgradeExplainer: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var stage: ClassicUpgradeStage = .classic
    @State private var availableWidth: CGFloat = ClassicUpgradeExplainer.canvasDesignSize.width

    static let canvasDesignSize = CGSize(width: 656, height: 300)
    static let chipRowHeight: CGFloat = 26
    static let rowSpacing: CGFloat = 16
    /// Two lines of the caption, whichever step.
    static let captionHeight: CGFloat = 44

    private var scale: CGFloat { max(0.5, min(1, availableWidth / Self.canvasDesignSize.width)) }

    var body: some View {
        VStack(spacing: Self.rowSpacing) {
            chips
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: Self.canvasDesignSize.height * scale)
                .onGeometryChange(for: CGFloat.self, of: \.size.width) { width in
                    if width > 0 { availableWidth = width }
                }
                .overlay {
                    ClassicUpgradeCanvas(stage: stage, reduceMotion: reduceMotion)
                        .scaleEffect(scale)
                        .frame(
                            width: Self.canvasDesignSize.width * scale,
                            height: Self.canvasDesignSize.height * scale
                        )
                        .settingsChrome(.surface)
                        .contentShape(Rectangle())
                        .onTapGesture { select(stage.next) }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(localized: "Classic and Osaurus 1.0 compared"))
                        .accessibilityValue(Text(stage.caption, bundle: .module))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint(Text(localized: "Shows the next step"))
                }
            // Stacked, not in the column: the old caption leaving and the new one arriving overlap for a moment, and
            // in the column the two would stack and push the sheet taller, then back.
            ZStack {
                Text(stage.caption, bundle: .module)
                    .font(SettingsFont.cardTitle)
                    .foregroundStyle(theme.text.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.9)
                    .frame(maxWidth: .infinity)
                    .id(stage)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity))
            }
            // A fixed height: with only `reservesSpace` a one-line caption came out 36pt and a two-line one 42pt, so the
            // sheet grew and shrank 6pt between steps, re-centring the window and flashing a scroll bar as it did.
            .frame(maxWidth: .infinity)
            .frame(height: Self.captionHeight)
        }
        .frame(maxWidth: .infinity)
        .task(id: stage) { await autoAdvance() }
    }

    private var chips: some View {
        HStack(spacing: theme.space.s6) {
            ForEach(ClassicUpgradeStage.allCases) { candidate in
                let selected = candidate == stage
                Button {
                    select(candidate)
                } label: {
                    HStack(spacing: theme.space.s6) {
                        Text(verbatim: "\(candidate.rawValue + 1)")
                            .font(SettingsFont.chip)
                            .foregroundStyle(selected ? theme.action.primary.default.foreground : theme.text.secondary)
                            .frame(width: 16, height: 16)
                            .background(
                                Circle().fill(
                                    selected ? theme.action.primary.default.background : theme.surface.pressed)
                            )
                        Text(candidate.chipLabel, bundle: .module)
                            .textStyle(.caption, weight: selected ? 600 : 500)
                            .foregroundStyle(selected ? theme.text.primary : theme.text.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .padding(.horizontal, theme.space.s8)
                    .frame(maxWidth: .infinity, minHeight: Self.chipRowHeight, maxHeight: Self.chipRowHeight)
                    .background(
                        ZStack(alignment: .leading) {
                            Capsule().fill(selected ? theme.surface.selected : theme.surface.subtle)
                            if selected {
                                ChipProgress(
                                    running: !reduceMotion, duration: stage.holdDuration, color: theme.border.strong
                                )
                                .id(stage)
                            }
                        }
                        .clipShape(Capsule())
                    )
                    .overlay(
                        Capsule().stroke(
                            selected ? theme.border.strong : theme.border.subtle, lineWidth: theme.stroke.default)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                .pointingHandCursor()
            }
        }
        .animation(theme.motion.quick, value: stage)
    }

    private func select(_ target: ClassicUpgradeStage) {
        if reduceMotion {
            stage = target
        } else {
            withAnimation(theme.motion.springAnimation) { stage = target }
        }
    }

    private func autoAdvance() async {
        guard !reduceMotion else { return }
        try? await Task.sleep(for: stage.holdDuration)
        guard !Task.isCancelled else { return }
        select(stage.next)
    }
}

/// The active chip's fill, sweeping across it over the stage's hold.
private struct ChipProgress: View {
    @Environment(\.theme) private var theme
    let running: Bool
    let duration: Duration
    let color: Color
    @State private var fraction: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            Rectangle().fill(color).frame(width: proxy.size.width * (running ? fraction : 1))
        }
        .onAppear {
            guard running else { return }
            let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            withAnimation(theme.motion.timed(duration: seconds)) { fraction = 1 }
        }
    }
}

// MARK: - Canvas

/// The diagram: an iPhone and a Mac with the server between them, every element placed from `stage` alone so the
/// scene animates between stages with one spring.
private struct ClassicUpgradeCanvas: View {
    let stage: ClassicUpgradeStage
    let reduceMotion: Bool

    @Environment(\.theme) private var theme

    private enum Layout {
        static let width: CGFloat = 656
        static let height: CGFloat = 300
        static let phoneX: CGFloat = 120
        static let macX: CGFloat = 536
        static let deviceY: CGFloat = 120
        static let serverX: CGFloat = 328
        /// Classic: the relay sits on the line between the two. 1.0: above it, the direct path below.
        static let serverYClassic: CGFloat = 120
        static let serverY: CGFloat = 58
        static let directY: CGFloat = 168
        static let chatsY: CGFloat = 196
        static let featuresY: CGFloat = 256
    }

    private var isClassic: Bool { stage == .classic }
    private var serverY: CGFloat { isClassic ? Layout.serverYClassic : Layout.serverY }
    private var classicTint: Color { theme.status.warning.foreground }
    private var syncTint: Color { theme.status.success.foreground }
    private var tint: Color { isClassic ? classicTint : syncTint }

    private var phonePoint: CGPoint { CGPoint(x: Layout.phoneX + 34, y: Layout.deviceY) }
    private var macPoint: CGPoint { CGPoint(x: Layout.macX - 34, y: Layout.deviceY) }
    private var serverLeft: CGPoint { CGPoint(x: Layout.serverX - 62, y: serverY) }
    private var serverRight: CGPoint { CGPoint(x: Layout.serverX + 62, y: serverY) }

    var body: some View {
        ZStack {
            wires
            if !reduceMotion { pulses.id(stage) }
            device(glyph: "iphone", label: "iPhone", x: Layout.phoneX)
            device(glyph: "laptopcomputer", label: "Mac", x: Layout.macX)
            server
            locks
            directLabel
            phoneChats
            macChats
            features
        }
        .frame(width: Layout.width, height: Layout.height)
        .clipped()
        .animation(theme.motion.springAnimation, value: stage)
    }

    // MARK: Wires

    private var wires: some View {
        ZStack {
            Wire(from: phonePoint, to: serverLeft)
                .stroke(tint.opacity(0.7), style: stroke(dashed: false))
            Wire(from: serverRight, to: macPoint)
                .stroke(tint.opacity(0.7), style: stroke(dashed: false))
            // 1.0 on one network: the two reach each other with no server between.
            Wire(from: phonePoint, to: macPoint, bow: 48)
                .trim(from: 0, to: stage.rawValue >= ClassicUpgradeStage.anywhere.rawValue ? 1 : 0)
                .stroke(syncTint, style: stroke(dashed: true))
        }
    }

    private var pulses: some View {
        ZStack {
            Pulse(from: phonePoint, to: serverLeft, color: tint, delay: 0)
            Pulse(from: serverRight, to: macPoint, color: tint, delay: 0.9)
            if !isClassic {
                // Both ways: each side sends its changes.
                Pulse(from: macPoint, to: serverRight, color: tint, delay: 1.8)
                Pulse(from: serverLeft, to: phonePoint, color: tint, delay: 2.7)
            }
            if stage.rawValue >= ClassicUpgradeStage.anywhere.rawValue {
                Pulse(from: phonePoint, to: macPoint, bow: 48, color: syncTint, delay: 0.4)
            }
        }
    }

    private func stroke(dashed: Bool) -> StrokeStyle {
        StrokeStyle(lineWidth: theme.stroke.focus, lineCap: .round, dash: dashed ? [4, 5] : [])
    }

    // MARK: Nodes

    private func device(glyph: String, label: LocalizedStringKey, x: CGFloat) -> some View {
        VStack(spacing: theme.space.s6) {
            ZStack {
                Circle().fill(theme.surface.raised).frame(width: 64, height: 64)
                Circle().stroke(theme.rule(around: tint), lineWidth: theme.stroke.default).frame(width: 64, height: 64)
                Image(systemName: glyph)
                    .glyphSize(.large, weight: .semibold)
                    .foregroundStyle(theme.text.primary)
            }
            Text(label, bundle: .module)
                .font(SettingsFont.chip)
                .foregroundStyle(theme.text.secondary)
        }
        .position(x: x, y: Layout.deviceY + 12)
    }

    private var server: some View {
        HStack(spacing: theme.space.s6) {
            Image(systemName: isClassic ? "server.rack" : "lock.icloud")
                .glyphSize(.footnote, weight: .semibold)
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
            Text(serverLabel, bundle: .module)
                .font(SettingsFont.smallLabel)
                .foregroundStyle(theme.text.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, theme.space.s8)
        .frame(width: 124, height: 32)
        .background(
            RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous).fill(theme.wash(behind: tint)))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                .stroke(theme.rule(around: tint), lineWidth: theme.stroke.default)
        )
        .position(x: Layout.serverX, y: serverY)
    }

    private var serverLabel: LocalizedStringKey {
        switch stage {
        case .classic: return "Classic relay"
        case .private_: return "Can't read it"
        default: return "Osaurus servers"
        }
    }

    /// Stage 3 on: a lock on each wire to the servers.
    private var locks: some View {
        let shown = stage.rawValue >= ClassicUpgradeStage.private_.rawValue
        // Each grown where it sits: scaled as one canvas-sized layer they swept in from, and out to, its middle.
        return ZStack {
            lock.scaleEffect(shown ? 1 : 0.6).opacity(shown ? 1 : 0).position(midpoint(phonePoint, serverLeft))
            lock.scaleEffect(shown ? 1 : 0.6).opacity(shown ? 1 : 0).position(midpoint(serverRight, macPoint))
        }
    }

    private var lock: some View {
        ZStack {
            Circle().fill(theme.status.success.background).frame(width: 26, height: 26)
            Image(systemName: "lock.fill")
                .glyphSize(.caption, weight: .semibold)
                .foregroundStyle(theme.status.success.foreground)
        }
    }

    private var directLabel: some View {
        let shown = stage.rawValue >= ClassicUpgradeStage.anywhere.rawValue
        return Text("Same network: direct", bundle: .module)
            .font(SettingsFont.chip)
            .foregroundStyle(theme.text.secondary)
            .padding(.horizontal, theme.space.s6)
            .background(Capsule().fill(theme.surface.raised))
            .position(x: Layout.serverX, y: Layout.directY)
            .opacity(shown ? 1 : 0)
    }

    // MARK: Chats

    /// Classic: borrowed, gone with the link. 1.0: the iPhone's own copy.
    private var phoneChats: some View {
        chatsPill(
            label: isClassic ? "Borrowed live" : "Own copy",
            glyph: isClassic ? "bubble.left.and.exclamationmark.bubble.right" : "bubble.left.and.bubble.right.fill",
            color: tint, dashed: isClassic
        )
        .position(x: Layout.phoneX, y: Layout.chatsY)
        .opacity(stage == .onlyOn10 ? 0 : 1)
    }

    private var macChats: some View {
        chatsPill(
            label: isClassic ? "All chats" : "Own copy", glyph: "bubble.left.and.bubble.right.fill",
            color: isClassic ? theme.text.secondary : syncTint, dashed: false
        )
        .position(x: Layout.macX, y: Layout.chatsY)
        .opacity(stage == .onlyOn10 ? 0 : 1)
    }

    private func chatsPill(label: LocalizedStringKey, glyph: String, color: Color, dashed: Bool) -> some View {
        HStack(spacing: theme.space.s6) {
            Image(systemName: glyph)
                .glyphSize(.footnote, weight: .semibold)
                .foregroundStyle(color)
                .contentTransition(.symbolEffect(.replace))
            Text(label, bundle: .module)
                .font(SettingsFont.smallLabel)
                .foregroundStyle(theme.text.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, theme.space.s10)
        .frame(height: 30)
        .background(Capsule().fill(theme.surface.raised))
        .overlay(
            Capsule().stroke(
                dashed ? color : theme.rule(around: color),
                style: StrokeStyle(lineWidth: theme.stroke.default, dash: dashed ? [3, 3] : [])
            )
        )
    }

    // MARK: Only on 1.0

    private struct Feature: Identifiable {
        let id: Int
        let label: LocalizedStringKey
        let glyph: String
    }

    private static let featureList: [Feature] = [
        Feature(id: 0, label: "Workflows", glyph: "point.3.connected.trianglepath.dotted"),
        Feature(id: 1, label: "Live Activities", glyph: "platter.filled.top.iphone"),
        Feature(id: 2, label: "Agent calls", glyph: "phone.fill"),
        Feature(id: 3, label: "Every device, one account", glyph: "person.crop.circle.badge.checkmark"),
    ]

    private var features: some View {
        let shown = stage == .onlyOn10
        return HStack(spacing: theme.space.s8) {
            ForEach(Self.featureList) { feature in
                HStack(spacing: theme.space.s6) {
                    Image(systemName: feature.glyph)
                        .glyphSize(.footnote, weight: .semibold)
                        .foregroundStyle(syncTint)
                    Text(feature.label, bundle: .module)
                        .font(SettingsFont.smallLabel)
                        .foregroundStyle(theme.text.primary)
                        .lineLimit(1)
                }
                .padding(.horizontal, theme.space.s10)
                .frame(height: 30)
                .background(Capsule().fill(theme.wash(behind: syncTint)))
                .overlay(Capsule().stroke(theme.rule(around: syncTint), lineWidth: theme.stroke.default))
                .offset(y: shown ? 0 : 16)
                .opacity(shown ? 1 : 0)
                .animation(
                    theme.motion.springAnimation.delay(shown ? 0.08 * Double(feature.id) : 0), value: stage)
            }
        }
        .position(x: Layout.width / 2, y: Layout.featuresY - (shown ? 40 : 0))
    }

    private func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
}

// MARK: - Wire

/// An S-curve between two points; `bow` sags it below the straight line instead (the direct path).
private struct Wire: Shape {
    var from: CGPoint
    var to: CGPoint
    var bow: CGFloat = 0

    var animatableData: AnimatablePair<CGPoint.AnimatableData, CGPoint.AnimatableData> {
        get { AnimatablePair(from.animatableData, to.animatableData) }
        set {
            from.animatableData = newValue.first
            to.animatableData = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: from)
        if bow != 0 {
            let mid = CGPoint(x: (from.x + to.x) / 2, y: max(from.y, to.y) + bow)
            path.addQuadCurve(to: to, control: mid)
        } else {
            let dx = (to.x - from.x) * 0.5
            path.addCurve(
                to: to,
                control1: CGPoint(x: from.x + dx, y: from.y),
                control2: CGPoint(x: to.x - dx, y: to.y)
            )
        }
        return path
    }
}

/// A bright segment running along a wire, over and over: what's sent.
private struct Pulse: View {
    @Environment(\.theme) private var theme
    let from: CGPoint
    let to: CGPoint
    var bow: CGFloat = 0
    let color: Color
    let delay: Double

    @State private var head: CGFloat = 0
    @State private var visible = false

    var body: some View {
        Wire(from: from, to: to, bow: bow)
            .trim(from: max(0, head - 0.16), to: min(1, head))
            .stroke(color, style: StrokeStyle(lineWidth: theme.stroke.focus * 2, lineCap: .round))
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(theme.motion.standard.delay(0.5 + delay)) { visible = true }
                withAnimation(theme.motion.loop(duration: 1.6, delay: 0.5 + delay)) { head = 1.16 }
            }
    }
}

#if DEBUG
    #Preview("Upgrading from Classic") {
        ClassicUpgradeSheet(onConnect: {}, onClose: {})
    }
#endif
