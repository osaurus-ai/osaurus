//
//  WorkspacesIntroModal.swift
//  osaurus
//
//  One-time "Founding Workspaces" introduction, presented as themed-alert
//  custom content by `AppDelegate.presentWorkspacesIntroDialogIfEligible()`.
//  The centrepiece is an interactive four-stage diagram that walks
//  through what a Workspace is (set up once, hand out, your hardware and
//  rules, one pooled bill). It auto-advances until the user picks a stage
//  themselves, and collapses to instant cuts under Reduce Motion.
//
//  Tone: an invitation to the community, never a paywall. Individual
//  Osaurus stays free and MIT-licensed, and the dialog says so.
//

import SwiftUI

// MARK: - Stages

/// The four beats of the explainer, in presentation order. Each stage owns
/// its chip label and the caption shown beneath the diagram.
enum WorkspacesIntroStage: Int, CaseIterable, Identifiable {
    case setUp
    case handOut
    case yourRules
    case oneBill

    var id: Int { rawValue }

    var next: WorkspacesIntroStage {
        WorkspacesIntroStage(rawValue: (rawValue + 1) % WorkspacesIntroStage.allCases.count) ?? .setUp
    }

    var chipLabel: LocalizedStringKey {
        switch self {
        case .setUp: return "Set up once"
        case .handOut: return "Hand them out"
        case .yourRules: return "Your hardware, your rules"
        case .oneBill: return "One bill"
        }
    }

    var caption: LocalizedStringKey {
        switch self {
        case .setUp: return "Set agents up once and wire them into the tools your team already uses."
        case .handOut: return "Hand them out. Everyone opens Osaurus and their agent is already there."
        case .yourRules: return "Runs on your own Macs, over a private network, under rules you write."
        case .oneBill: return "Cloud models, if you want them, from one shared credit pool."
        }
    }
}

// MARK: - Modal

struct WorkspacesIntroModal: View {
    /// Invoked when the user taps the primary CTA. The caller dismisses
    /// the alert and opens the Workspaces tab.
    let onClaim: () -> Void
    /// Invoked by the secondary "Maybe later" button. The caller dismisses.
    let onLater: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var stage: WorkspacesIntroStage = .setUp
    /// Once the user picks a stage the auto-advance loop stops for good;
    /// a diagram that keeps moving under someone who is reading it is
    /// the opposite of a gentle nudge.
    @State private var userTookControl = false

    /// Content width inside the dialog's 24pt horizontal padding (760 - 48).
    static let dialogWidth: CGFloat = 760
    private var contentWidth: CGFloat { Self.dialogWidth - 48 }

    /// Seconds each stage stays up before the loop advances on its own.
    private static let autoAdvanceInterval: Duration = .seconds(4.5)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            subheadline

