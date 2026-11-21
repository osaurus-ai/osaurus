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
//  The five stages: how Classic pairs (one encrypted relay; when it's offline so is access) and what that means for
//  data (only while connected and the device is on); how Osaurus Sync pairs (the same kind of relay, but devices know
//  each other, so losing it doesn't cut them off) and syncs data (there even offline); and that Sync needs 1.0.
//

import SwiftUI

// MARK: - Stages

enum ClassicUpgradeStage: Int, CaseIterable, Identifiable {
    case classicPairing
    case classicData
    case syncPairing
    case syncData
    case compared

    var id: Int { rawValue }

    var next: ClassicUpgradeStage {
        ClassicUpgradeStage(rawValue: (rawValue + 1) % Self.allCases.count) ?? .classicPairing
    }

    /// Stages showing Classic, drawn in its colour; the rest show Osaurus Sync.
    var isClassic: Bool { self == .classicPairing || self == .classicData }

    var chipLabel: LocalizedStringKey {
        switch self {
        case .classicPairing: return "Classic Pairing"
        case .classicData: return "Classic Data"
        case .syncPairing: return "Osaurus Sync Pairing"
        case .syncData: return "Osaurus Sync Data"
        case .compared: return "Classic vs. Sync"
        }
    }

    /// Long enough to read the caption.
    var holdDuration: Duration {
        switch self {
        case .classicPairing: return .seconds(5.5)
        case .classicData: return .seconds(5)
        case .syncPairing: return .seconds(6.5)
        case .syncData: return .seconds(4.5)
        case .compared: return .seconds(4)
        }
    }

    var caption: LocalizedStringKey {
        switch self {
        case .classicPairing:
            return """
                Classic Osaurus devices pair using a secure, end-to-end encrypted relay. If the relay goes offline, \
                so does access to your devices.
                """
        case .classicData:
            return """
                Classic Pairing only lets you access your chat and agent data while your connection is active and \
                your device is turned on.
                """
        case .syncPairing:
            return """
                New Osaurus Sync devices also pair using a secure, end-to-end encrypted relay. However, your devices \
                are aware of each other, so if the relay goes offline, you can still connect to your other devices.
                """
        case .syncData:
            return "Osaurus Sync lets you sync your data across your devices and access it even when they're offline."
        case .compared:
            return "Osaurus Sync is only supported in the new architecture of Osaurus 1.0 and above."
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
            secondary: .init(label: "I'll Do It Later", handler: onClose),
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

    @State private var stage: ClassicUpgradeStage = .classicPairing
    @State private var availableWidth: CGFloat = ClassicUpgradeExplainer.canvasDesignSize.width

    static let canvasDesignSize = CGSize(width: 656, height: 300)
    static let chipRowHeight: CGFloat = 26
    static let rowSpacing: CGFloat = 16
    /// Three lines of the caption, whichever step.
    static let captionHeight: CGFloat = 66

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
                    .lineLimit(3)
                    .minimumScaleFactor(0.9)
                    .frame(maxWidth: .infinity)
                    .id(stage)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity))
            }
            // A fixed height: with only `reservesSpace` a one-line caption came out 36pt and a two-line one 42pt, so
            // the sheet grew and shrank 6pt between steps, re-centring the window and flashing a scroll bar as it did.
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

/// The diagram: an iPhone and a Mac with the relay between them, every element placed from `stage` (and, in the two
/// pairing stages, whether the relay has gone offline yet) so the scene animates with one spring. Both kinds of pairing
/// go through the same end-to-end encrypted relay, so both carry its locks: Classic is never drawn as less secure, only
/// as cut off when the relay is.
private struct ClassicUpgradeCanvas: View {
    let stage: ClassicUpgradeStage
    let reduceMotion: Bool

    @Environment(\.theme) private var theme

    /// Partway through a Classic stage or Sync Pairing, something drops: the relay in the pairing stages, the Mac in
    /// Classic Data.
    @State private var dropped = false
    private var relayDown: Bool { dropped && (stage == .classicPairing || stage == .syncPairing) }
    /// Classic Data: the Mac itself offline, taking the iPhone's access with it.
    private var macDown: Bool { dropped && stage == .classicData }

