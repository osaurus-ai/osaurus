//
//  WorkspacesIntroModal.swift
//  osaurus
//
//  One-time "Founding Workspaces" introduction, presented as themed-alert
//  custom content by `AppDelegate.presentWorkspacesIntroDialogIfEligible()`.
//  The centrepiece is an interactive five-stage diagram that walks
//  through what a Workspace is (agents grouped, set up once, handed out,
//  your hardware and rules, one pooled bill). It advances on a timer that
//  restarts whenever a stage is picked, and collapses to cuts under Reduce Motion.
//
//  Tone: an invitation to the community, never a paywall. Individual
//  Osaurus stays free and MIT-licensed, and the dialog says so.
//

import SwiftUI

// MARK: - Stages

/// The five beats of the explainer, in presentation order. Each stage owns
/// its chip label and the caption shown beneath the diagram.
enum WorkspacesIntroStage: Int, CaseIterable, Identifiable {
    case agents
    case setUp
    case handOut
    case yourRules
    case oneBill

    var id: Int { rawValue }

    var next: WorkspacesIntroStage {
        WorkspacesIntroStage(rawValue: (rawValue + 1) % WorkspacesIntroStage.allCases.count) ?? .agents
    }

    var chipLabel: LocalizedStringKey {
        switch self {
        case .agents: return "Your agents"
        case .setUp: return "Set up once"
        case .handOut: return "Hand them out"
        case .yourRules: return "Full control"
        case .oneBill: return "One bill"
        }
    }

    /// How long the stage stays up before the loop advances on its own,
    /// and the span of the chip progress fill. The first two beats are
    /// lighter and get less time.
    var holdDuration: Duration {
        switch self {
        case .agents: return .seconds(4)
        case .setUp: return .seconds(4.4)
        case .handOut, .yourRules, .oneBill: return .seconds(5.7)
        }
    }

