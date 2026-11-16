//
//  OnboardingPanel.swift
//  osaurus
//
//  What sits under the latest authored line: the teammate cards, a path's
//  request, its asks, and Back. Built from the plan and the
//  brain state on every rebuild, so a model landing or a grant changing
//  shows at once. A tap is an `OnboardingAction`; none generates.
//

import Foundation

enum OnboardingAction: Hashable, Sendable {
    case selectPath(String)
    case back
    /// Skips the current step. Discovery panels: Not Now.
    case skip
    /// Ends setup from any step of the walkthrough: Skip setup.
    case dismissSetup
    /// The chosen path's request: a permission, Downloads, or a folder.
    case request
    case openSettings(SystemPermission)
    /// System Settings → Privacy & Security → Files & Folders, for Downloads.
    case openFilesAndFolders
    case ask(String)
    case topic(String)
    case chooseBrain
    /// After a task: the team's cards again.
    case exploreTeam
    /// After a task: done exploring, setup lets go.
    case doneExploring
    /// Takes the open discovery's next step.
    case discover
    /// Opens a discovery from the Set Up Osaurus list.
    case openDiscovery(DiscoveryItem)
}

struct OnboardingPanel: Equatable, Sendable {
    struct Card: Equatable, Sendable, Identifiable {
        let id: String
        let name: String
        let pitch: String
        let icon: String
        let note: String?
        /// What the teammate works with: Calendar, Mail, the web.
        let access: String?
        /// The agent's avatar, as the sidebar shows it.
        let mascotId: String?
        /// A picture set in place of the mascot.
        var imageURL: URL? = nil
    }

    struct Button: Equatable, Sendable, Identifiable {
        enum Style: Equatable, Sendable { case primary, ask, quiet }
        let action: OnboardingAction
        let title: String
        let icon: String?
        let style: Style
        var id: OnboardingAction { action }
    }

    /// Which part of the walkthrough the panel belongs to; the header's title.
    /// `explore` is the offer under a task's reply to meet someone else.
    enum Step: Equatable, Sendable { case brain, team, firstTask, explore }

    /// Osaurus itself, as the sidebar shows it: the last row of the team.
    struct Orchestrator: Equatable, Sendable {
        var name = L("Osaurus")
        var mascotId: String? = Agent.defaultAgentStockAvatar
        var imageURL: URL? = nil
    }

    /// The teammate picked from the list; the header names it after.
    struct Teammate: Equatable, Sendable {
        let pathId: String
        let name: String
        let mascotId: String?
        var imageURL: URL? = nil
    }

    var sessionId: UUID
    var step: Step?
    var teammate: Teammate?
    var note: String?
    var cards: [Card] = []
    var buttons: [Button] = []
    /// Scout's topic field.
    var topicField = false
    /// A discovery's panel: taps go to `DiscoveryCenter`.
    var isDiscovery = false

    /// The panel for the plan's current step, or nil when nothing shows.
    static func make(
        plan: OnboardingPlan,
        brain: OnboardingBrainState,
        team: [OnboardingOpening.Member],
        osaurus: Orchestrator = Orchestrator(),
        sessionId: UUID
    ) -> OnboardingPanel? {
        var panel = OnboardingPanel(sessionId: sessionId)
        let members = Dictionary(team.map { ($0.teammate, $0) }, uniquingKeysWith: { first, _ in first })
        let browse = plan.canExplore ? plan.browse : nil
        if let path = browse?.path ?? (plan.isFinished ? nil : plan.path) {
            if let teammate = path.teammate, let member = members[teammate] {
                panel.teammate = Teammate(pathId: path.id, name: member.name, mascotId: member.avatar)
            } else if path.teammate == nil {
                panel.teammate = Teammate(
                    pathId: path.id, name: osaurus.name, mascotId: osaurus.mascotId, imageURL: osaurus.imageURL)
            }
        }
        if plan.isFinished {
            guard let browse else { return nil }
            if let path = browse.path {
                panel.step = .firstTask
                fillFirstTask(&panel, path: path, requestOutcome: browse.requestOutcome, brain: brain)
            } else {
                panel.step = .team
                panel.cards = cards(members: members, osaurus: osaurus)
            }
            return panel
        }
        switch plan.current?.id {
        case OnboardingSteps.brain:
            panel.teammate = nil
            panel.step = .brain
            panel.buttons = [Button(action: .chooseBrain, title: L("Choose a Model"), icon: "cpu", style: .primary)]
        case OnboardingSteps.choice:
            panel.teammate = nil
            panel.step = .team
            panel.cards = cards(members: members, osaurus: osaurus)
        case OnboardingSteps.firstTask:
            guard let path = plan.path else { return nil }
            panel.step = .firstTask
            fillFirstTask(&panel, path: path, requestOutcome: plan.requestOutcome, brain: brain)
        default:
            return nil
        }
        return panel
    }

