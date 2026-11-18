//
//  OnboardingClassicUpgradeView.swift
//  osaurus
//
//  The upgrade screen for someone who updated from Classic: their chats,
//  agents, and settings came with them, but the starter team and default
//  workflows did not. One glass card offers the team (Add starter team)
//  or leaves everything as it is (Keep my setup). A switch on the same card
//  downloads Raptor 0.7 when it is not on this Mac yet.
//

import SwiftUI

// MARK: - State

@MainActor
final class ClassicUpgradeState: ObservableObject {
    /// The teammates Add Starter Team creates on this Mac.
    let roster: [Teammate]
    /// Raptor 0.7 when this Mac can run it and does not have it yet.
    let raptor: MLXModel?
    let raptorCompatibility: ModelCompatibility?
    /// Shown only while usage consent is undecided (an upgrader who never
    /// made the choice); otherwise the earlier choice stands.
    let asksUsageConsent: Bool

    @Published var downloadRaptor: Bool
    @Published var shareUsageData = true
    /// Inline "not enough disk space" warning under the Raptor switch.
    @Published var diskWarning: String?
    private(set) var startedRaptorDownload = false

    init(
        roster: [Teammate],
        raptorOffer: RaptorOffer?,
        asksUsageConsent: Bool
    ) {
        self.roster = roster
        self.raptor = raptorOffer?.model
        self.raptorCompatibility = raptorOffer?.compatibility
        self.downloadRaptor = raptorOffer?.onByDefault ?? false
        self.asksUsageConsent = asksUsageConsent
    }

    /// Reads this Mac: its roster, whether to offer Raptor 0.7, and whether
    /// usage consent is still undecided. No Raptor offer when the
    /// Orchestrator has no model yet: Configure AI runs then and offers it.
    static func live() -> ClassicUpgradeState {
        let roster = TeamSeeder.Options(
            developerMac: DeveloperMacSignal.isDeveloperMac(),
            brainIsLocal: false,
            excludedTeammates: BundleOnboardingPreferences.effective.excludeTeammates
        ).teammates
        let offer =
            AgentManager.shared.effectiveModel(for: Agent.defaultId) == nil
            ? nil
            : raptorOffer(
                from: ModelManager.shared.deduplicatedModels(),
                totalMemoryGB: SystemMonitorService.shared.totalMemoryGB)
        return ClassicUpgradeState(
            roster: roster,
            raptorOffer: offer,
            asksUsageConsent: TelemetryService.shared.needsConsentDecision)
    }

    struct RaptorOffer {
        let model: MLXModel
        let compatibility: ModelCompatibility
        let onByDefault: Bool
    }

    /// Raptor 0.7 is offered when the catalog carries it, it is not on disk,
    /// and it is not too big for this Mac. On by default only when it runs
    /// comfortably.
    static func raptorOffer(from candidates: [MLXModel], totalMemoryGB: Double) -> RaptorOffer? {
        guard let model = candidates.first(where: { $0.id == ConfigureAIState.preferredOnboardingModelId }),
            !RaptorUpgrade.isLoadable(model)
        else { return nil }
        let compatibility = model.compatibility(totalMemoryGB: totalMemoryGB)
        guard compatibility != .tooLarge else { return nil }
        return RaptorOffer(model: model, compatibility: compatibility, onByDefault: compatibility == .compatible)
    }

    /// Starts the Raptor download when the switch is on. Returns `false`
    /// when it will not fit: the warning shows, the switch turns off, and
    /// the person decides again.
    func startRaptorDownloadIfChosen() -> Bool {
        guard downloadRaptor, !startedRaptorDownload, let raptor else { return true }
        if let warning = ConfigureAIState.diskShortfallWarning(
            for: raptor, freeBytes: ConfigureAIState.queryFreeDiskBytes())
        {
            diskWarning = warning
            downloadRaptor = false
            return false
        }
        diskWarning = nil
        RaptorUpgrade.markPending()
        ModelManager.shared.downloadModel(raptor, route: .onboardingProxy)
        startedRaptorDownload = true
        return true
    }

    /// "3.68 GB" and how well it fits this Mac, as separate pieces so the
    /// fit can take its own colour.
    var raptorSize: String? { raptor?.formattedDownloadSize }
    var raptorFit: String? { raptorCompatibility.flatMap(ConfigureAIState.fitLabel) }
}

private extension Teammate {
    var displayName: String { rawValue.capitalized }
}

// MARK: - Chapter view

struct ClassicUpgradeChapterView: View {
    @Environment(\.theme) private var theme

    @ObservedObject var state: ClassicUpgradeState
    @ObservedObject var stage: OnboardingStage
    let onAddTeam: () -> Void
    let onKeep: () -> Void