            WorkspacesIntroCanvas(stage: stage, reduceMotion: reduceMotion)
                .frame(width: contentWidth, height: WorkspacesIntroCanvas.height)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(theme.secondaryBackground.opacity(theme.isDark ? 0.55 : 0.7))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(theme.primaryBorder.opacity(0.35), lineWidth: 1)
                )
                .contentShape(Rectangle())
                .onTapGesture { select(stage.next) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(localized: "Workspaces explainer diagram"))
                .accessibilityValue(Text(stage.chipLabel, bundle: .module))
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(Text(localized: "Shows the next step"))

            stageChips

            Text(stage.caption, bundle: .module)
                .font(.system(size: 13))
                .foregroundStyle(theme.secondaryText)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: contentWidth, height: 20, alignment: .topLeading)
                .id(stage)
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 6)),
                        removal: .opacity
                    )
                )

            footer
        }
        .frame(width: contentWidth)
        .task(id: userTookControl) { await autoAdvance() }
    }

    // MARK: - Copy

    private var subheadline: some View {
        Text(localized: "Workspaces is here: your Osaurus, for the whole team, on the Macs you already own.")
            .font(.system(size: 13))
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Spacer(minLength: 0)

                Button(action: onLater) {
                    Text(localized: "Maybe later")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.primaryText)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(
                            Capsule()
                                .fill(theme.secondaryBackground)
                                .overlay(Capsule().stroke(theme.primaryBorder.opacity(0.4), lineWidth: 1))
                        )
                }
                .buttonStyle(.plain)

                Button(action: onClaim) {
                    HStack(spacing: 6) {
                        Text(localized: "Claim a Founding Workspace")
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 16)
                    .frame(height: 34)
                    .background(Capsule().fill(theme.accentColor))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }

            Text(localized: "Limited founding pricing, offered to early users first. Osaurus for individuals stays free and MIT-licensed.")
                .font(.system(size: 11))
                .foregroundStyle(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Stage chips

    private var stageChips: some View {
        HStack(spacing: 6) {
            ForEach(WorkspacesIntroStage.allCases) { candidate in
                let selected = candidate == stage
                Button {
                    select(candidate)
                } label: {
                    HStack(spacing: 6) {
                        Text(verbatim: "\(candidate.rawValue + 1)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(selected ? Color.white : theme.secondaryText)
                            .frame(width: 16, height: 16)
                            .background(
                                Circle().fill(selected ? theme.accentColor : theme.secondaryText.opacity(0.18))
                            )
                        Text(candidate.chipLabel, bundle: .module)
                            .font(.system(size: 12, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? theme.primaryText : theme.secondaryText)
                            .lineLimit(1)
                    }
                    .padding(.leading, 6)
                    .padding(.trailing, 10)
                    .frame(height: 26)
                    .background(
                        ZStack(alignment: .leading) {
                            Capsule().fill(selected ? theme.accentColor.opacity(0.10) : theme.secondaryBackground)
                            if selected {
                                // Story-style fill that sweeps across the
                                // active chip over the auto-advance interval.
                                // Remounted per stage so it always starts
                                // from zero; sits at full once the user has
                                // taken control or motion is reduced.
                                StageChipProgress(
                                    running: !userTookControl && !reduceMotion,
                                    duration: Self.autoAdvanceInterval,
                                    color: theme.accentColor.opacity(0.22)
                                )
                                .id(stage)
                            }
                        }
                        .clipShape(Capsule())
                    )
                    .overlay(
                        Capsule().stroke(
                            selected ? theme.accentColor.opacity(0.5) : theme.primaryBorder.opacity(0.3),
                            lineWidth: 1
                        )
                    )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
            Spacer(minLength: 0)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: stage)
    }

    // MARK: - Behaviour

    /// User-initiated stage change: stops the auto-advance loop for good.
    private func select(_ target: WorkspacesIntroStage) {
        userTookControl = true
        advance(to: target)
    }

    private func advance(to target: WorkspacesIntroStage) {
        if reduceMotion {
            stage = target
        } else {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.82)) {
                stage = target
            }
        }
    }

    /// Cycles through the stages until the user takes control. Runs as a
    /// SwiftUI task so it is cancelled with the view and never touches a
    /// timer; Reduce Motion disables it entirely so the diagram stays put.
    private func autoAdvance() async {
        guard !userTookControl, !reduceMotion else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.autoAdvanceInterval)
            guard !Task.isCancelled, !userTookControl else { return }
            advance(to: stage.next)
        }
    }
}

// MARK: - Chip progress

/// Leading-edge fill inside the active stage chip. Starts at zero when it
/// appears and sweeps to the chip's full width over `duration`, in step
/// with the auto-advance loop. When not running it sits at full width.
private struct StageChipProgress: View {
    let running: Bool
    let duration: Duration
    let color: Color

    @State private var fraction: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(color)
                .frame(width: proxy.size.width * (running ? fraction : 1))
        }
        .onAppear {
            guard running else { return }
            let seconds = Double(duration.components.seconds)
                + Double(duration.components.attoseconds) / 1e18
            withAnimation(.linear(duration: seconds)) {
                fraction = 1
            }
        }
    }
}

// MARK: - Canvas

/// The explainer diagram. Every element derives its position, opacity and
/// glyph from `stage` alone, so the whole scene is a pure function of state
/// and animates between stages with a single implicit animation.
private struct WorkspacesIntroCanvas: View {
    let stage: WorkspacesIntroStage
    let reduceMotion: Bool

    @Environment(\.theme) private var theme

    static let height: CGFloat = 284