    /// The offer under a task's reply: meet someone else, or be done.
    static func exploreOffer(sessionId: UUID) -> OnboardingPanel {
        var panel = OnboardingPanel(sessionId: sessionId)
        panel.step = .explore
        panel.buttons = [
            Button(action: .doneExploring, title: L("Done"), icon: nil, style: .quiet),
            Button(action: .exploreTeam, title: L("Meet Another Teammate"), icon: "person.2", style: .primary),
        ]
        return panel
    }

    private static func cards(members: [OsaurusCore.Teammate: OnboardingOpening.Member], osaurus: Orchestrator)
        -> [Card]
    {
        OnboardingPaths.available(teammates: Set(members.keys)).map { path in
            let member = path.teammate.flatMap { members[$0] }
            return Card(
                id: path.id,
                name: member?.name ?? (path.teammate == nil ? osaurus.name : path.job),
                pitch: path.pitch,
                icon: path.icon,
                note: path.note,
                access: path.request.flatMap(accessLabel),
                mascotId: path.teammate == nil ? osaurus.mascotId : member?.avatar,
                imageURL: path.teammate == nil ? osaurus.imageURL : nil
            )
        }
    }

    private static func fillFirstTask(
        _ panel: inout OnboardingPanel,
        path: OnboardingPath,
        requestOutcome: OnboardingPlan.RequestOutcome?,
        brain: OnboardingBrainState
    ) {
        let controls = [Button(action: .back, title: L("Back"), icon: "chevron.left", style: .quiet)]
        let readsPersonal = path.asks.contains(where: \.readsPersonalData)
        if let request = path.request, request != .topic, requestOutcome == nil {
            if readsPersonal, let provider = brain.disclosedProvider {
                panel.note = String(
                    format: L("What it reads is sent to %@ to write the answer."),
                    provider
                )
            }
            panel.buttons =
                [Button(action: .request, title: requestTitle(request), icon: path.icon, style: .primary)]
                + controls
            return
        }

        var asks = path.asks
        var notes: [String] = []
        if requestOutcome == .denied {
            asks = asks.filter { !$0.dependsOnRequest }
            notes.append(
                path.request == .downloadsFolder
                    ? L("macOS did not allow it. Turn on Downloads for Osaurus in System Settings, under Privacy & Security, Files & Folders, then try again.")
                    : L("macOS did not allow it. You can turn it on in System Settings."))
        }
        if !brain.canAnswer {
            asks = []
            notes.append(L("I can run these once your private model is ready."))
        } else if brain.holdsPersonalAsks, asks.contains(where: \.readsPersonalData) {
            asks = asks.filter { !$0.readsPersonalData }
            notes.append(L("These read your own data, so they wait for the private model on this Mac."))
        }
        panel.note = notes.isEmpty ? nil : notes.joined(separator: " ")
        panel.topicField = path.request == .topic && brain.canAnswer

        var buttons = asks.map { Button(action: .ask($0.id), title: $0.label, icon: nil, style: .ask) }
        if requestOutcome == .denied, case .permission(let permission) = path.request {
            buttons.append(
                Button(
                    action: .openSettings(permission),
                    title: L("Open System Settings"),
                    icon: "gear",
                    style: .primary
                )
            )
        }
        if requestOutcome == .denied, path.request == .downloadsFolder {
            buttons += [
                Button(action: .request, title: L("Try Again"), icon: "arrow.clockwise", style: .primary),
                Button(action: .openFilesAndFolders, title: L("Open System Settings"), icon: "gear", style: .quiet),
            ]
        }
        if requestOutcome == .denied, path.request == .projectFolder {
            buttons.append(
                Button(action: .request, title: requestTitle(.projectFolder), icon: path.icon, style: .primary)
            )
        }
        panel.buttons = buttons + controls
    }

    static func accessLabel(_ request: OnboardingRequest) -> String? {
        switch request {
        case .permission(.calendar): return L("Calendar")
        case .permission(.automationMail): return L("Mail")
        case .permission: return nil
        case .downloadsFolder: return L("Downloads")
        case .projectFolder: return L("Folder")
        case .topic: return L("Web")
        }
    }

    static func requestTitle(_ request: OnboardingRequest) -> String {
        switch request {
        case .permission(.calendar): return L("Allow Calendar and Reminders")
        case .permission(.automationMail): return L("Allow Mail")
        case .permission: return L("Allow Access")
        case .downloadsFolder: return L("Allow Downloads")
        case .projectFolder: return L("Choose Project Folder")
        case .topic: return L("Research")
        }
    }
}
