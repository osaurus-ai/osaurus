//
//  AgentTemplatesIntroCard.swift
//  osaurus
//
//  Explainer card shown above the template grid in the Templates tab. Copy
//  and a step list on the left, an animated scene on the right. One agent
//  card is the protagonist of all four beats: its setup switches on, a
//  copy peels off while private data stays behind, the copy fans out into
//  the ways to share it, and it lands on another Mac where the wizard fills
//  in the gaps. Auto-advances, restarts on a click, cuts under Reduce Motion.
//

import SwiftUI

// MARK: - Stages

enum AgentTemplatesIntroStage: Int, CaseIterable, Identifiable {
    case agent
    case save
    case share
    case reuse

    var id: Int { rawValue }

    var next: AgentTemplatesIntroStage {
        AgentTemplatesIntroStage(rawValue: (rawValue + 1) % AgentTemplatesIntroStage.allCases.count) ?? .agent
    }

    var title: String {
        switch self {
        case .agent: return L("Your agent")
        case .save: return L("Save the setup")
        case .share: return L("Share It")
        case .reuse: return L("Use it anywhere")
        }
    }

    var holdDuration: Duration {
        switch self {
        case .agent: return .seconds(3.6)
        case .save, .share, .reuse: return .seconds(5)
        }
    }

    var caption: String {
        switch self {
        case .agent:
            return L("Start with an agent you have set up the way you like: prompt, model, tools, and folder.")
        case .save:
            return L("Save it as a template. Only the setup travels. Your files, keys, and chats stay on your Mac.")
        case .share:
            return L("Send the template as a link or a JSON file, or keep it in your library so the Orchestrator can use it.")
        case .reuse:
            return L("Anyone can turn it back into an agent. Osaurus asks only for what their Mac is missing.")
        }
    }
}

// MARK: - Card

/// Inline explainer: copy and a clickable step list on the left, a compact
/// diagram on the right. The active step auto-advances and shows its caption
/// underneath; clicking a step or the diagram jumps there and restarts the
/// countdown. Reduce Motion turns the transitions into cuts.
struct AgentTemplatesIntroCard: View {
    let onDismiss: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var stage: AgentTemplatesIntroStage = .agent

    /// The diagram is drawn in fixed coordinates at this size and scaled as
    /// a whole to fill the space beside the copy, up or down, so it stays
    /// legible on a wide window and never reflows on a narrow one.
    static let canvasDesignSize = CGSize(width: 380, height: 250)
    /// Largest enlargement before the pills start to look oversized.
    static let maxCanvasScale: CGFloat = 1.7
    private static let copyWidth: CGFloat = 220