    /// One row per team: the agent you set up, the system it is wired
    /// into, and the person who ends up with it. Rows are stable across
    /// stages so each agent visibly travels to its owner.
    private struct Lane: Identifiable, Sendable {
        let id: Int
        let agent: (label: String, glyph: String)
        let service: (label: String, glyph: String)
        let member: (label: String, glyph: String)
    }

    private static let lanes: [Lane] = [
        Lane(
            id: 0,
            agent: ("Sales agent", "chart.line.uptrend.xyaxis"),
            service: ("Email", "envelope"),
            member: ("Sales team", "person.2")
        ),
        Lane(
            id: 1,
            agent: ("Support agent", "headphones"),
            service: ("Tickets", "ticket"),
            member: ("Support team", "person.2")
        ),
        Lane(
            id: 2,
            agent: ("Marketing agent", "megaphone"),
            service: ("Docs", "folder"),
            member: ("Marketing team", "person.2")
        ),
        Lane(
            id: 3,
            agent: ("Engineering agent", "chevron.left.forwardslash.chevron.right"),
            service: ("Repo", "arrow.triangle.branch"),
            member: ("Engineering team", "person.2")
        ),
    ]

    // Fixed geometry. The canvas is 712 x 284; rows sit at y = 44, 108,
    // 172, 236 so four 30pt cards stack with 34pt of air between them.
    private enum Layout {
        static let midY: CGFloat = 140
        static func rowY(_ index: Int) -> CGFloat { 44 + CGFloat(index) * 64 }

        static let ownerX: CGFloat = 68
        static let agentX: CGFloat = 250
        static let agentWidth: CGFloat = 140
        static let serviceX: CGFloat = 470
        static let serviceWidth: CGFloat = 108
        static let memberX: CGFloat = 520
        static let memberWidth: CGFloat = 130
        static let deviceX: CGFloat = 284
        static let networkX: CGFloat = 176
        static let gateX: CGFloat = 486
        static let cloudX: CGFloat = 636
        static let poolX: CGFloat = 566
        static let poolWidth: CGFloat = 200
    }