    private enum Layout {
        static let width: CGFloat = 656
        static let height: CGFloat = 300
        static let phoneX: CGFloat = 120
        static let macX: CGFloat = 536
        static let deviceY: CGFloat = 112
        static let relayX: CGFloat = 328
        /// Classic: the relay sits on the line between the two, the only way across. Sync: above it, the devices'
        /// own link below.
        static let relayYClassic: CGFloat = 112
        static let relayY: CGFloat = 50
        static let directLabelY: CGFloat = 162
        static let dataY: CGFloat = 196
        static let noteY: CGFloat = 230
        static let comparedY: CGFloat = 150
    }

    private var isClassic: Bool { stage.isClassic }
    private var isCompared: Bool { stage == .compared }
    private var relayY: CGFloat { isClassic ? Layout.relayYClassic : Layout.relayY }
    private var classicTint: Color { theme.status.warning.foreground }
    private var syncTint: Color { theme.status.success.foreground }
    private var offTint: Color { theme.text.tertiary }
    private var tint: Color { isClassic ? classicTint : syncTint }
    /// The relay offline: in the pairing stages once it's dropped, and in Sync Data, where the devices are offline.
    private var relayOff: Bool { relayDown || stage == .syncData }
    /// The devices' own link: Sync only.
    private var hasDirect: Bool { stage == .syncPairing || stage == .syncData }

    private var phonePoint: CGPoint { CGPoint(x: Layout.phoneX + 34, y: Layout.deviceY) }
    private var macPoint: CGPoint { CGPoint(x: Layout.macX - 34, y: Layout.deviceY) }
    private var relayLeft: CGPoint { CGPoint(x: Layout.relayX - 66, y: relayY) }
    private var relayRight: CGPoint { CGPoint(x: Layout.relayX + 66, y: relayY) }

    var body: some View {
        ZStack {
            Group {
                wires
                if !reduceMotion { pulses.id("\(stage.rawValue)-\(linkOff)") }
                device(glyph: "iphone", label: "iPhone", x: Layout.phoneX)
                device(glyph: "laptopcomputer", label: "Mac", x: Layout.macX, isMac: true)
                relay
                locks
                directLabel
                phoneData
                macData
                notes
            }
            .opacity(isCompared ? 0 : 1)
            compared
        }
        .frame(width: Layout.width, height: Layout.height)
        .clipped()
        .animation(theme.motion.springAnimation, value: stage)
        .animation(theme.motion.springAnimation, value: dropped)
        .task(id: stage) { await drop() }
    }

    /// After a beat, the relay (pairing stages) or the Mac (Classic Data) goes offline: Classic loses access, Sync
    /// keeps its own link.
    private func drop() async {
        dropped = false
        guard !reduceMotion, stage != .syncData, stage != .compared else { return }
        try? await Task.sleep(for: .seconds(2.4))
        guard !Task.isCancelled else { return }
        dropped = true
    }

    // MARK: Wires

    /// Nothing gets through: the relay offline, or the Mac on the other end of it.
    private var linkOff: Bool { relayOff || macDown }
    private var relayWireColor: Color { linkOff ? offTint.opacity(0.5) : tint.opacity(0.7) }

    private var wires: some View {
        ZStack {
            Wire(from: phonePoint, to: relayLeft)
                .stroke(relayWireColor, style: stroke(dashed: linkOff))
            Wire(from: relayRight, to: macPoint)
                .stroke(relayWireColor, style: stroke(dashed: linkOff))
            // Sync: the devices know each other, so they reach each other without the relay.
            Wire(from: phonePoint, to: macPoint, bow: 44)
                .trim(from: 0, to: hasDirect ? 1 : 0)
                .stroke(stage == .syncData ? offTint.opacity(0.5) : syncTint, style: stroke(dashed: true))
        }
    }

    private var pulses: some View {
        ZStack {
            if !linkOff {
                Pulse(from: phonePoint, to: relayLeft, color: tint, delay: 0)
                Pulse(from: relayRight, to: macPoint, color: tint, delay: 0.8)
                if !isClassic {
                    Pulse(from: macPoint, to: relayRight, color: tint, delay: 1.6)
                    Pulse(from: relayLeft, to: phonePoint, color: tint, delay: 2.4)
                }
            }
            if stage == .syncPairing {
                Pulse(from: phonePoint, to: macPoint, bow: 44, color: syncTint, delay: 0.4)
            }
        }
    }

