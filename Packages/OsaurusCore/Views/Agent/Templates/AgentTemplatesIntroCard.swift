//
//  AgentTemplatesIntroCard.swift
//  osaurus
//
//  Explainer card shown above the template grid in the Templates tab. Copy
//  and a step list on the left, a compact four-beat diagram on the right,
//  walking through what a template is: an agent's setup, saved without its
//  private data, shared as a link or file, and unpacked into a new agent on
//  any Mac. Advances on a timer that restarts whenever a beat is picked,
//  and collapses to cuts under Reduce Motion. Dismissable, remembered.
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
    /// a whole to the space beside the copy, so a narrow window never
    /// reflows it.
    static let canvasDesignSize = CGSize(width: 420, height: 160)
    private static let copyWidth: CGFloat = 250

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            copy
                .frame(width: Self.copyWidth, alignment: .leading)

            diagram
                .frame(maxWidth: .infinity)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(theme.primaryBorder.opacity(0.4), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(theme.secondaryBackground))
            }
            .buttonStyle(.plain)
            .padding(10)
            .help(L("Hide this explainer"))
            .accessibilityLabel(Text(L("Hide this explainer")))
        }
        .task(id: stage) { await autoAdvance() }
    }

    // MARK: - Copy and steps

    private var copy: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "square.on.square.dashed")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.accentColor)
                Text(L("What is a template?"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
            }
            Text(L("A portable copy of how an agent is set up, ready to share or reuse."))
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(AgentTemplatesIntroStage.allCases) { candidate in
                    stepRow(candidate)
                }
            }
            .padding(.top, 2)
        }
    }

    /// One step. The active row grows to show its caption and carries a
    /// thin progress line that sweeps over the hold interval, so the card
    /// reads as a small guided tour rather than a static list.
    private func stepRow(_ candidate: AgentTemplatesIntroStage) -> some View {
        let selected = candidate == stage
        return Button {
            advance(to: candidate)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(selected ? theme.accentColor : theme.secondaryText.opacity(0.18))
                        .frame(width: 16, height: 16)
                    Text(verbatim: "\(candidate.rawValue + 1)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(selected ? Color.white : theme.secondaryText)
                }
                .padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.title)
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? theme.primaryText : theme.secondaryText)
                    if selected {
                        Text(candidate.caption)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.secondaryText)
                            .lineSpacing(1)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.opacity)
                        // Progress line under the caption, remounted per
                        // stage so it restarts on every jump.
                        IntroStepProgress(
                            running: !reduceMotion,
                            duration: candidate.holdDuration,
                            color: theme.accentColor.opacity(0.45),
                            track: theme.secondaryText.opacity(0.14)
                        )
                        .frame(height: 2)
                        .padding(.top, 2)
                        .id(stage)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? theme.accentColor.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: stage)
    }

    // MARK: - Diagram

    private var diagram: some View {
        GeometryReader { proxy in
            let scale = min(1, proxy.size.width / Self.canvasDesignSize.width)
            AgentTemplatesIntroCanvas(stage: stage, reduceMotion: reduceMotion)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(
                    width: Self.canvasDesignSize.width * scale,
                    height: Self.canvasDesignSize.height * scale,
                    alignment: .topLeading
                )
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .aspectRatio(Self.canvasDesignSize.width / Self.canvasDesignSize.height, contentMode: .fit)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.secondaryBackground.opacity(theme.isDark ? 0.55 : 0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.primaryBorder.opacity(0.35), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { advance(to: stage.next) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L("Templates explainer diagram")))
        .accessibilityValue(Text(stage.title))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text(L("Shows the next step")))
        // Keep the close button clear of the diagram corner.
        .padding(.trailing, 20)
    }

    // MARK: - Behaviour

    private func advance(to target: AgentTemplatesIntroStage) {
        if reduceMotion {
            stage = target
        } else {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.82)) {
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
            withAnimation(.linear(duration: seconds)) { fraction = 1 }
        }
    }
}

// MARK: - Canvas

/// Every element derives its position, opacity and glyph from `stage`
/// alone, so the scene is a pure function of state and animates between
/// beats with one implicit animation.
private struct AgentTemplatesIntroCanvas: View {
    let stage: AgentTemplatesIntroStage
    let reduceMotion: Bool

    @Environment(\.theme) private var theme

    /// Flipped on first appearance to drive the stage 1 build-up.
    @State private var appeared = false

    /// One row of the agent's setup. These are what a template carries.
    private struct Setting: Identifiable {
        let id: Int
        let label: String
        let glyph: String
    }

    private static let settings: [Setting] = [
        Setting(id: 0, label: L("System Prompt"), glyph: "text.alignleft"),
        Setting(id: 1, label: L("Model"), glyph: "cube"),
        Setting(id: 2, label: L("Tools"), glyph: "wrench.and.screwdriver"),
        Setting(id: 3, label: L("Working Folder"), glyph: "folder"),
    ]