    private var animation: Animation? {
        reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.82)
    }

    var body: some View {
        ZStack {
            connectors
            owner
            ForEach(Self.lanes) { lane in
                serviceChip(lane)
                agentCard(lane)
                memberCard(lane)
            }
            networkBadge
            scrubGate
            cloud
            pool
            localFreeTag
        }
        .frame(width: 712, height: Self.height)
        .clipped()
        .animation(animation, value: stage)
    }

    // MARK: Owner ("Your company" / "Your rules")

    private var owner: some View {
        let isRules = stage == .yourRules || stage == .oneBill
        return VStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(theme.accentColor.opacity(0.16))
                    .frame(width: 44, height: 44)
                Circle()
                    .stroke(theme.accentColor.opacity(0.6), lineWidth: 1.5)
                    .frame(width: 44, height: 44)
                Image(systemName: isRules ? "checkmark.shield" : "building.2.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.accentColor)
                    .contentTransition(.symbolEffect(.replace))
            }
            Group {
                if isRules {
                    Text(localized: "Your rules")
                } else {
                    Text(localized: "Your company")
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.primaryText)
        }
        .position(x: Layout.ownerX, y: Layout.midY)
    }

    // MARK: Cards

    private func agentCard(_ lane: Lane) -> some View {
        let visible = stage == .setUp || stage == .handOut
        let x: CGFloat = stage == .setUp ? Layout.agentX : (stage == .handOut ? Layout.agentX + 40 : Layout.deviceX)
        return pill(label: lane.agent.label, glyph: lane.agent.glyph, width: Layout.agentWidth, tint: theme.accentColor)
            .scaleEffect(visible ? 1 : 0.6)
            .opacity(visible ? 1 : 0)
            .position(x: x, y: Layout.rowY(lane.id))
    }

    private func serviceChip(_ lane: Lane) -> some View {
        let visible = stage == .setUp
        return pill(
            label: lane.service.label, glyph: lane.service.glyph, width: Layout.serviceWidth, tint: theme.infoColor,
            subtle: true
        )
        .scaleEffect(visible ? 1 : 0.7)
        .opacity(visible ? 1 : 0)
        .position(x: visible ? Layout.serviceX : Layout.serviceX + 30, y: Layout.rowY(lane.id))
    }

    /// The team member's card. From `handOut` on it carries the person; in
    /// the last two stages it becomes their own Mac to make "your hardware"
    /// concrete, and slides left to leave room for the rules and pool.
    private func memberCard(_ lane: Lane) -> some View {
        let visible = stage != .setUp
        let isDevice = stage == .yourRules || stage == .oneBill
        let x: CGFloat = isDevice ? Layout.deviceX : Layout.memberX
        return pill(
            label: lane.member.label,
            glyph: isDevice ? "laptopcomputer" : lane.member.glyph,
            width: Layout.memberWidth,
            tint: isDevice ? theme.successColor : theme.accentColor,
            filled: isDevice
        )
        .scaleEffect(visible ? 1 : 0.6)
        .opacity(visible ? 1 : 0)
        .position(x: visible ? x : Layout.memberX + 40, y: Layout.rowY(lane.id))
    }

    private func pill(
        label: String,
        glyph: String,
        width: CGFloat,
        tint: Color,
        subtle: Bool = false,
        filled: Bool = false
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: glyph)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 14)
                .contentTransition(.symbolEffect(.replace))
            Text(LocalizedStringKey(label), bundle: .module)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(subtle ? theme.secondaryText : theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(width: width, height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(filled ? tint.opacity(0.14) : theme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(subtle ? theme.primaryBorder.opacity(0.35) : tint.opacity(0.45), lineWidth: 1)
        )
    }

    // MARK: Stage 3 and 4 props

    private var networkBadge: some View {
        let visible = stage == .yourRules
        return VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(theme.successColor.opacity(0.14))
                    .frame(width: 34, height: 34)
                Image(systemName: "lock.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.successColor)
            }
            Text("Private network", bundle: .module)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.secondaryText)
        }
        .scaleEffect(visible ? 1 : 0.6)
        .opacity(visible ? 1 : 0)
        .position(x: Layout.networkX, y: Layout.midY)
    }

    private var scrubGate: some View {
        let visible = stage == .yourRules
        return VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.warningColor.opacity(0.14))
                    .frame(width: 40, height: 40)
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.warningColor)
            }
            Text("Scrubbed", bundle: .module)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.secondaryText)
        }
        .scaleEffect(visible ? 1 : 0.6)
        .opacity(visible ? 1 : 0)
        .position(x: Layout.gateX, y: Layout.midY)
    }

    private var cloud: some View {
        let visible = stage == .yourRules
        return VStack(spacing: 4) {
            Image(systemName: "cloud")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(theme.tertiaryText)
            Text("Cloud, only if you want", bundle: .module)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
        }
        .scaleEffect(visible ? 1 : 0.6)
        .opacity(visible ? 1 : 0)
        .position(x: Layout.cloudX, y: Layout.midY)
    }

    private var pool: some View {
        let visible = stage == .oneBill
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "creditcard")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.accentColor)
                Text("One credit pool", bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.secondaryText.opacity(0.18))
                    Capsule()
                        .fill(theme.accentColor)
                        .frame(width: visible ? proxy.size.width * 0.62 : 0)
                }
            }
            .frame(height: 8)
            Text("One bill for the whole team, ours or your own accounts", bundle: .module)
                .font(.system(size: 10))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: Layout.poolWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.accentColor.opacity(0.45), lineWidth: 1)
        )
        .scaleEffect(visible ? 1 : 0.7)
        .opacity(visible ? 1 : 0)
        .position(x: visible ? Layout.poolX : Layout.poolX + 30, y: Layout.midY)
    }

    private var localFreeTag: some View {
        let visible = stage == .yourRules || stage == .oneBill
        return HStack(spacing: 5) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 9, weight: .bold))
            Text("Local inference stays free", bundle: .module)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(theme.successColor)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(theme.successColor.opacity(0.12)))
        .opacity(visible ? 1 : 0)
        .position(x: Layout.deviceX, y: Self.height - 13)
    }

    // MARK: Connectors

    /// Every wire the diagram ever draws, each trimmed to 0 or 1 by the
    /// current stage so it grows in and shrinks away with the same spring
    /// as the cards it connects.
    private var connectors: some View {
        ZStack {
            ForEach(Self.lanes) { lane in
                let y = Layout.rowY(lane.id)

                // You -> agent (stage 1 and 2)
                wire(
                    from: CGPoint(x: Layout.ownerX + 26, y: Layout.midY),
                    to: CGPoint(x: (stage == .handOut ? Layout.agentX + 40 : Layout.agentX) - Layout.agentWidth / 2, y: y),
                    shown: stage == .setUp || stage == .handOut,
                    color: theme.accentColor.opacity(0.5)
                )

                // Agent -> service (stage 1)
                wire(
                    from: CGPoint(x: Layout.agentX + Layout.agentWidth / 2, y: y),
                    to: CGPoint(x: Layout.serviceX - Layout.serviceWidth / 2, y: y),
                    shown: stage == .setUp,
                    color: theme.infoColor.opacity(0.55),
                    dashed: true
                )

                // Agent -> member (stage 2)
                wire(
                    from: CGPoint(x: Layout.agentX + 40 + Layout.agentWidth / 2, y: y),
                    to: CGPoint(x: Layout.memberX - Layout.memberWidth / 2, y: y),
                    shown: stage == .handOut,
                    color: theme.accentColor.opacity(0.55)
                )

                // Rules -> network -> each Mac (stage 3), then Mac -> gate.
                wire(
                    from: CGPoint(x: Layout.networkX + 18, y: Layout.midY),
                    to: CGPoint(x: Layout.deviceX - Layout.memberWidth / 2, y: y),
                    shown: stage == .yourRules,
                    color: theme.successColor.opacity(0.5),
                    dashed: true
                )
                wire(
                    from: CGPoint(x: Layout.deviceX + Layout.memberWidth / 2, y: y),
                    to: CGPoint(x: Layout.gateX - 22, y: Layout.midY),
                    shown: stage == .yourRules,
                    color: theme.warningColor.opacity(0.45),
                    dashed: true
                )

                // Mac -> pool (stage 4)
                wire(
                    from: CGPoint(x: Layout.deviceX + Layout.memberWidth / 2, y: y),
                    to: CGPoint(x: Layout.poolX - Layout.poolWidth / 2, y: Layout.midY),
                    shown: stage == .oneBill,
                    color: theme.accentColor.opacity(0.45)
                )
            }

            // Rules -> network (stage 3)
            wire(
                from: CGPoint(x: Layout.ownerX + 24, y: Layout.midY),
                to: CGPoint(x: Layout.networkX - 18, y: Layout.midY),
                shown: stage == .yourRules,
                color: theme.successColor.opacity(0.5),
                dashed: true
            )
            // Gate -> cloud (stage 3)
            wire(
                from: CGPoint(x: Layout.gateX + 22, y: Layout.midY),
                to: CGPoint(x: Layout.cloudX - 22, y: Layout.midY),
                shown: stage == .yourRules,
                color: theme.tertiaryText.opacity(0.5),
                dashed: true
            )
        }
    }

    private func wire(
        from: CGPoint,
        to: CGPoint,
        shown: Bool,
        color: Color,
        dashed: Bool = false
    ) -> some View {
        Wire(from: from, to: to)
            .trim(from: 0, to: shown ? 1 : 0)
            .stroke(
                color,
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: dashed ? [3, 4] : [])
            )
            .opacity(shown ? 1 : 0)
    }
}

/// A gentle S-curve between two points, so fan-out wires read as cables
/// rather than a starburst of straight lines.
private struct Wire: Shape {
    var from: CGPoint
    var to: CGPoint

    /// Endpoints animate so a wire tracks the card it is attached to while
    /// that card slides between columns.
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
        let dx = (to.x - from.x) * 0.5
        path.addCurve(
            to: to,
            control1: CGPoint(x: from.x + dx, y: from.y),
            control2: CGPoint(x: to.x - dx, y: to.y)
        )
        return path
    }
}

#if DEBUG
    #Preview("Workspaces intro") {
        WorkspacesIntroModal(onClaim: {}, onLater: {})
            .padding(24)
            .frame(width: WorkspacesIntroModal.dialogWidth)
    }
#endif
