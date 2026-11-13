//
//  OnboardingPaths.swift
//  osaurus
//
//  The first run's choices. A card stands for one teammate; it makes one
//  request (a macOS permission, a folder, or a topic) and then
//  offers three authored asks. An ask is a canned message: its prepared
//  workflow does the read, so no model chooses a tool.
//

import Foundation

/// The one thing a teammate needs before its asks can run.
enum OnboardingRequest: Sendable, Equatable {
    case permission(SystemPermission)
    /// Keeper reads Downloads; the first read raises the macOS dialog.
    case downloadsFolder
    /// Builder works in a project the person picks.
    case projectFolder
    /// Scout researches a topic the person types.
    case topic
}

struct OnboardingAsk: Sendable, Equatable, Identifiable {
    let id: String
    /// Sent as the person's message.
    let label: String
    /// The prepared or installed workflow the host runs. Nil sends the
    /// label to the Orchestrator as an ordinary message.
    let workflowId: UUID?
    var input: [String: String]
    /// Reads mail, calendar, notes, files, or code: held on the bridge and
    /// disclosed on a provider.
    let readsPersonalData: Bool
    /// Needs the path's request granted. False for an ask that reads
    /// another app, which raises its own dialog: it stays usable after a
    /// denial.
    let dependsOnRequest: Bool

    init(
        id: String,
        label: String,
        workflowId: UUID?,
        input: [String: String] = [:],
        readsPersonalData: Bool,
        dependsOnRequest: Bool = true
    ) {
        self.id = id
        self.label = label
        self.workflowId = workflowId
        self.input = input
        self.readsPersonalData = readsPersonalData
        self.dependsOnRequest = dependsOnRequest
    }
}

struct OnboardingPath: Sendable, Equatable, Identifiable {
    let id: String
    /// Nil for Osaurus itself, the one the person talks to.
    let teammate: Teammate?
    /// The job in a few words, for typed matching and the handover facts.
    let job: String
    /// The card's line, in the teammate's own plain words.
    let pitch: String
    /// SF Symbol for the app or folder the teammate is bound to.
    let icon: String
    /// A line the card adds, such as Scout's note that it uses the web.
    let note: String?
    let request: OnboardingRequest?
    /// The authored line shown when the card is tapped.
    let introLine: String
    let asks: [OnboardingAsk]
    /// Other words for the job, so "help with my mail" picks the card:
    /// one comma-separated list, matched after an opening like "help me with my".
    var aliases: String = ""
}

enum OnboardingPaths {
    static let morningBriefId = UUID(uuidString: "0f5c1a4e-6b7d-4c1a-9a01-000000000201")!
    static let meetingPrepId = UUID(uuidString: "0f5c1a4e-6b7d-4c1a-9a01-000000000202")!
    static let mailTriageId = UUID(uuidString: "0f5c1a4e-6b7d-4c1a-9a01-000000000203")!
    static let newDownloadId = UUID(uuidString: "0f5c1a4e-6b7d-4c1a-9a01-000000000204")!
    static let endOfDayId = UUID(uuidString: "0f5c1a4e-6b7d-4c1a-9a01-000000000205")!
    static let researchBriefId = UUID(uuidString: "0f5c1a4e-6b7d-4c1a-9a01-000000000206")!

    /// The installed copy of a default workflow. The ids above are the
    /// bundled templates'; an install gets an id of its own.
    @MainActor
    static func installed(_ templateID: UUID) -> InstalledWorkflow? {
        InstalledWorkflowStore.shared.workflow(templateID: templateID)
    }

    /// The cards for this install, in roster order: a teammate shows only
    /// when its agent exists. Osaurus comes last, so meeting it is part of
    /// meeting the team.
    static func available(teammates present: Set<Teammate>) -> [OnboardingPath] {
        all.filter { path in path.teammate.map(present.contains) ?? true }
    }

    static func path(id: String?) -> OnboardingPath? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    static func ask(id: String) -> OnboardingAsk? {
        all.lazy.flatMap(\.asks).first { $0.id == id }
    }

    /// Scout's ask for a typed topic: Research Brief with the topic.
    static func topicAsk(_ topic: String) -> OnboardingAsk {
        OnboardingAsk(
            id: "scout.topic",
            label: String(format: L("Research %@"), topic),
            workflowId: researchBriefId,
            input: ["topic": topic],
            readsPersonalData: false
        )
    }

    static var all: [OnboardingPath] {
        [planner, courier, keeper, scout, builder, osaurus]
    }