    var body: some View {
        HStack(alignment: .top, spacing: theme.space.s24) {
            copy
                .frame(width: Self.copyWidth, alignment: .leading)

            diagram
                .frame(maxWidth: .infinity)
        }
        .padding(theme.space.s16)
        .settingsChrome(.card)
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.large, style: .continuous)
                .stroke(theme.border.subtle, lineWidth: theme.stroke.default)
        )
        .overlay(alignment: .topTrailing) {
            SettingsIconButton("xmark", help: "Dismiss", size: .compact, action: onDismiss)
            .padding(theme.space.s8)
            .help(L("Hide this explainer"))
            .accessibilityLabel(Text(L("Hide this explainer")))
        }
        .task(id: stage) { await autoAdvance() }
    }

    // MARK: - Copy and steps

    private var copy: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            HStack(spacing: theme.space.s8) {
                Image(systemName: "square.on.square.dashed")
                    .glyphSize(.label, weight: .semibold)
                    .foregroundStyle(theme.text.link)
                Text(L("What is a template?"))
                    .font(SettingsFont.cardTitle)
                    .foregroundStyle(theme.text.primary)
            }
            Text(L("A portable copy of how an agent is set up, ready to share or reuse."))
                .font(SettingsFont.caption)
                .foregroundStyle(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: theme.space.s2) {
                ForEach(AgentTemplatesIntroStage.allCases) { candidate in
                    stepRow(candidate)
                }
            }
            .padding(.top, theme.space.s2)

            // Caption in its own slot, so the rows above keep their height
            // and consecutive captions never draw over each other.
            Text(stage.caption)
                .font(SettingsFont.rowDescription)
                .foregroundStyle(theme.text.secondary)
                .lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 50, alignment: .topLeading)
                .padding(.horizontal, theme.space.s8)
                .id(stage)
                .transition(.opacity)
        }
    }

    /// One step. The active row is tinted and carries a thin progress line
    /// that sweeps over the hold interval, so the card reads as a small
    /// guided tour rather than a static list.
    private func stepRow(_ candidate: AgentTemplatesIntroStage) -> some View {
        let selected = candidate == stage
        return Button {
            advance(to: candidate)
        } label: {
            HStack(alignment: .center, spacing: theme.space.s10) {
                ZStack {
                    Circle()
                        .fill(selected ? theme.action.primary.default.background : theme.surface.pressed)
                        .frame(width: 16, height: 16)
                    Text(verbatim: "\(candidate.rawValue + 1)")
                        .font(SettingsFont.chip)
                        .foregroundStyle(selected ? theme.action.primary.default.foreground : theme.text.secondary)
                }
                VStack(alignment: .leading, spacing: theme.space.s2) {
                    Text(candidate.title)
                        .textStyle(.caption, weight: selected ? 600 : 500)
                        .foregroundStyle(selected ? theme.text.primary : theme.text.secondary)
                    // Progress line under the active title, remounted per
                    // stage so it restarts on every jump. Present but
                    // clear on the others, so every row is the same height.
                    IntroStepProgress(
                        running: selected && !reduceMotion,
                        duration: candidate.holdDuration,
                        color: selected ? theme.border.strong : Color.clear,
                        track: selected ? theme.surface.hover : Color.clear
                    )
                    .frame(height: 2)
                    .id(selected ? stage.rawValue : -1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, theme.space.s6)
            .padding(.horizontal, theme.space.s8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsChrome(selected ? .selected : nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .animation(theme.motion.quick, value: stage)
    }

    // MARK: - Diagram

    private var diagram: some View {
        GeometryReader { proxy in
            // Fit the whole drawing inside the box in both directions and
            // centre it, so it fills the row the copy sets the height of.
            let scale = min(
                Self.maxCanvasScale,
                proxy.size.width / Self.canvasDesignSize.width,
                proxy.size.height / Self.canvasDesignSize.height
            )
            AgentTemplatesIntroCanvas(stage: stage, reduceMotion: reduceMotion)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(
                    width: Self.canvasDesignSize.width * scale,
                    height: Self.canvasDesignSize.height * scale,
                    alignment: .topLeading
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .settingsChrome(.surface)
        .contentShape(Rectangle())
        .onTapGesture { advance(to: stage.next) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L("Templates explainer diagram")))
        .accessibilityValue(Text(stage.title))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text(L("Shows the next step")))
        // Keep the close button clear of the diagram corner.
        .padding(.trailing, theme.space.s16)
    }

    // MARK: - Behaviour

    private func advance(to target: AgentTemplatesIntroStage) {
        if reduceMotion {
            stage = target
        } else {
            withAnimation(theme.motion.springAnimation) {
                stage = target
            }
        }
    }

    /// Keyed on the stage by `.task(id:)`, so every change restarts the
    /// countdown from zero. Reduce Motion disables it.
    private func autoAdvance() async {
        guard !reduceMotion else { return }
        try? await Task.sleep(for: stage.holdDuration)
        guard !Task.isCancelled else { return }
        advance(to: stage.next)
    }
}

// MARK: - Step progress

private struct IntroStepProgress: View {
    @Environment(\.theme) private var theme
    let running: Bool
    let duration: Duration
    let color: Color
    let track: Color

    @State private var fraction: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule()
                    .fill(color)
                    .frame(width: proxy.size.width * (running ? fraction : 1))
            }
        }
        .onAppear {
            guard running else { return }
            let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            withAnimation(theme.motion.timed(duration: seconds)) { fraction = 1 }
        }
    }
}

// MARK: - Canvas

/// Four scenes with shared props. Everything derives from `stage` and an
/// intra-beat `phase` counter that the choreography advances on a timer,
/// so each scene is a pure function of state and animates implicitly.
private struct AgentTemplatesIntroCanvas: View {
    let stage: AgentTemplatesIntroStage
    let reduceMotion: Bool

    @Environment(\.theme) private var theme

    /// Sub-step inside the current beat. Reset to zero on every stage
    /// change and stepped by `schedule(for:)`.
    @State private var phase = 0

    private struct Row: Identifiable {
        let id: Int
        let label: String
        let glyph: String
    }

    private static let rows: [Row] = [
        Row(id: 0, label: L("System Prompt"), glyph: "text.alignleft"),
        Row(id: 1, label: L("Model"), glyph: "cube"),
        Row(id: 2, label: L("Tools"), glyph: "wrench.and.screwdriver"),
        Row(id: 3, label: L("Working Folder"), glyph: "folder"),
    ]

    /// Rows the wizard has to ask about on another Mac.
    private static let localChoiceRows: Set<Int> = [1, 3]

    private struct Channel: Identifiable {
        let id: Int
        let label: String
        let glyph: String
    }

    private static let channels: [Channel] = [
        Channel(id: 0, label: L("Share Link"), glyph: "link"),
        Channel(id: 1, label: L("JSON file"), glyph: "doc.text"),
        Channel(id: 2, label: L("Orchestrator"), glyph: "sparkles"),
    ]

    private enum Layout {
        static let size = CGSize(width: 380, height: 250)
        static let center = CGPoint(x: 190, y: 125)
        static let cardWidth: CGFloat = 200
        static let rowHeight: CGFloat = 26
        static let rowGap: CGFloat = 6
        static let headerHeight: CGFloat = 30
        static let cardHeight: CGFloat = headerHeight + 4 * (rowHeight + rowGap) + 8
        /// Beat 2: the original steps back and the copy peels forward.
        static let peel = CGSize(width: 18, height: 12)
        static let copyWidth: CGFloat = 170
        static let copyHeight: CGFloat = 150
        /// Beat 3: fan spacing and tilt per card away from the middle one.
        static let fanSpread: CGFloat = 80
        static let fanAngle: Double = 13
        /// Fanned copies shrink so the outer two stay inside the canvas.
        static let fanScale: CGFloat = 0.85
        /// Beat 2 pill under the cards.
        static let stayPillY: CGFloat = 232
        /// Beat 4 laptop.
        static let screenSize = CGSize(width: 250, height: 176)
        static let screenCenter = CGPoint(x: 190, y: 108)
        static let baseY: CGFloat = 206
        static let laptopLabelY: CGFloat = 228
        static let screenCardScale: CGFloat = 0.82
    }

    /// Seconds after a beat begins at which `phase` steps up by one.
    private static func schedule(for stage: AgentTemplatesIntroStage) -> [Double] {
        switch stage {
        case .agent: return [0.4, 0.9, 1.4, 1.9]
        case .save: return [0.5, 1.5]
        case .share: return [0.9]
        case .reuse: return [0.7, 2.6]
        }
    }

    private var animation: Animation? {
        theme.motion.springAnimation
    }

    var body: some View {
        ZStack {
            laptop
            originalCard
            stayPill
            ForEach(0..<3, id: \.self) { index in
                fanCopy(index)
            }
            newCard
        }
        .frame(width: Layout.size.width, height: Layout.size.height)
        .clipped()
        .animation(animation, value: stage)
        .animation(animation, value: phase)
        .task(id: stage) { await runChoreography() }
    }

    // MARK: Choreography

    private func runChoreography() async {
        let steps = Self.schedule(for: stage)
        if reduceMotion {
            phase = steps.count
            return
        }
        phase = 0
        var elapsed: Double = 0
        for at in steps {
            try? await Task.sleep(for: .seconds(at - elapsed))
            guard !Task.isCancelled else { return }
            elapsed = at
            phase += 1
        }
    }

    // MARK: Scene 1 and 2: the agent card

    /// Rows switch on one by one in beat 1; in beat 2 the card steps back
    /// and dims while its copy peels off. Gone from beat 3 on.
    private var originalCard: some View {
        let visible = stage == .agent || stage == .save
        let peeled = stage == .save && phase >= 1
        return card(
            title: L("Invoice Bot"),
            glyph: "person.crop.circle.fill",
            tint: theme.action.primary.default.background,
            rowState: { row in
                if stage == .agent { return phase > row.id ? .checked : .hidden }
                return .checked
            }
        )
        .scaleEffect(visible ? (peeled ? 0.96 : 1) : 0.9)
        .opacity(visible ? (peeled ? 0.55 : 1) : 0)
        .position(
            x: Layout.center.x - (peeled ? Layout.peel.width : 0),
            y: Layout.center.y - (peeled ? Layout.peel.height : 0)
        )
    }

    /// What deliberately stays behind. Slides out from under the cards
    /// once the copy has peeled.
    private var stayPill: some View {
        let visible = stage == .save && phase >= 2
        return HStack(spacing: theme.space.s6) {
            Image(systemName: "lock.fill")
                .glyphSize(.micro, weight: .bold)
                .foregroundStyle(theme.status.success.foreground)
            Text(L("Files, keys, and chats stay on your Mac"))
                .font(SettingsFont.smallLabel)
                .foregroundStyle(theme.text.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, theme.space.s12)
        .frame(height: 26)
        .background(Capsule().fill(theme.status.success.background))
        .overlay(Capsule().stroke(theme.status.success.border, lineWidth: theme.stroke.default))
        .opacity(visible ? 1 : 0)
        .position(x: Layout.center.x, y: visible ? Layout.stayPillY : Layout.stayPillY - 30)
    }

    // MARK: Scene 2 and 3: the template copies

    /// Three copies. In beat 2 only the middle one shows, peeling forward
    /// off the card. In beat 3 they start stacked and fan out like a dealt
    /// hand. In beat 4 the middle one lands on the laptop and dissolves
    /// into the new card.
    private func fanCopy(_ index: Int) -> some View {
        let offset = CGFloat(index - 1)
        let isMiddle = index == 1
        let fanned = stage == .share && phase >= 1

        let visible: Bool
        var position = Layout.center
        var rotation: Double = 0
        var scale: CGFloat = 1
        switch stage {
        case .agent:
            visible = false
            scale = 0.9
        case .save:
            visible = isMiddle && phase >= 1
            position = CGPoint(x: Layout.center.x + Layout.peel.width, y: Layout.center.y + Layout.peel.height)
        case .share:
            visible = true
            if fanned {
                position = CGPoint(x: Layout.center.x + offset * Layout.fanSpread, y: Layout.center.y + abs(offset) * 8)
                rotation = Double(offset) * Layout.fanAngle
                scale = Layout.fanScale
            }
        case .reuse:
            visible = isMiddle && phase == 0
            position = Layout.screenCenter
            scale = phase == 0 ? Layout.screenCardScale : 1.05
        }

        // Once dealt, each copy is headed by the way it travels.
        let channel: Channel? = fanned ? Self.channels[index] : nil
        return templateCopy(channel: channel)
            .rotationEffect(.degrees(rotation), anchor: .bottom)
            .scaleEffect(visible ? scale : scale * 0.92)
            .opacity(visible ? 1 : 0)
            .position(position)
            .zIndex(isMiddle ? 1 : 0)
    }

    private func templateCopy(channel: Channel?) -> some View {
        VStack(spacing: theme.space.s0) {
            HStack(spacing: theme.space.s6) {
                Image(systemName: channel?.glyph ?? "square.on.square.dashed")
                    .glyphSize(.footnote, weight: .semibold)
                    .foregroundStyle(channel == nil ? theme.text.link : theme.status.info.foreground)
                    .contentTransition(.symbolEffect(.replace))
                Text(channel?.label ?? L("Template"))
                    .font(SettingsFont.smallLabel)
                    .foregroundStyle(theme.text.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, theme.space.s12)
            .frame(height: 28)
            VStack(spacing: theme.space.s4) {
                ForEach(Self.rows) { row in
                    HStack(spacing: theme.space.s6) {
                        Image(systemName: row.glyph)
                            .glyphSize(.micro, weight: .semibold)
                            .foregroundStyle(theme.text.secondary)
                            .frame(width: 14)
                        Text(row.label)
                            .font(SettingsFont.chip)
                            .foregroundStyle(theme.text.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, theme.space.s8)
                    .frame(height: 22)
                    .settingsChrome(.inset)
                }
            }
            .padding(.horizontal, theme.space.s8)
            .padding(.bottom, theme.space.s8)
        }
        .frame(width: Layout.copyWidth, height: Layout.copyHeight)
        .settingsChrome(.surface)
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                .strokeBorder(theme.border.strong, style: StrokeStyle(lineWidth: theme.stroke.default, dash: [6, 4]))
        )
        .themeElevation(theme.elevation.raised)
    }

    // MARK: Scene 4: another Mac

    private var laptop: some View {
        let visible = stage == .reuse
        return ZStack {
            RoundedRectangle(cornerRadius: theme.radius.large, style: .continuous)
                .fill(theme.status.success.background)
                .overlay(
                    RoundedRectangle(cornerRadius: theme.radius.large, style: .continuous)
                        .stroke(theme.status.success.border, lineWidth: theme.stroke.default)
                )
                .frame(width: Layout.screenSize.width, height: Layout.screenSize.height)
                .position(Layout.screenCenter)
            Capsule()
                .fill(theme.status.success.foreground)
                .frame(width: 120, height: 6)
                .position(x: Layout.center.x, y: Layout.baseY)
            HStack(spacing: theme.space.s4) {
                Image(systemName: "laptopcomputer")
                    .glyphSize(.footnote, weight: .semibold)
                Text(L("Another Mac"))
                    .font(SettingsFont.smallLabel)
            }
            .foregroundStyle(theme.text.secondary)
            .position(x: Layout.center.x, y: Layout.laptopLabelY)
        }
        .scaleEffect(visible ? 1 : 0.94)
        .opacity(visible ? 1 : 0)
    }

    /// The agent rebuilt on the other Mac. Rows that need a local choice
    /// ask first, then resolve, which is exactly what the setup wizard does.
    private var newCard: some View {
        let visible = stage == .reuse && phase >= 1
        return card(
            title: L("Invoice Bot"),
            glyph: "person.crop.circle.fill",
            tint: theme.status.success.foreground,
            rowState: { row in
                guard Self.localChoiceRows.contains(row.id) else { return .checked }
                return phase >= 2 ? .checked : .asking
            }
        )
        .scaleEffect(visible ? Layout.screenCardScale : Layout.screenCardScale * 0.9)
        .opacity(visible ? 1 : 0)
        .position(Layout.screenCenter)
    }

    // MARK: Card chrome

    private enum RowState { case hidden, checked, asking }

    private func card(
        title: String,
        glyph: String,
        tint: Color,
        rowState: @escaping (Row) -> RowState
    ) -> some View {
        VStack(spacing: theme.space.s0) {
            HStack(spacing: theme.space.s6) {
                Image(systemName: glyph)
                    .glyphSize(.label, weight: .semibold)
                    .foregroundStyle(tint)
                Text(title)
                    .font(SettingsFont.compactLabel)
                    .foregroundStyle(theme.text.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, theme.space.s12)
            .frame(height: Layout.headerHeight)
            VStack(spacing: Layout.rowGap) {
                ForEach(Self.rows) { row in
                    settingRow(row, state: rowState(row))
                }
            }
            .padding(.horizontal, theme.space.s8)
            .padding(.bottom, theme.space.s8)
        }
        .frame(width: Layout.cardWidth, height: Layout.cardHeight)
        .settingsChrome(.surface)
        .overlay(
            RoundedRectangle(cornerRadius: theme.radius.medium, style: .continuous)
                .stroke(theme.rule(around: tint), lineWidth: theme.stroke.default)
        )
        .themeElevation(theme.elevation.raised)
    }

    private func settingRow(_ row: Row, state: RowState) -> some View {
        let shown = state != .hidden
        let asking = state == .asking
        return HStack(spacing: theme.space.s8) {
            Image(systemName: row.glyph)
                .glyphSize(.footnote, weight: .semibold)
                .foregroundStyle(asking ? theme.status.warning.foreground : theme.text.link)
                .frame(width: 14)
            Text(row.label)
                .font(SettingsFont.smallLabel)
                .foregroundStyle(theme.text.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: asking ? "questionmark.circle.fill" : "checkmark.circle.fill")
                .glyphSize(.caption, weight: .semibold)
                .foregroundStyle(asking ? theme.status.warning.foreground : theme.status.success.foreground)
                .contentTransition(.symbolEffect(.replace))
                .scaleEffect(shown ? 1 : 0.4)
        }
        .padding(.horizontal, theme.space.s8)
        .frame(height: Layout.rowHeight)
        .settingsChrome(asking ? .status(.warning) : .inset)
        .opacity(shown ? 1 : 0)
        .offset(x: shown ? 0 : -10)
    }
}