    private func stroke(dashed: Bool) -> StrokeStyle {
        StrokeStyle(lineWidth: theme.stroke.focus, lineCap: .round, dash: dashed ? [4, 5] : [])
    }

    // MARK: Nodes

    /// A device, greyed when it can't be reached (Classic with the relay down) or is offline (Sync Data).
    private func device(glyph: String, label: LocalizedStringKey, x: CGFloat, isMac: Bool = false) -> some View {
        let dimmed = (stage == .classicPairing && relayDown) || stage == .syncData || (isMac && macDown)
        return VStack(spacing: theme.space.s6) {
            ZStack {
                Circle().fill(theme.surface.raised).frame(width: 64, height: 64)
                Circle()
                    .stroke(theme.rule(around: dimmed ? offTint : tint), lineWidth: theme.stroke.default)
                    .frame(width: 64, height: 64)
                Image(systemName: glyph)
                    .glyphSize(.large, weight: .semibold)
                    .foregroundStyle(dimmed ? theme.text.tertiary : theme.text.primary)
            }
            Text(label, bundle: .module)
                .font(SettingsFont.chip)
                .foregroundStyle(theme.text.secondary)
        }
        .position(x: x, y: Layout.deviceY + 12)
    }

    /// The relay: the same end-to-end encrypted relay for both, a lock on it either way.
    private var relay: some View {
        let color = relayOff ? offTint : tint
        return HStack(spacing: theme.space.s6) {
            Image(systemName: relayOff ? "icloud.slash" : "lock.icloud")
                .glyphSize(.footnote, weight: .semibold)
                .foregroundStyle(color)
                .contentTransition(.symbolEffect(.replace))
            Text(relayOff ? "Relay offline" : "Encrypted relay", bundle: .module)
                .font(SettingsFont.smallLabel)
                .foregroundStyle(relayOff ? theme.text.secondary : theme.text.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, theme.space.s8)
        .frame(width: 132, height: 32)
        .background(
            RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                .fill(relayOff ? theme.surface.raised : theme.wash(behind: color)))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                .stroke(theme.rule(around: color), lineWidth: theme.stroke.default)
        )
        .position(x: Layout.relayX, y: relayY)
    }

    /// End-to-end encryption on both wires, Classic and Sync alike, while the relay carries anything.
    private var locks: some View {
        let shown = !relayOff
        // Each grown where it sits: scaled as one canvas-sized layer they swept in from, and out to, its middle.
        return ZStack {
            lock.scaleEffect(shown ? 1 : 0.6).opacity(shown ? 1 : 0).position(midpoint(phonePoint, relayLeft))
            lock.scaleEffect(shown ? 1 : 0.6).opacity(shown ? 1 : 0).position(midpoint(relayRight, macPoint))
        }
    }

    private var lock: some View {
        ZStack {
            Circle().fill(theme.wash(behind: tint)).frame(width: 26, height: 26)
            Circle().stroke(theme.rule(around: tint), lineWidth: theme.stroke.default).frame(width: 26, height: 26)
            Image(systemName: "lock.fill")
                .glyphSize(.caption, weight: .semibold)
                .foregroundStyle(tint)
        }
    }

    private var directLabel: some View {
        return Text("Direct via peer-to-peer network", bundle: .module)
            .font(SettingsFont.chip)
            .foregroundStyle(relayDown ? syncTint : theme.text.secondary)
            .padding(.horizontal, theme.space.s6)
            .background(Capsule().fill(theme.surface.raised))
            .position(x: Layout.relayX, y: Layout.directLabelY)
            .opacity(stage == .syncPairing ? 1 : 0)
    }

    // MARK: Data

    private var phoneData: some View {
        let label: LocalizedStringKey
        let color: Color
        var dashed = false
        switch stage {
        case .classicPairing where relayDown, .classicData where macDown:
            label = "No access"
            color = offTint
            dashed = true
        case .classicPairing, .classicData:
            label = "Only while connected"
            color = classicTint
            dashed = true
        case .syncData:
            label = "Own copy"
            color = syncTint
        default:
            label = "Chats & agents"
            color = tint
        }
        return dataPill(label: label, color: color, dashed: dashed)
            .position(x: Layout.phoneX, y: Layout.dataY)
            // Sync Pairing is about the connection only; the data comes in Sync Data.
            .opacity(stage == .syncPairing ? 0 : 1)
    }