    private static func prepared(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "0f5c1a4e-6b7d-4c1a-9a01-%012d", suffix))!
    }

    static let planner = OnboardingPath(
        id: "planner",
        teammate: .planner,
        job: L("Your day"),
        pitch: L("Work with me to plan out your day."),
        icon: Teammate.planner.symbol,
        note: nil,
        request: .permission(.calendar),
        introLine: L(
            "Planner reads your calendar and reminders. It needs to see both first, and macOS will ask you once for each."
        ),
        asks: [
            OnboardingAsk(
                id: "planner.today",
                label: L("What is on my calendar today"),
                workflowId: prepared(301),
                readsPersonalData: true
            ),
            OnboardingAsk(
                id: "planner.week",
                label: L("What is due this week"),
                workflowId: prepared(302),
                readsPersonalData: true,
                dependsOnRequest: false
            ),
            OnboardingAsk(
                id: "planner.overdue",
                label: L("What is overdue"),
                workflowId: prepared(303),
                readsPersonalData: true,
                dependsOnRequest: false
            ),
        ],
        aliases: L("day, calendar, schedule, meetings, reminders, agenda, planning, week")
    )

    static let courier = OnboardingPath(
        id: "courier",
        teammate: .courier,
        job: L("Your mail"),
        pitch: L("Let me help you catch up on your email."),
        icon: Teammate.courier.symbol,
        note: nil,
        request: .permission(.automationMail),
        introLine: L(
            "Courier reads your mail and never sends anything without asking. It needs to reach Mail first, and macOS will ask you once."
        ),
        asks: [
            OnboardingAsk(
                id: "courier.reply",
                label: L("What needs a reply"),
                workflowId: prepared(311),
                readsPersonalData: true
            ),
            OnboardingAsk(
                id: "courier.yesterday",
                label: L("What came in since yesterday"),
                workflowId: prepared(312),
                readsPersonalData: true
            ),
            OnboardingAsk(
                id: "courier.unread",
                label: L("What is still unread"),
                workflowId: prepared(313),
                readsPersonalData: true
            ),
        ],
        aliases: L("mail, email, emails, inbox, replies")
    )

    static let keeper = OnboardingPath(
        id: "keeper",
        teammate: .keeper,
        job: L("Your files and notes"),
        pitch: L("Ask me to find and sum up your files and notes."),
        icon: Teammate.keeper.symbol,
        note: nil,
        request: .downloadsFolder,
        introLine: L(
            "Keeper reads your Downloads folder and your notes, and never changes a file. It needs to see Downloads first, and macOS will ask you once."
        ),
        asks: [
            OnboardingAsk(
                id: "keeper.week",
                label: L("What did I download this week"),
                workflowId: prepared(321),
                readsPersonalData: true
            ),
            OnboardingAsk(
                id: "keeper.newest",
                label: L("Summarize the newest document"),
                workflowId: prepared(322),
                readsPersonalData: true
            ),
            OnboardingAsk(
                id: "keeper.note",
                label: L("What did I last write down"),
                workflowId: prepared(323),
                readsPersonalData: true,
                dependsOnRequest: false
            ),
        ],
        aliases: L("files, downloads, notes, documents, folders")
    )

    static let scout = OnboardingPath(
        id: "scout",
        teammate: .scout,
        job: L("Finding things out"),
        pitch: L("Send me to look something up on the web for you."),
        icon: Teammate.scout.symbol,
        note: L("Searches the web"),
        request: .topic,
        introLine: L(
            "Scout searches the web and writes a note with a source for every claim. Its searches leave this Mac. What should it look into?"
        ),
        asks: [
            topicAsk(L("how heat pumps work")).withId("scout.example1"),
            topicAsk(L("the history of the Mac")).withId("scout.example2"),
        ],
        aliases: L("research, the web, web, search, searching, news, looking things up")
    )

    static let builder = OnboardingPath(
        id: "builder",
        teammate: .builder,
        job: L("Your code"),
        pitch: L("Let me walk you through a coding project and what changed."),
        icon: Teammate.builder.symbol,
        note: nil,
        request: .projectFolder,
        introLine: L(
            "Builder reads a project you pick and changes nothing without asking. Which folder is the project?"
        ),
        asks: [
            OnboardingAsk(
                id: "builder.week",
                label: L("What changed here this week"),
                workflowId: prepared(341),
                readsPersonalData: true
            ),
            OnboardingAsk(
                id: "builder.uncommitted",
                label: L("What is uncommitted right now"),
                workflowId: prepared(342),
                readsPersonalData: true
            ),
            OnboardingAsk(
                id: "builder.explain",
                label: L("Explain this project"),
                workflowId: prepared(343),
                readsPersonalData: true
            ),
        ],
        aliases: L("code, coding, project, projects, repo, repository, git, programming")
    )

    /// Osaurus itself: the one the person talks to, who answers, changes
    /// settings, and hands jobs to the team. Its asks go to it as ordinary
    /// messages.
    static let osaurus = OnboardingPath(
        id: "osaurus",
        teammate: nil,
        job: L("Anything"),
        pitch: L("Start with me. Ask anything, change a setting, or let me pass a job to the right teammate."),
        icon: "bubble.left.and.bubble.right",
        note: nil,
        request: nil,
        introLine: L(
            "You can ask me anything right here. I answer questions, change Osaurus settings when you ask, and pass jobs like research or email to the teammate who does them best. Try one of these:"
        ),
        asks: [
            OnboardingAsk(id: "osaurus.help", label: L("What can you help me with?"), workflowId: nil, readsPersonalData: false),
            OnboardingAsk(id: "osaurus.theme", label: L("How do I change how Osaurus looks?"), workflowId: nil, readsPersonalData: false),
            OnboardingAsk(id: "osaurus.team", label: L("Ask Scout to look up how rainbows form"), workflowId: nil, readsPersonalData: false),
        ],
        aliases: L("osaurus, settings")
    )
}

extension OnboardingAsk {
    func withId(_ id: String) -> OnboardingAsk {
        OnboardingAsk(
            id: id,
            label: label,
            workflowId: workflowId,
            input: input,
            readsPersonalData: readsPersonalData,
            dependsOnRequest: dependsOnRequest
        )
    }
}