    var body: some View {
        OnboardingGreetingLayout(stage: stage) { card }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: theme.space.s0) {
            carriedOver

            Divider()
                .overlay(OnboardingPalette.fill10)
                .padding(.vertical, theme.space.s12)

            Text("New in 1.0", bundle: .module)
                .font(OnboardingTypography.badge)
                .foregroundColor(OnboardingPalette.dinoGreenText)
                .textCase(.uppercase)
            Spacer().frame(height: theme.space.s4)
            Text("Meet your starter team", bundle: .module)
                .font(OnboardingTypography.cardTitle)
                .foregroundColor(OnboardingPalette.labelPrimary)
            Spacer().frame(height: theme.space.s6)
            Text(
                "Each teammate handles one part of your Mac, like your calendar, Mail, or files. Ask Osaurus anything and it passes the job to the right one.",
                bundle: .module
            )
            .font(OnboardingTypography.subtitle)
            .foregroundColor(OnboardingPalette.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)

            if !state.roster.isEmpty {
                Spacer().frame(height: theme.space.s16)
                teamStrip
            }

            Spacer().frame(height: theme.space.s16)
            Text(
                "Ready-made workflows come too, like Morning Brief and Mail Triage. They run only when you start them.",
                bundle: .module
            )
            .font(OnboardingTypography.cardCaption)
            .foregroundColor(OnboardingPalette.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)

            if state.raptor != nil {
                Divider()
                    .overlay(OnboardingPalette.fill10)
                    .padding(.vertical, theme.space.s12)
                raptorRow
            }

            Spacer().frame(height: theme.space.s20)

            HStack(spacing: theme.space.s8) {
                OnboardingPillButton(
                    title: "Add starter team",
                    style: .primary,
                    size: .large,
                    trailingSymbol: "arrow.right",
                    action: onAddTeam
                )
                OnboardingPillButton(
                    title: "Keep my setup",
                    style: .secondary,
                    size: .large,
                    action: onKeep
                )
            }

            if !state.asksUsageConsent {
                Spacer().frame(height: theme.space.s10)
                Text("Keep my setup changes nothing. You can add the team later in Settings.", bundle: .module)
                    .font(OnboardingTypography.footnote)
                    .foregroundColor(OnboardingPalette.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if state.asksUsageConsent {
                Divider()
                    .overlay(OnboardingPalette.fill10)
                    .padding(.vertical, theme.space.s12)

                OnboardingSwitchRow(
                    isOn: $state.shareUsageData,
                    title: "Share anonymous usage data",
                    caption: "Optional. Helps improve Osaurus. Never includes your chats, prompts, files, or keys."
                )
            }
        }
        .padding(theme.space.s24)
        .frame(width: OnboardingLayout.helloCardWidth, alignment: .leading)
        .background(OnboardingGlass(cornerRadius: OnboardingLayout.panelRadius))
        .onboardingEntrance(1)
    }

    /// What Classic left behind: all of it.
    private var carriedOver: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.space.s8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(OnboardingPalette.dinoGreenText)
            Text("Your chats, agents, and settings came with you.", bundle: .module)
                .font(OnboardingTypography.subtitle)
                .foregroundColor(OnboardingPalette.labelPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// The teammates as the sidebar will show them, each badged with its job.
    private var teamStrip: some View {
        HStack(alignment: .top, spacing: theme.space.s4) {
            ForEach(state.roster, id: \.self) { teammate in
                VStack(spacing: theme.space.s6) {
                    OnboardingTeammateAvatar(
                        mascotId: teammate.avatar.rawValue, name: teammate.displayName,
                        roleSymbol: teammate.symbol, size: 36)
                    Text(verbatim: teammate.displayName)
                        .font(OnboardingTypography.cardCaption)
                        .foregroundColor(OnboardingPalette.labelPrimary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .help(teammate.role)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "\(teammate.displayName), \(teammate.role)"))
            }
        }
    }

    private var raptorRow: some View {
        VStack(alignment: .leading, spacing: theme.space.s6) {
            HStack(alignment: .center, spacing: theme.space.s12) {
                VStack(alignment: .leading, spacing: theme.space.s2) {
                    Text("Get Raptor 0.7", bundle: .module)
                        .font(OnboardingTypography.optionTitle)
                        .foregroundColor(OnboardingPalette.labelPrimary)
                    raptorFacts
                }
                Spacer(minLength: 0)
                Toggle(isOn: $state.downloadRaptor) { Text("Get Raptor 0.7", bundle: .module) }
                    .settingsSwitch()
            }
            .accessibilityElement(children: .combine)

            Text(
                "The newest local model built for Osaurus agents. Agents on an older Raptor move to it once it's downloaded.",
                bundle: .module
            )
            .font(OnboardingTypography.cardCaption)
            .foregroundColor(OnboardingPalette.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)

            if let warning = state.diskWarning {
                Text(verbatim: warning)
                    .font(OnboardingTypography.cardCaption)
                    .foregroundColor(OnboardingPalette.warningLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "3.68 GB · Runs smoothly here", the fit tinted when it is tight.
    @ViewBuilder
    private var raptorFacts: some View {
        HStack(spacing: theme.space.s4) {
            if let size = state.raptorSize {
                Text(verbatim: size)
                    .foregroundColor(OnboardingPalette.labelSecondary)
            }
            if state.raptorSize != nil, state.raptorFit != nil {
                Text(verbatim: "·").foregroundColor(OnboardingPalette.labelSecondary).accessibilityHidden(true)
            }
            if let fit = state.raptorFit {
                Text(verbatim: fit)
                    .foregroundColor(
                        state.raptorCompatibility == .tight ? OnboardingPalette.fitTight : OnboardingPalette.dinoGreenText)
            }
        }
        .font(OnboardingTypography.cardCaption)
    }
}
