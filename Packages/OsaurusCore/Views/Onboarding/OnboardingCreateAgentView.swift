//
//  OnboardingCreateAgentView.swift
//  osaurus
//
//  Onboarding step 2 — a delightful, low-friction "Meet your dino" step.
//  The user picks an avatar and an archetype and can tweak the name right
//  in the badge; the system prompt is derived from the chosen archetype,
//  and everything is editable later in Settings. Split into:
//    - `CreateAgentState`: ObservableObject holding the selections + name
//      (lives in OnboardingView via @StateObject, so values survive slide
//      transitions).
//    - `CreateAgentBody`: the single-column body slot (hero dino + editable
//      name badge + role description + avatar picker + archetype picker).
//    - `CreateAgentCTA`: the primary "Create Dino" footer button.
//

import SwiftUI

// MARK: - State

@MainActor
final class CreateAgentState: ObservableObject {
    /// Defaults to the general-purpose `.assistant` so a user who just wants
    /// to move on can tap "Create Dino" immediately.
    @Published var selectedTemplate: AgentStarterTemplate = .assistant
    @Published var selectedAvatar: String? = AgentMascot.allCases.first?.id
    /// Editable name, surfaced as the badge under the hero. Seeded from the
    /// archetype and kept in sync until the user types their own.
    @Published var name: String
    /// Flips to `true` once the user edits the name, so switching archetypes
    /// stops clobbering their input.
    @Published var nameUserEdited: Bool = false
    @Published var isSaving: Bool = false

    /// ID of the agent created by `saveAgent`. Read by
    /// `OnboardingView.finishOnboarding` to flip
    /// `AgentManager.activeAgentId` so the user lands in chat with the
    /// agent they just made already selected.
    @Published private(set) var createdAgentId: UUID?

    init() {
        name = AgentStarterTemplate.assistant.defaultName
    }

    /// Always savable — selections always have a default and the name falls
    /// back to the archetype default, so the CTA is enabled immediately.
    var canSave: Bool { !isSaving }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resolved name actually persisted: the user's text, or the archetype
    /// default when they've left it blank.
    var resolvedName: String {
        trimmedName.isEmpty ? selectedTemplate.defaultName : trimmedName
    }

    /// Select an archetype. The name follows the archetype's default until
    /// the user types their own, at which point presets stop touching it.
    func selectArchetype(_ template: AgentStarterTemplate) {
        selectedTemplate = template
        if !nameUserEdited {
            name = template.defaultName
        }
    }

    /// Curated pool of playful names for the "randomize" affordance on the
    /// name badge. These are proper nouns, so they're set directly into
    /// `name` and never run through `LocalizedStringKey`.
    static let funNames = [
        "Rexford", "Spike", "Nibbles", "Pebbles", "Tito",
        "Stompy", "Pip", "Biscuit", "Magnus", "Coco",
        "Dino", "Bruno", "Sunny", "Fern", "Bramble", "Ziggy",
    ]

    /// Picks a fun name distinct from the current one. Marks the name as
    /// user-edited so a later archetype switch doesn't clobber it (mirrors
    /// the guard in `selectArchetype`).
    func randomizeName() {
        let pool = Self.funNames.filter { $0 != trimmedName }
        name = pool.randomElement() ?? Self.funNames[0]
        nameUserEdited = true
    }

    /// Persists the agent and returns whether save succeeded. The caller is
    /// responsible for advancing the flow afterwards.
    ///
    /// The system prompt is derived from the chosen archetype and the
    /// description from its tagline; both are editable later in Settings.
    ///
    /// Idempotent: if the user navigates back from a later onboarding
    /// step and re-fires the CTA, the previously-created agent's id is
    /// returned as success without spawning a duplicate `AgentManager`
    /// entry.
    @discardableResult
    func saveAgent() -> Bool {
        if createdAgentId != nil { return true }
        guard !isSaving else { return false }
        isSaving = true
        let agent = Agent(
            id: UUID(),
            name: resolvedName,
            description: selectedTemplate.tagline,
            systemPrompt: selectedTemplate.systemPrompt,
            createdAt: Date(),
            updatedAt: Date(),
            autonomousExec: AgentManager.sandboxDefaultAutonomousExec,
            toolSelectionMode: .auto,
            avatar: selectedAvatar
        )
        AgentManager.shared.add(agent)
        createdAgentId = agent.id
        isSaving = false
        return true
    }
}