    /// What deliberately stays behind when a template is saved.
    private struct Kept: Identifiable {
        let id: Int
        let label: String
        let glyph: String
    }

    private static let kept: [Kept] = [
        Kept(id: 0, label: L("Files"), glyph: "doc.fill"),
        Kept(id: 1, label: L("Keys"), glyph: "key.fill"),
        Kept(id: 2, label: L("Chats"), glyph: "bubble.left.and.bubble.right.fill"),
    ]

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

    // Fixed geometry on a 420 x 160 canvas. The agent card stands on the
    // left, the template document in the middle, and the destination
    // (share channels, then the other Mac) on the right.
    private enum Layout {
        static let midY: CGFloat = 80
        static let settingWidth: CGFloat = 110
        static let settingHeight: CGFloat = 24
        static let settingGap: CGFloat = 6
        /// Left agent card: four rows stacked inside a frame.
        static let agentX: CGFloat = 70
        static func agentRowY(_ index: Int) -> CGFloat { 40 + CGFloat(index) * (settingHeight + settingGap) }
        /// Template document in the middle, rows stack tighter inside it.
        static let docX: CGFloat = 210
        static let docWidth: CGFloat = 130
        static let docHeight: CGFloat = 136
        static func docRowY(_ index: Int) -> CGFloat { 48 + CGFloat(index) * 27 }
        /// "Stays on your Mac" cluster under the collapsed agent frame.
        static func keptX(_ index: Int) -> CGFloat { agentX + (CGFloat(index) - 1) * 44 }
        static let keptY: CGFloat = 104
        static let keptTagY: CGFloat = 146
        /// Share channels on the right.
        static let channelX: CGFloat = 350
        static let channelWidth: CGFloat = 110
        static func channelY(_ index: Int) -> CGFloat { 50 + CGFloat(index) * 30 }
        /// The other Mac in the last beat.
        static let macX: CGFloat = 350
        static func macRowY(_ index: Int) -> CGFloat { 40 + CGFloat(index) * (settingHeight + settingGap) }
        /// Arrow centres between the three columns; the last one sits past
        /// the shrunk, shifted document.
        static let saveArrowX: CGFloat = 140
        static let shareArrowX: CGFloat = 280
        static let reuseArrowX: CGFloat = 272
    }