    private var macData: some View {
        let label: LocalizedStringKey = stage == .syncData ? "Own copy" : "Chats & agents"
        let color = (stage == .classicPairing && relayDown) || macDown ? offTint : tint
        return dataPill(label: label, color: color, dashed: false)
            .position(x: Layout.macX, y: Layout.dataY)
            .opacity(stage == .syncPairing ? 0 : 1)
    }

    private func dataPill(label: LocalizedStringKey, color: Color, dashed: Bool) -> some View {
        HStack(spacing: theme.space.s6) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .glyphSize(.footnote, weight: .semibold)
                .foregroundStyle(color)
            Text(label, bundle: .module)
                .font(SettingsFont.smallLabel)
                .foregroundStyle(theme.text.primary)
                .lineLimit(1)
                .contentTransition(.opacity)
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

    /// The condition each stage turns on, under the devices.
    private var notes: some View {
        ZStack {
            note(
                macDown ? "Offline" : "Must stay on", glyph: macDown ? "wifi.slash" : "power",
                color: macDown ? offTint : classicTint
            )
                .position(x: Layout.macX, y: Layout.noteY)
                .opacity(stage == .classicData ? 1 : 0)
            note("Available offline", glyph: "checkmark.circle.fill", color: syncTint)
                .position(x: Layout.phoneX, y: Layout.noteY)
                .opacity(stage == .syncData ? 1 : 0)
            note("Available offline", glyph: "checkmark.circle.fill", color: syncTint)
                .position(x: Layout.macX, y: Layout.noteY)
                .opacity(stage == .syncData ? 1 : 0)
        }
    }

    private func note(_ label: LocalizedStringKey, glyph: String, color: Color) -> some View {
        HStack(spacing: theme.space.s4) {
            Image(systemName: glyph).glyphSize(.caption, weight: .semibold).foregroundStyle(color)
            Text(label, bundle: .module).font(SettingsFont.chip).foregroundStyle(theme.text.secondary)
        }
    }

    // MARK: Classic vs. Sync

    private var compared: some View {
        HStack(spacing: theme.space.s24) {
            card(
                title: "Classic", detail: "Osaurus Classic", glyph: "lock.icloud",
                points: ["Encrypted relay", "Only while connected"], color: classicTint, index: 0)
            card(
                title: "Osaurus Sync", detail: "Osaurus 1.0 and above", glyph: "arrow.triangle.2.circlepath",
                points: ["Encrypted relay", "Devices aware of each other", "Data synced and offline"],
                color: syncTint, index: 1)
        }
        .position(x: Layout.width / 2, y: Layout.comparedY)
    }

    private func card(
        title: LocalizedStringKey, detail: LocalizedStringKey, glyph: String, points: [LocalizedStringKey],
        color: Color, index: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            HStack(spacing: theme.space.s8) {
                Image(systemName: glyph).glyphSize(.body, weight: .semibold).foregroundStyle(color)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title, bundle: .module).font(SettingsFont.cardTitle).foregroundStyle(theme.text.primary)
                    Text(detail, bundle: .module).font(SettingsFont.chip).foregroundStyle(theme.text.secondary)
                }
            }
            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                HStack(spacing: theme.space.s6) {
                    Image(systemName: "checkmark").glyphSize(.caption, weight: .bold).foregroundStyle(color)
                    Text(point, bundle: .module).font(SettingsFont.smallLabel).foregroundStyle(theme.text.primary)
                }
            }
        }
        .padding(theme.space.s16)
        .frame(width: 250, height: 170, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: theme.radius.large, style: .continuous).fill(theme.wash(behind: color)))
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.large, style: .continuous)
                .stroke(theme.rule(around: color), lineWidth: theme.stroke.default)
        )
        .offset(y: isCompared ? 0 : 20)
        .opacity(isCompared ? 1 : 0)
        .animation(theme.motion.springAnimation.delay(isCompared ? 0.1 * Double(index) : 0), value: stage)
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