    var caption: LocalizedStringKey {
        switch self {
        case .agents: return "Start with the agents your company relies on, grouped into a Workspace."
        case .setUp: return "Set them up once and wire them into the tools your company already uses."
        case .handOut: return "Hand them to your teams. Everyone opens Osaurus and their agent is already there, wired in."
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

    @State private var stage: WorkspacesIntroStage = .agents

    /// Uniform shrink applied to the diagram when the host window cannot
    /// fit the designed size; 1 on any normal display. See `scale(fitting:)`.
    let scale: CGFloat

    init(scale: CGFloat = 1, onClaim: @escaping () -> Void, onLater: @escaping () -> Void) {
        self.scale = scale
        self.onClaim = onClaim
        self.onLater = onLater
    }

    // MARK: - Sizing

    /// The diagram is drawn in fixed coordinates at this size and scaled as
    /// a whole, so a smaller window never reflows it.
    static let canvasDesignSize = CGSize(width: 912, height: 312)
    /// Horizontal padding the alert dialog adds around custom content.
    static let dialogSidePadding: CGFloat = 24
    /// Everything in the dialog except the canvas, top to bottom: dialog
    /// padding, title, chips, description, buttons, and the gaps between.
    static let chromeHeight: CGFloat = 250
    /// Below this the diagram is unreadable; on such a window we would
    /// rather clip than render it illegibly.
    static let minimumScale: CGFloat = 0.5

    /// Dialog width for a given scale: the scaled canvas plus side padding.
    static func dialogWidth(scale: CGFloat) -> CGFloat {
        canvasDesignSize.width * scale + dialogSidePadding * 2
    }

    /// The largest scale (at most 1) at which the whole dialog fits inside
    /// `available` with `inset` of clear space around it, floored at
    /// `minimumScale`. Pure so it can be tested against arbitrary sizes.
    static func scale(fitting available: CGSize, inset: CGFloat = 48) -> CGFloat {
        let widthRoom = available.width - inset - dialogSidePadding * 2
        let heightRoom = available.height - inset - chromeHeight
        let fit = min(widthRoom / canvasDesignSize.width, heightRoom / canvasDesignSize.height)
        return max(minimumScale, min(1, fit))
    }

    private var contentWidth: CGFloat { Self.canvasDesignSize.width * scale }
    private var canvasHeight: CGFloat { Self.canvasDesignSize.height * scale }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            stageChips

            WorkspacesIntroCanvas(stage: stage, reduceMotion: reduceMotion)
                // Drawn at design size, shrunk as one piece when the window is small.
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: contentWidth, height: canvasHeight)
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

            Text(stage.caption, bundle: .module)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.primaryText)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: contentWidth, height: 24, alignment: .topLeading)
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
        .task(id: stage) { await autoAdvance() }
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
                        Text(localized: "Start Free Trial")
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
                            .minimumScaleFactor(0.8)
                    }
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26)
                    .background(
                        ZStack(alignment: .leading) {
                            Capsule().fill(selected ? theme.accentColor.opacity(0.10) : theme.secondaryBackground)
                            if selected {
                                // Story-style fill that sweeps across the
                                // active chip over the auto-advance interval.
                                // Remounted per stage so it always starts
                                // from zero, so a chip click restarts it; sits
                                // at full when motion is reduced.
                                StageChipProgress(
                                    running: !reduceMotion,
                                    duration: stage.holdDuration,
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
                .pointingHandCursor()
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: stage)
    }

    // MARK: - Behaviour

    /// Chip or canvas click: jump to the stage and restart its countdown.
    private func select(_ target: WorkspacesIntroStage) {
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

    /// Waits one interval, then moves to the next stage. Keyed on the stage
    /// by `.task(id:)`, so every stage change, automatic or from a chip,
    /// restarts the countdown from zero. Reduce Motion disables it.
    private func autoAdvance() async {
        guard !reduceMotion else { return }
        try? await Task.sleep(for: stage.holdDuration)
        guard !Task.isCancelled else { return }
        advance(to: stage.next)
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

    /// Flipped on first appearance to drive the stage 1 build-up.
    @State private var appeared = false

    /// Stage 1 choreography: a row of agents, then a column, then the frame.
    enum IntroPhase { case row, column, framed }
    @State private var introPhase: IntroPhase = .row

    static let height: CGFloat = 312

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
            agent: ("HR agent", "person.badge.shield.checkmark"),
            service: ("Directory", "person.text.rectangle"),
            member: ("HR team", "person.2")
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

    // Fixed geometry. The canvas is 912 x 312; rows sit at y = 58, 122,
    // 186, 250 so four 30pt cards stack with 34pt of air between them.
    private enum Layout {
        static let midY: CGFloat = 154
        static func rowY(_ index: Int) -> CGFloat { 58 + CGFloat(index) * 64 }

        static let ownerX: CGFloat = 64
        static let agentX: CGFloat = 291
        static let agentWidth: CGFloat = 160
        /// Stage 1 opening row: four agent cards centred across the canvas.
        static func rowSlotX(_ index: Int) -> CGFloat { 456 + (CGFloat(index) - 1.5) * (agentWidth + 24) }
        static let serviceX: CGFloat = 556
        static let serviceWidth: CGFloat = 120
        static let memberX: CGFloat = 816
        static let memberWidth: CGFloat = 150
        static let deviceX: CGFloat = 453
        static let networkX: CGFloat = 233
        static let gateX: CGFloat = 676
        static let cloudX: CGFloat = 849
        static let poolX: CGFloat = 740
        static let poolWidth: CGFloat = 220
        /// Padding between the Workspace frame and the cards it encloses.
        static let frameInset: CGFloat = 14
        /// Right edge of the Workspace frame once it encloses the tools.
        static let frameRightX: CGFloat = serviceX + serviceWidth / 2 + frameInset
    }

    private var animation: Animation? {
        reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.82)
    }

    var body: some View {
        ZStack {
            connectors
            if !reduceMotion {
                // Looping attention layer: pulses along the live wires and a
                // breathing ring on the stage's focal node. Keyed by stage so
                // every loop restarts from zero on a transition.
                pulses.id(stage)
                focusRing.id(stage)
            }
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
            workspaceFrame
        }
        .frame(width: 912, height: Self.height)
        .clipped()
        .animation(animation, value: stage)
        // The first stage is the initial state, so nothing transitions into
        // it; the agents build up off this flag instead, one lane at a time.
        .onAppear { appeared = true }
        .task(id: stage) { await runIntroChoreography() }
    }

    // MARK: Stage 1 choreography

    /// Row → column → framed, with a beat between each. Keyed on the stage
    /// by `.task(id:)`, so it replays whenever stage 1 is (re)entered and is
    /// cancelled the moment the story moves on. Reduce Motion jumps straight
    /// to the framed column.
    private func runIntroChoreography() async {
        guard stage == .agents else { return }
        if reduceMotion {
            introPhase = .framed
            return
        }
        introPhase = .row
        // Let the four cards land in the row (staggered) and be read.
        try? await Task.sleep(for: .seconds(Double(Self.lanes.count) * Self.laneStaggerInterval + 1.1))
        guard !Task.isCancelled else { return }
        introPhase = .column
        try? await Task.sleep(for: .seconds(Double(Self.lanes.count) * Self.columnStaggerInterval + 0.45))
        guard !Task.isCancelled else { return }
        introPhase = .framed
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
        .opacity(stage == .agents ? 0 : 1)
        .scaleEffect(stage == .agents ? 0.6 : 1)
        .position(x: Layout.ownerX, y: Layout.midY)
    }

    // MARK: Cards

    private func agentCard(_ lane: Lane) -> some View {
        // Built in stage 1 and still standing, wired to its tool, in stage
        // 2: handing out adds the teams to the picture, it does not undo
        // the setup. The agents leave the picture only when the story
        // moves on to hardware.
        let visible = appeared && (stage == .agents || stage == .setUp || stage == .handOut)
        return pill(label: lane.agent.label, glyph: lane.agent.glyph, width: Layout.agentWidth, tint: theme.accentColor)
            .scaleEffect(visible ? 1 : 0.6)
            .opacity(visible ? 1 : 0)
            .position(agentPosition(for: lane))
            .animation(laneStagger(for: lane), value: stage)
            .animation(laneStagger(for: lane), value: appeared)
            .animation(columnMove(for: lane), value: introPhase)
    }

    /// Stage 1 opens with the agents in a row across the middle, then they
    /// slide into the column the rest of the story uses.
    private func agentPosition(for lane: Lane) -> CGPoint {
        if stage == .agents, introPhase == .row {
            return CGPoint(x: Layout.rowSlotX(lane.id), y: Layout.midY)
        }
        return CGPoint(x: Layout.agentX, y: Layout.rowY(lane.id))
    }

    /// Per-lane delay so agents (and their wires) land one after the other
    /// in stage 1 and are delivered one after the other in stage 2. Zero
    /// everywhere else, so the later stages move everything together.
    private static let laneStaggerInterval: Double = 0.32
    /// Tighter stagger and snappier spring for the row → column move in
    /// stage 1, so the regrouping reads as one quick gesture.
    private static let columnStaggerInterval: Double = 0.1
    private func columnMove(for lane: Lane) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.86).delay(Double(lane.id) * Self.columnStaggerInterval)
    }

    private func laneStagger(for lane: Lane, extra: Double = 0) -> Animation? {
        guard stage == .agents || stage == .setUp || stage == .handOut else { return animation }
        return animation?.delay(Double(lane.id) * Self.laneStaggerInterval + extra)
    }

    private func serviceChip(_ lane: Lane) -> some View {
        // The tools the agent was wired into stay on screen through stage
        // 2, so the team visibly inherits a working setup.
        let visible = stage == .setUp || stage == .handOut
        return pill(
            label: lane.service.label, glyph: lane.service.glyph, width: Layout.serviceWidth, tint: theme.infoColor,
            subtle: true
        )
        .scaleEffect(visible ? 1 : 0.7)
        .opacity(visible ? 1 : 0)
        .position(x: visible ? Layout.serviceX : Layout.serviceX + 30, y: Layout.rowY(lane.id))
        .animation(laneStagger(for: lane), value: stage)
    }

    /// The team member's card. From `handOut` on it carries the person; in
    /// the last two stages it becomes their own Mac to make "your hardware"
    /// concrete, and steps right to make room for the private-network lock.
    private func memberCard(_ lane: Lane) -> some View {
        let visible = stage == .handOut || stage == .yourRules || stage == .oneBill
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
        // Arrives from the far side: the Workspace is what gets handed out,
        // so the teams sit beyond it, not between it and the company.
        .position(x: visible ? x : Layout.memberX + 40, y: Layout.rowY(lane.id))
        .animation(laneStagger(for: lane), value: stage)
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
        .foregroundStyle(Color.white)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(theme.accentColor))
        .opacity(visible ? 1 : 0)
        // Sits as a header over the Macs column: the claim is about them.
        .position(x: Layout.deviceX, y: Layout.rowY(0) - 34)
    }

    // MARK: Workspace frame

    /// A dashed frame around the agents column with a "Workspace" tag: the
    /// grouping is the product. It closes around the agents once the last
    /// one has landed in stage 1,
    /// and stays through the setup and hand-out stages, then
    /// gives way to the hardware view.
    private var workspaceFrame: some View {
        let visible = appeared && ((stage == .agents && introPhase == .framed) || stage == .setUp || stage == .handOut)
        let top = Layout.rowY(0) - 15
        let bottom = Layout.rowY(Self.lanes.count - 1) + 15
        let inset = Layout.frameInset
        let frameHeight = bottom - top + inset * 2
        // Stage 1 frames the agents alone; from stage 2 the frame grows to
        // take in the tools they are wired to, so what gets handed out in
        // stage 3 is visibly the whole working setup.
        let frameLeft = Layout.agentX - Layout.agentWidth / 2 - inset
        let frameRight = stage == .agents ? Layout.agentX + Layout.agentWidth / 2 + inset : Layout.frameRightX
        return ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    theme.accentColor.opacity(0.45),
                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 5])
                )
            Text(localized: "Workspace")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(theme.accentColor)
                .padding(.horizontal, 8)
                .frame(height: 18)
                .background(Capsule().fill(theme.secondaryBackground))
                .overlay(Capsule().stroke(theme.accentColor.opacity(0.45), lineWidth: 1))
                .offset(y: -9)
        }
        .frame(width: frameRight - frameLeft, height: frameHeight)
        .scaleEffect(visible ? 1 : 0.92)
        .opacity(visible ? 1 : 0)
        .position(x: (frameLeft + frameRight) / 2, y: (top + bottom) / 2)
        .animation(animation, value: stage)
        .animation(animation, value: introPhase)
    }

    // MARK: Looping attention layer

    /// The wires that carry traffic in the current stage, as (from, to)
    /// pairs, in the same coordinates as `connectors`. Each lane's pulse is
    /// staggered so the four never fire in lockstep.
    private var activeWires: [(from: CGPoint, to: CGPoint, color: Color)] {
        Self.lanes.flatMap { lane -> [(from: CGPoint, to: CGPoint, color: Color)] in
            let y = Layout.rowY(lane.id)
            switch stage {
            case .agents:
                return []
            case .setUp, .handOut:
                // Stages 2 and 3 run a sequential train instead (see `pulses`).
                return []
            case .yourRules:
                return [
                    (
                        CGPoint(x: Layout.networkX + 18, y: Layout.midY),
                        CGPoint(x: Layout.deviceX - Layout.memberWidth / 2, y: y),
                        theme.successColor
                    ),
                    (
                        CGPoint(x: Layout.deviceX + Layout.memberWidth / 2, y: y),
                        CGPoint(x: Layout.gateX - 22, y: Layout.midY),
                        theme.warningColor
                    ),
                ]
            case .oneBill:
                return [
                    (
                        CGPoint(x: Layout.deviceX + Layout.memberWidth / 2, y: y),
                        CGPoint(x: Layout.poolX - Layout.poolWidth / 2, y: Layout.midY),
                        theme.accentColor
                    )
                ]
            }
        }
    }

    @ViewBuilder
    private var pulses: some View {
        if stage == .setUp || stage == .handOut {
            // Stages 1 and 2 tell a sequence, not a swarm: one signal leaves
            // the company and runs the whole lane (through the team, once
            // there is one) before the next lane takes its turn. It begins
            // once the last card has landed and loops from the top.
            SequentialPulseTrain(
                legs: stage == .setUp ? setUpLegs : handOutLegs,
                legDuration: 0.7,
                startDelay: Double(Self.lanes.count - 1) * Self.laneStaggerInterval + 0.9
            )
        } else {
            let wires = activeWires
            ZStack {
                ForEach(wires.indices, id: \.self) { index in
                    WirePulse(
                        from: wires[index].from,
                        to: wires[index].to,
                        color: wires[index].color,
                        delay: Double(index % Self.lanes.count) * 0.35
                    )
                }
            }
        }
    }

    /// Stage 3 legs in travel order: company → agent, agent → tool, then
    /// out of the Workspace to the team, lane by lane. The stage 2 route
    /// with the hand-off appended, which is the whole point of the stage.
    private var handOutLegs: [SequentialPulseTrain.Leg] {
        Self.lanes.flatMap { lane -> [SequentialPulseTrain.Leg] in
            let y = Layout.rowY(lane.id)
            return [
                SequentialPulseTrain.Leg(
                    from: CGPoint(x: Layout.ownerX + 26, y: Layout.midY),
                    to: CGPoint(x: Layout.agentX - Layout.agentWidth / 2, y: y),
                    color: theme.accentColor
                ),
                SequentialPulseTrain.Leg(
                    from: CGPoint(x: Layout.agentX + Layout.agentWidth / 2, y: y),
                    to: CGPoint(x: Layout.serviceX - Layout.serviceWidth / 2, y: y),
                    color: theme.infoColor
                ),
                SequentialPulseTrain.Leg(
                    from: CGPoint(x: Layout.frameRightX, y: y),
                    to: CGPoint(x: Layout.memberX - Layout.memberWidth / 2, y: y),
                    color: theme.accentColor
                ),
            ]
        }
    }

    /// Stage 1 legs in travel order: company → agent, agent → tool, lane
    /// by lane. Endpoints match the static wires in `connectors`.
    private var setUpLegs: [SequentialPulseTrain.Leg] {
        Self.lanes.flatMap { lane -> [SequentialPulseTrain.Leg] in
            let y = Layout.rowY(lane.id)
            return [
                SequentialPulseTrain.Leg(
                    from: CGPoint(x: Layout.ownerX + 26, y: Layout.midY),
                    to: CGPoint(x: Layout.agentX - Layout.agentWidth / 2, y: y),
                    color: theme.accentColor
                ),
                SequentialPulseTrain.Leg(
                    from: CGPoint(x: Layout.agentX + Layout.agentWidth / 2, y: y),
                    to: CGPoint(x: Layout.serviceX - Layout.serviceWidth / 2, y: y),
                    color: theme.infoColor
                ),
            ]
        }
    }

    /// The node the stage is "about": the company in stage 1, the private
    /// network lock in stage 3. Stages 2 and 4 already have the busiest
    /// pulse traffic, so a ring there would be noise.
    @ViewBuilder
    private var focusRing: some View {
        switch stage {
        case .setUp:
            BreathingRing(color: theme.accentColor, size: 44)
                .position(x: Layout.ownerX, y: Layout.midY - 9)
        case .yourRules:
            BreathingRing(color: theme.successColor, size: 34)
                .position(x: Layout.networkX, y: Layout.midY - 8)
        case .agents, .handOut, .oneBill:
            EmptyView()
        }
    }

    // MARK: Connectors

    /// Every wire the diagram ever draws, each trimmed to 0 or 1 by the
    /// current stage so it grows in and shrinks away with the same spring
    /// as the cards it connects.
    private var connectors: some View {
        ZStack {
            ForEach(Self.lanes) { lane in
                let y = Layout.rowY(lane.id)

                // Company -> agent (stages 2 and 3).
                wire(
                    from: CGPoint(x: Layout.ownerX + 26, y: Layout.midY),
                    to: CGPoint(x: Layout.agentX - Layout.agentWidth / 2, y: y),
                    shown: stage == .setUp || stage == .handOut,
                    color: theme.accentColor.opacity(0.5),
                    animation: .some(laneStagger(for: lane))
                )

                // Workspace -> team (stage 3): the hand-off itself, leaving
                // the frame's right edge on the team's row.
                wire(
                    from: CGPoint(x: Layout.frameRightX, y: y),
                    to: CGPoint(x: Layout.memberX - Layout.memberWidth / 2, y: y),
                    shown: stage == .handOut,
                    color: theme.accentColor.opacity(0.5),
                    animation: .some(laneStagger(for: lane, extra: 0.2))
                )

                // Agent -> tool (stages 1 and 2): the setup from stage 1
                // stays intact while the teams arrive.
                wire(
                    from: CGPoint(x: Layout.agentX + Layout.agentWidth / 2, y: y),
                    to: CGPoint(x: Layout.serviceX - Layout.serviceWidth / 2, y: y),
                    shown: stage == .setUp || stage == .handOut,
                    color: theme.infoColor.opacity(0.55),
                    dashed: true,
                    animation: .some(laneStagger(for: lane))
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
        dashed: Bool = false,
        animation override: Animation?? = nil
    ) -> some View {
        Wire(from: from, to: to)
            .trim(from: 0, to: shown ? 1 : 0)
            .stroke(
                color,
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: dashed ? [3, 4] : [])
            )
            .opacity(shown ? 1 : 0)
            // `nil` keeps the canvas-wide spring; a stage-1 wire passes its
            // lane's staggered animation so it draws with its agent.
            .animation(override ?? animation, value: stage)
    }
}

/// A short bright segment that travels from one end of a wire to the
/// other, forever. Lives on its own `@State` so the loop is independent of
/// the stage spring; the host remounts it per stage to restart.
private struct WirePulse: View {
    let from: CGPoint
    let to: CGPoint
    let color: Color
    let delay: Double
    var duration: Double = 1.8

    @State private var head: CGFloat = 0
    @State private var visible = false

    var body: some View {
        Wire(from: from, to: to)
            .trim(from: max(0, head - 0.14), to: head)
            .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .opacity(visible ? 1 : 0)
            .onAppear {
                // Wait for the stage spring to settle so pulses never
                // chase cards that are still sliding into place.
                withAnimation(.easeIn(duration: 0.3).delay(0.55 + delay)) { visible = true }
                withAnimation(.linear(duration: duration).delay(0.55 + delay).repeatForever(autoreverses: false)) {
                    head = 1.14
                }
            }
    }
}

/// One signal that travels a list of legs strictly in order and then starts
/// over. Driven by a display-rate timeline rather than stacked
/// `repeatForever` animations so the legs can never drift out of sequence;
/// the drawing is a pure function of elapsed time.
private struct SequentialPulseTrain: View {
    struct Leg {
        let from: CGPoint
        let to: CGPoint
        let color: Color
    }

    let legs: [Leg]
    /// Seconds a signal takes to cross one leg.
    let legDuration: Double
    /// Seconds after appearance before the first signal leaves.
    let startDelay: Double

    /// Length of the visible segment as a fraction of its leg.
    private let tail: CGFloat = 0.14

    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSince(start) - startDelay
            if elapsed >= 0, !legs.isEmpty {
                let cycle = elapsed.truncatingRemainder(dividingBy: legDuration * Double(legs.count))
                let index = min(legs.count - 1, Int(cycle / legDuration))
                let progress = CGFloat((cycle - Double(index) * legDuration) / legDuration)
                // The head runs past the end so the tail fully exits the
                // leg before the next one begins.
                let head = progress * (1 + tail)
                let leg = legs[index]
                Wire(from: leg.from, to: leg.to)
                    .trim(from: max(0, head - tail), to: min(1, head))
                    .stroke(leg.color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
        }
        .onAppear { start = Date() }
    }
}

/// A ring that swells and fades from the focal node, forever.
private struct BreathingRing: View {
    let color: Color
    var size: CGFloat = 44

    @State private var expanded = false

    var body: some View {
        Circle()
            .stroke(color, lineWidth: 1.5)
            .frame(width: size, height: size)
            .scaleEffect(expanded ? 1.6 : 1)
            .opacity(expanded ? 0 : 0.7)
            .onAppear {
                withAnimation(.easeOut(duration: 1.8).delay(0.6).repeatForever(autoreverses: false)) {
                    expanded = true
                }
            }
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
            .frame(width: WorkspacesIntroModal.dialogWidth(scale: 1))
    }
#endif