// MARK: - Body

struct CreateAgentBody: View {
    @ObservedObject var state: CreateAgentState

    @Environment(\.theme) private var theme
    /// Honors the system "Reduce Motion" preference: the playful spin, name
    /// pop, and hero wiggle all collapse to the plain swap when this is on.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var nameFocused: Bool
    /// Width the name field is pinned to, measured from a hidden copy of the
    /// displayed text. Pinning the field stops AppKit's field editor from
    /// nudging the intrinsic width when focus toggles, which (combined with
    /// the badge-wide focus animation) read as a small jiggle.
    @State private var nameFieldWidth: CGFloat = 0
    /// Monotonic count of "roll a name" taps. Drives the accumulating icon
    /// spin so it always rolls forward a full turn and never unwinds backward.
    @State private var randomizeSpins: Int = 0
    /// Raised for a single frame burst on each roll and relaxed shortly after
    /// by `rollName`. One flag drives the icon pop, the name bounce, and the
    /// hero wiggle together so the whole badge reacts as one beat.
    @State private var isRolling: Bool = false

    /// The selected dino's signature color — themes the hero glow, avatar
    /// tints, and selection rings so the whole screen reacts in color.
    private var selectedColor: Color {
        state.selectedAvatar
            .flatMap(AgentMascot.init(rawValue:))?
            .color ?? theme.accentColor
    }

    /// Centralized layout rhythm + sizing. Kept together so the vertical
    /// spacing and hero / swatch dimensions stay consistent and are easy to
    /// retune as a set — the step is hand-fit to the fixed onboarding window.
    private enum Layout {
        static let contentMaxWidth: CGFloat = 700
        static let heroDiameter: CGFloat = 132
        static let taglineMaxWidth: CGFloat = 560
        static let swatchDiameter: CGFloat = 56
        static let swatchCell: CGFloat = 66
        static let swatchSpacing: CGFloat = 12

        /// Slack added to the measured name width so the caret at the end of
        /// the text isn't clipped while the field stays focus-stable.
        static let nameCaretAllowance: CGFloat = 4

        // Vertical rhythm between the centered content groups.
        static let heroToBadge: CGFloat = 16
        static let badgeToTagline: CGFloat = 10
        static let sectionGap: CGFloat = 22
    }

    /// Tuning for the "roll a name" delight, grouped so the motion reads as a
    /// single coordinated beat and stays easy to retune together.
    private enum RollMotion {
        /// Full-turn icon spin; springy so it overshoots and settles.
        static let spin = Animation.spring(response: 0.5, dampingFraction: 0.55)
        /// Pop used for the icon and name bounce.
        static let pop = Animation.spring(response: 0.32, dampingFraction: 0.5)
        /// Looser spring so the hero tilt wobbles back to center.
        static let wiggle = Animation.spring(response: 0.4, dampingFraction: 0.35)

        static let iconScale: CGFloat = 1.22
        static let nameScale: CGFloat = 1.16
        static let heroTilt: Double = 7

        /// How long the pop is held before it relaxes back to rest.
        static let crest: TimeInterval = 0.16
    }

    /// Non-scrolling, vertically-centered layout. The step is intentionally
    /// sized to fit the fixed onboarding window without scrolling — the
    /// "edit later" hint lives in the footer caption slot (see
    /// `OnboardingView.chromeFooterCaption`) so it never crowds the body.
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            heroDino

            Spacer().frame(height: Layout.heroToBadge)

            nameBadge

            Spacer().frame(height: Layout.badgeToTagline)

            tagline

            Spacer().frame(height: Layout.sectionGap)

            avatarRow

            Spacer().frame(height: Layout.sectionGap)

            archetypeRow