    private var animation: Animation? {
        reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.82)
    }

    var body: some View {
        ZStack {
            agentFrame
            ForEach(Self.settings) { setting in settingPill(setting) }
            ForEach(Self.kept) { item in keptChip(item) }
            keptTag
            templateDocument
            ForEach(Self.channels) { channel in channelPill(channel) }
            otherMac
            flowArrows
        }
        .frame(width: 420, height: 160)
        .clipped()
        .animation(animation, value: stage)
        .onAppear { appeared = true }
    }

    // MARK: Agent card (stages 1 to 3)

    private var agentFrame: some View {
        let visible = appeared && stage != .reuse
        let collapsed = stage == .save || stage == .share
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.accentColor)
                Text(L("Invoice Bot"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            Spacer(minLength: 0)
        }
        .frame(width: Layout.settingWidth + 20, height: collapsed ? 28 : 4 * (Layout.settingHeight + Layout.settingGap) + 30)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.accentColor.opacity(0.45), lineWidth: 1)
        )
        .scaleEffect(visible ? 1 : 0.7)
        .opacity(visible ? 1 : 0)
        .position(x: Layout.agentX, y: collapsed ? 26 : Layout.midY)
    }

    /// A setting row. Lives inside the agent card in beat 1, travels into
    /// the template document in beat 2 and stays there, and is copied back
    /// out onto the other Mac in beat 4.
    private func settingPill(_ setting: Setting) -> some View {
        let visible = appeared
        let inDoc = stage == .save || stage == .share || stage == .reuse
        // On the other Mac, model and folder are the two that need a local
        // choice; the wizard asks for those, the rest is already right.
        let needsChoice = stage == .reuse && (setting.id == 1 || setting.id == 3)
        return pill(
            label: setting.label,
            glyph: needsChoice ? "questionmark.circle" : setting.glyph,
            width: inDoc ? Layout.docWidth - 20 : Layout.settingWidth,
            tint: needsChoice ? theme.warningColor : theme.accentColor,
            subtle: inDoc && stage != .reuse
        )
        .scaleEffect(visible ? 1 : 0.6)
        .opacity(visible ? 1 : 0)
        .position(settingPosition(setting))
        .animation(staggered(setting.id), value: stage)
        .animation(staggered(setting.id), value: appeared)
    }

    private func settingPosition(_ setting: Setting) -> CGPoint {
        switch stage {
        case .agent:
            return CGPoint(x: Layout.agentX, y: Layout.agentRowY(setting.id) + 8)
        case .save, .share:
            return CGPoint(x: Layout.docX, y: Layout.docRowY(setting.id) + 6)
        case .reuse:
            return CGPoint(x: Layout.macX, y: Layout.macRowY(setting.id) + 8)
        }
    }

    private static let staggerInterval: Double = 0.12
    private func staggered(_ index: Int) -> Animation? {
        animation?.delay(Double(index) * Self.staggerInterval)
    }

    // MARK: Stays on your Mac (stage 2)

    private func keptChip(_ item: Kept) -> some View {
        let visible = stage == .save
        return VStack(spacing: 3) {
            ZStack {
                Circle()
                    .fill(theme.successColor.opacity(0.14))
                    .frame(width: 26, height: 26)
                Image(systemName: item.glyph)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.successColor)
            }
            Text(item.label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(theme.secondaryText)
        }
        .overlay(alignment: .topTrailing) {
            Image(systemName: "lock.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(theme.successColor)
                .offset(x: 4, y: -2)
        }
        .scaleEffect(visible ? 1 : 0.6)
        .opacity(visible ? 1 : 0)
        .position(x: Layout.keptX(item.id), y: visible ? Layout.keptY : Layout.keptY + 16)
        .animation(staggered(item.id + 2), value: stage)
    }

    private var keptTag: some View {
        let visible = stage == .save
        return Text(L("Stays on your Mac"))
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(theme.successColor)
            .opacity(visible ? 1 : 0)
            .position(x: Layout.agentX, y: Layout.keptTagY)
    }

    // MARK: Template document (stages 2 to 4)

    private var templateDocument: some View {
        let visible = stage != .agent
        // Steps aside in the last beat, making room for the flow onto the
        // other Mac, but stays as the source the new agent is built from.
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "square.on.square.dashed")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.accentColor)
                Text(L("Template"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                Spacer(minLength: 0)
                Text(verbatim: ".json")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.tertiaryText)
            }
            .padding(.horizontal, 12)
            .frame(height: 26)
            Spacer(minLength: 0)
        }
        .frame(width: Layout.docWidth, height: Layout.docHeight)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
        )
        .scaleEffect(visible ? (stage == .reuse ? 0.85 : 1) : 0.7)
        .opacity(visible ? (stage == .reuse ? 0.6 : 1) : 0)
        .position(x: stage == .reuse ? Layout.docX - 12 : Layout.docX, y: Layout.midY)
    }

    // MARK: Share channels (stage 3)

    private func channelPill(_ channel: Channel) -> some View {
        let visible = stage == .share
        return pill(label: channel.label, glyph: channel.glyph, width: Layout.channelWidth, tint: theme.infoColor)
            .scaleEffect(visible ? 1 : 0.7)
            .opacity(visible ? 1 : 0)
            .position(x: visible ? Layout.channelX : Layout.channelX + 30, y: Layout.channelY(channel.id))
            .animation(staggered(channel.id), value: stage)
    }

    // MARK: The other Mac (stage 4)

    private var otherMac: some View {
        let visible = stage == .reuse
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.successColor)
                Text(L("Another Mac"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            Spacer(minLength: 0)
        }
        .frame(width: Layout.settingWidth + 20, height: 4 * (Layout.settingHeight + Layout.settingGap) + 30)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.successColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.successColor.opacity(0.5), lineWidth: 1)
        )
        .scaleEffect(visible ? 1 : 0.7)
        .opacity(visible ? 1 : 0)
        .position(x: visible ? Layout.macX : Layout.macX + 40, y: Layout.midY)
    }

    // MARK: Arrows

    private var flowArrows: some View {
        ZStack {
            // Agent → template (beat 2), template → channels (beat 3),
            // template → other Mac (beat 4).
            arrow(visible: stage == .save, x: Layout.saveArrowX)
            arrow(visible: stage == .share || stage == .reuse, x: stage == .reuse ? Layout.reuseArrowX : Layout.shareArrowX)
        }
    }

    private func arrow(visible: Bool, x: CGFloat) -> some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(theme.secondaryText)
            .opacity(visible ? 1 : 0)
            .scaleEffect(visible ? 1 : 0.6)
            .position(x: x, y: Layout.midY)
    }

    // MARK: Pill

    private func pill(label: String, glyph: String, width: CGFloat, tint: Color, subtle: Bool = false) -> some View {
        HStack(spacing: 7) {
            Image(systemName: glyph)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 14)
                .contentTransition(.symbolEffect(.replace))
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(subtle ? theme.secondaryText : theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(width: width, height: Layout.settingHeight)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(subtle ? theme.secondaryBackground : theme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(subtle ? theme.primaryBorder.opacity(0.35) : tint.opacity(0.45), lineWidth: 1)
        )
    }
}