            Spacer(minLength: 0)
        }
        .frame(maxWidth: Layout.contentMaxWidth)
        .padding(.horizontal, OnboardingMetrics.rightColumnHorizontalPadding)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { nameFocused = false }
    }

    // MARK: - Hero dino

    /// Big, playful centerpiece that updates as the user picks an avatar or
    /// archetype. The bounce on change makes selection feel responsive and
    /// fun rather than form-like, and the glow adopts the dino's color.
    private var heroDino: some View {
        let diameter = Layout.heroDiameter
        return ZStack {
            Circle()
                .fill(selectedColor.opacity(theme.isDark ? 0.32 : 0.20))
                .frame(width: diameter + 52, height: diameter + 52)
                .blur(radius: 28)
                .animation(theme.animationQuick(), value: selectedColor)

            AgentAvatarView(
                mascotId: state.selectedAvatar,
                name: state.resolvedName,
                tint: selectedColor,
                diameter: diameter,
                monogramFontSize: 44,
                borderWidth: 2.5,
                bleedsToEdge: true
            )
            .shadow(
                color: selectedColor.opacity(theme.isDark ? 0.36 : 0.24),
                radius: 22,
                x: 0,
                y: 10
            )
            .id(state.selectedAvatar)
            .transition(.scale.combined(with: .opacity))
            // Springy tilt that wobbles back to center, so rolling a name
            // makes the dino feel like it's reacting to its new identity.
            .rotationEffect(.degrees(isRolling ? RollMotion.heroTilt : 0))
            .animation(RollMotion.wiggle, value: isRolling)
        }
        .frame(height: diameter + 12)
        .animation(.spring(response: 0.42, dampingFraction: 0.62), value: state.selectedAvatar)
    }

    // MARK: - Editable name badge

    /// The name, surfaced as the prominent capsule badge under the hero. The
    /// archetype icon on the leading edge doubles as a "randomize" button that
    /// rolls a fun dino name; the text stays editable and a faint pencil hints
    /// at that.
    private var nameBadge: some View {
        HStack(spacing: 8) {
            Button {
                rollName()
            } label: {
                Image(systemName: state.selectedTemplate.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(selectedColor)
                    // Each tap adds a full clockwise turn; the value only ever
                    // grows, so the spring rolls forward and never rewinds.
                    .rotationEffect(.degrees(Double(randomizeSpins) * 360))
                    .animation(RollMotion.spin, value: randomizeSpins)
                    // A quick squash-and-pop on press reads as "roll the dice".
                    .scaleEffect(isRolling ? RollMotion.iconScale : 1)
                    .animation(RollMotion.pop, value: isRolling)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(Text("Pick a random name", bundle: .module))

            ZStack {
                nameWidthDriver.hidden()

                TextField(text: $state.name, prompt: defaultNameText) { defaultNameText }
                    .textFieldStyle(.plain)
                    .font(theme.font(size: 19, weight: .bold))
                    .foregroundColor(theme.primaryText)
                    .multilineTextAlignment(.center)
                    // Pin to the measured text width (+ caret room) so focusing
                    // never changes the field's footprint.
                    .frame(width: nameFieldWidth + Layout.nameCaretAllowance)
                    // Bounce the rolled name in. `scaleEffect` doesn't affect
                    // layout, so the pinned field width stays stable.
                    .scaleEffect(isRolling ? RollMotion.nameScale : 1)
                    .animation(RollMotion.pop, value: isRolling)
                    .focused($nameFocused)
                    .onChange(of: state.name) { _, newValue in
                        if newValue != state.selectedTemplate.defaultName {
                            state.nameUserEdited = true
                        }
                    }
            }
            .onPreferenceChange(NameWidthKey.self) { nameFieldWidth = $0 }

            Image(systemName: "pencil")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
                .opacity(nameFocused ? 0 : 0.7)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(
            Capsule().fill(selectedColor.opacity(nameFocused ? 0.18 : 0.12))
        )
        .overlay(
            Capsule().strokeBorder(
                selectedColor.opacity(nameFocused ? 0.7 : 0.3),
                lineWidth: nameFocused ? 2 : 1
            )
        )
        .animation(theme.animationQuick(), value: nameFocused)
        .animation(theme.animationQuick(), value: selectedColor)
        .contentShape(Capsule())
        .onTapGesture { nameFocused = true }
    }

    /// Rolls a fresh fun name and fires the coordinated delight: the icon
    /// spins a full turn and pops, the new name bounces in, and the hero gives
    /// a little wiggle (all driven by the `.animation(_:value:)` modifiers on
    /// those views). Under Reduce Motion this collapses to the plain swap.
    private func rollName() {
        state.randomizeName()
        guard !reduceMotion else { return }

        randomizeSpins += 1
        isRolling = true
        // Release the pop so the icon, name, and hero settle back to rest.
        DispatchQueue.main.asyncAfter(deadline: .now() + RollMotion.crest) {
            isRolling = false
        }
    }

    /// The archetype's localized default name. Shared by the field's prompt
    /// and the width driver so the empty field is sized to the hint it shows.
    private var defaultNameText: Text {
        Text(LocalizedStringKey(state.selectedTemplate.defaultName), bundle: .module)
    }

    /// Invisible mirror of the field's displayed text, styled identically, used
    /// purely to measure the width the editable field should be pinned to. When
    /// the user has typed a name we measure that; otherwise we measure the
    /// archetype's default (the prompt) so the empty field matches its hint.
    private var nameWidthDriver: some View {
        (state.trimmedName.isEmpty ? defaultNameText : Text(state.name))
            .font(theme.font(size: 19, weight: .bold))
            .fixedSize()
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: NameWidthKey.self, value: proxy.size.width)
                }
            )
    }

    // MARK: - Role description preview

    private var tagline: some View {
        Text(LocalizedStringKey(state.selectedTemplate.tagline), bundle: .module)
            .font(theme.font(size: 14))
            .foregroundColor(theme.secondaryText)
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            // Wide enough that every role's tagline stays on one line, so the
            // layout doesn't jump (and feel crowded) when switching roles.
            .frame(maxWidth: Layout.taglineMaxWidth)
            .id(state.selectedTemplate)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
            .animation(theme.animationQuick(), value: state.selectedTemplate)
    }

    // MARK: - Avatar picker

    /// Six mascots as a centered row of tappable swatches. The create flow
    /// always picks a colorful mascot so the row of cute dinos reads as the
    /// brand — the monogram/no-avatar option lives in Settings.
    private var avatarRow: some View {
        // Tighter label gap than the role row: the swatch cells are taller
        // than their circles (`cellSize` > `diameter`), so this offsets that
        // built-in top inset and keeps the label→content gap visually equal
        // to the role chips below.
        VStack(spacing: OnboardingMetrics.labelToInput) {
            sectionLabel("Pick a color")
            HStack(spacing: Layout.swatchSpacing) {
                ForEach(AgentMascot.allCases) { mascot in
                    avatarChip(mascot: mascot)
                }
            }
        }
    }

    private func avatarChip(mascot: AgentMascot) -> some View {
        let isSelected = state.selectedAvatar == mascot.id
        let diameter = Layout.swatchDiameter
        let cellSize = Layout.swatchCell
        return Button {
            withAnimation(theme.animationQuick()) {
                state.selectedAvatar = mascot.id
            }
        } label: {
            ZStack {
                if isSelected {
                    Circle()
                        .fill(mascot.color.opacity(0.3))
                        .frame(width: diameter + 16, height: diameter + 16)
                        .blur(radius: 8)
                }

                AgentAvatarView(
                    mascotId: mascot.id,
                    name: "",
                    tint: mascot.color,
                    diameter: diameter,
                    monogramFontSize: 18,
                    borderWidth: 1.5,
                    bleedsToEdge: true
                )
                .overlay(
                    Circle()
                        .strokeBorder(
                            isSelected ? mascot.color : Color.clear,
                            lineWidth: 2.5
                        )
                        .padding(-3)
                )
            }
            .frame(width: cellSize, height: cellSize)
            .scaleEffect(isSelected ? 1.0 : 0.9)
            .opacity(isSelected ? 1.0 : 0.78)
            // Lower damping gives the newly-picked swatch a celebratory
            // overshoot; Reduce Motion settles it without the bounce.
            .animation(
                .spring(response: 0.35, dampingFraction: reduceMotion ? 0.85 : 0.45),
                value: isSelected
            )
        }
        .buttonStyle(.plain)
        .help(Text(mascot.displayName))
    }

    // MARK: - Archetype picker

    /// Curated archetypes (excludes the from-scratch `.blank`) as a centered,
    /// wrapping row of chips. Selecting one drives the hero label, the
    /// description, and the agent's derived name + system prompt.
    private var archetypeRow: some View {
        VStack(spacing: OnboardingMetrics.labelToInput + 4) {
            sectionLabel("Pick a role")
            CenteredFlowLayout(spacing: 8, lineSpacing: 10) {
                ForEach(AgentStarterTemplate.onboardingArchetypes) { template in
                    archetypeChip(template)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func archetypeChip(_ template: AgentStarterTemplate) -> some View {
        let isSelected = state.selectedTemplate == template
        return Button {
            withAnimation(theme.animationQuick()) {
                state.selectArchetype(template)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: template.icon)
                    .font(.system(size: 15, weight: .semibold))
                Text(LocalizedStringKey(template.label), bundle: .module)
                    .font(theme.font(size: 15, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: OnboardingMetrics.buttonCornerRadius, style: .continuous)
                    .fill(isSelected ? theme.accentColor.opacity(0.12) : theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: OnboardingMetrics.buttonCornerRadius, style: .continuous)
                            .strokeBorder(
                                isSelected ? theme.accentColor.opacity(0.45) : theme.inputBorder,
                                lineWidth: isSelected ? 1.5 : 1
                            )
                    )
            )
            // A small overshooting pop on the freshly-picked role keeps the
            // chip selection feeling alive and in step with the swatches.
            .scaleEffect(isSelected ? 1.05 : 1)
            .animation(
                .spring(response: 0.32, dampingFraction: reduceMotion ? 0.85 : 0.5),
                value: isSelected
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func sectionLabel(_ key: String) -> some View {
        Text(LocalizedStringKey(key), bundle: .module)
            .font(theme.font(size: 12, weight: .semibold))
            .foregroundColor(theme.tertiaryText)
    }
}

// MARK: - Name Field Width Measurement

/// Carries the measured width of the hidden name mirror up to `CreateAgentBody`
/// so the editable field can be pinned to a focus-stable width.
private struct NameWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Centered Flow Layout

/// Minimal wrapping HStack: lays children left-to-right and wraps to the
/// next line when they'd overflow the proposed width, centering each line.
/// Used for the archetype chips so the curated set stays balanced and never
/// overflows the fixed onboarding window. (The shared `FlowLayout` in
/// Views/Common left-aligns rows; this one centers them for the playful,
/// centered onboarding step.)
private struct CenteredFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(maxWidth: maxWidth, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height =
            rows.map(\.height).reduce(0, +)
            + CGFloat(max(0, rows.count - 1)) * lineSpacing
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for item in row.items {
                let size = subviews[item].sizeThatFits(.unspecified)
                subviews[item].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let projected = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if !current.items.isEmpty && projected > maxWidth {
                rows.append(current)
                current = Row()
                current.items = [index]
                current.width = size.width
                current.height = size.height
            } else {
                if !current.items.isEmpty { current.width += spacing }
                current.items.append(index)
                current.width += size.width
                current.height = max(current.height, size.height)
            }
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - CTA

struct CreateAgentCTA: View {
    @ObservedObject var state: CreateAgentState
    let onContinue: () -> Void

    var body: some View {
        OnboardingBrandButton(
            title: "Create Dino",
            action: { if state.saveAgent() { onContinue() } },
            isEnabled: state.canSave
        )
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Preview

#if DEBUG
    struct OnboardingCreateAgentView_Previews: PreviewProvider {
        static var previews: some View {
            let state = CreateAgentState()
            return VStack {
                CreateAgentBody(state: state).frame(height: 520)
                CreateAgentCTA(state: state, onContinue: {})
            }
            .frame(width: OnboardingMetrics.windowWidth, height: 660)
        }
    }
#endif
