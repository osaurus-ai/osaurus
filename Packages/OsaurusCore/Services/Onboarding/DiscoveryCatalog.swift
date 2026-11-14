//
//  DiscoveryCatalog.swift
//  osaurus
//
//  What a new chat can offer after the first run, one card at a time. Each
//  item is shown or done from app state alone, so doing the thing without
//  the card retires it as surely as the card does. An item that adds an
//  app makes a new teammate rather than growing an existing one past the
//  tool budget; Messages is the exception, and joins Courier.
//

import Foundation

enum DiscoveryItem: String, CaseIterable, Codable, Sendable {
    case tryWorkflow = "try_workflow"
    case turnOnWorkflow = "turn_on_workflow"
    case keeperFolders = "keeper_folders"
    case keeperRedaction = "keeper_redaction"
    case history
    case people
    case navigator
    case builder
    case ownAgent = "own_agent"
    case privacyAI = "privacy_ai"
    case search
    case shortcuts
    case store
    case messages
    case phone
    case encryption
    case music
    case voice
    case memory
    case toolServer = "tool_server"
    case channels
    case skills
    case orchestratorFolder = "orchestrator_folder"
    case computerUse = "computer_use"
}

/// The app state the catalog reads. Built live by `DiscoveryCenter`; tests
/// build it by hand.
struct DiscoverySnapshot: Sendable, Equatable {
    /// Default workflows that have completed a run and have no automation,
    /// in default-workflow order.
    var ranWithoutAutomation: [UUID] = []
    /// Installed default workflows that have never run, in
    /// default-workflow order.
    var neverRun: [UUID] = []
    /// Some default workflow has completed a run.
    var defaultWorkflowSucceeded = false
    var defaultAutomationExists = false
    var keeperExists = false
    var keeperRedactionOn = false
    /// A folder other than Downloads, on an agent other than Builder.
    var otherFolderAttached = false
    /// The import prompt was presented, or a card opened the import. A
    /// finished import retires the item through its notification.
    var importPromptSeen = false
    /// Every app turned on for any agent.
    var enabledApps: Set<AppleApp> = []
    var courierExists = false
    var courierHasMessages = false
    var fullDiskAccess = false
    var builderExists = false
    var builderHasFolder = false
    var customAgentExists = false
    var privacyAIOn = false
    var providerConnected = false
    var searchProviderSet = false
    var storeLive = true
    var storeInstalled = false
    var phonePaired = false
    var encryptionOn = false
    var voiceSetUp = false
    var memoryEnabled = true
    var memoryHasEntries = false
    /// The memory card's review step was taken: reviewing changes no
    /// setting of its own.
    var memoryReviewed = false
    var toolServerAdded = false
    /// Nil until the channel credentials have been read.
    var channelConfigured: Bool?
    /// A skill or plugin the person added.
    var skillOrPluginAdded = false
    var orchestratorHasFolder = false
    var computerOrBrowserOn = false
}

enum DiscoveryCatalog {
    enum Status: Equatable, Sendable {
        /// Offered.
        case open
        /// Not offered now; may be later.
        case hidden
        /// Retired for good.
        case done
    }

    /// The default order, which follows the first run.
    static let defaultOrder: [DiscoveryItem] = [
        .tryWorkflow, .turnOnWorkflow, .keeperFolders, .keeperRedaction, .history, .people, .navigator, .builder,
        .ownAgent, .memory, .toolServer, .orchestratorFolder, .privacyAI, .search, .shortcuts, .store, .skills,
        .channels, .computerUse, .messages, .phone, .encryption, .music, .voice,
    ]

    /// Items related to the first-run choice come first.
    static func order(startedWith teammate: Teammate?) -> [DiscoveryItem] {
        let related: [DiscoveryItem]
        switch teammate {
        case .planner: related = [.tryWorkflow, .turnOnWorkflow, .people, .navigator]
        case .courier: related = [.messages, .tryWorkflow, .turnOnWorkflow, .people]
        case .keeper: related = [.keeperFolders, .keeperRedaction, .tryWorkflow, .turnOnWorkflow]
        case .scout: related = [.search, .privacyAI, .toolServer]
        case .builder: related = [.tryWorkflow, .turnOnWorkflow, .orchestratorFolder, .toolServer]
        case nil: related = []
        }
        return related + defaultOrder.filter { !related.contains($0) }
    }

    /// The default workflows the Try card can run, by template id: the
    /// first-run teammate's first, then the rest in default order. Repo
    /// Digest waits for Builder's project folder.
    static func workflowsToTry(_ s: DiscoverySnapshot, startedWith teammate: Teammate?) -> [UUID] {
        let candidates = s.neverRun.filter { $0 != TeamSeeder.repoDigestTemplateID || s.builderHasFolder }
        let first = teammate.map(workflows(of:)) ?? []
        return first.filter(candidates.contains) + candidates.filter { !first.contains($0) }
    }

    static func workflows(of teammate: Teammate) -> [UUID] {
        switch teammate {
        case .planner: return [OnboardingPaths.morningBriefId, OnboardingPaths.meetingPrepId, OnboardingPaths.endOfDayId]
        case .courier: return [OnboardingPaths.mailTriageId]
        case .keeper: return [OnboardingPaths.newDownloadId]
        case .builder: return [TeamSeeder.repoDigestTemplateID]
        case .scout: return []
        }
    }

    static func status(_ item: DiscoveryItem, in s: DiscoverySnapshot) -> Status {
        func openUnless(_ done: Bool, shownWhen shown: Bool = true) -> Status {
            done ? .done : (shown ? .open : .hidden)
        }
        switch item {
        case .tryWorkflow:
            return openUnless(
                s.defaultWorkflowSucceeded || s.defaultAutomationExists,
                shownWhen: !workflowsToTry(s, startedWith: nil).isEmpty
            )
        case .turnOnWorkflow:
            return openUnless(s.defaultAutomationExists, shownWhen: !s.ranWithoutAutomation.isEmpty)
        case .keeperFolders: return openUnless(s.otherFolderAttached, shownWhen: s.keeperExists)
        case .keeperRedaction: return openUnless(s.keeperRedactionOn, shownWhen: s.keeperExists)
        case .history: return s.importPromptSeen ? .hidden : .open
        case .people: return openUnless(s.enabledApps.contains(.contacts))
        case .navigator: return openUnless(s.enabledApps.contains(.maps))
        case .builder: return openUnless(s.builderExists)
        case .ownAgent: return openUnless(s.customAgentExists)
        case .privacyAI: return openUnless(s.privacyAIOn, shownWhen: s.providerConnected)
        case .search: return openUnless(s.searchProviderSet)
        case .shortcuts: return openUnless(s.enabledApps.contains(.shortcuts))
        case .store: return openUnless(s.storeInstalled, shownWhen: s.storeLive)
        case .messages:
            return openUnless(
                s.fullDiskAccess && s.courierHasMessages,
                shownWhen: s.courierExists && !s.enabledApps.contains(.messages)
            )
        case .phone: return openUnless(s.phonePaired)
        case .encryption: return openUnless(s.encryptionOn)
        case .music: return openUnless(s.enabledApps.contains(.music))
        case .voice: return openUnless(s.voiceSetUp)
        case .memory:
            return s.memoryEnabled ? openUnless(s.memoryReviewed, shownWhen: s.memoryHasEntries) : .open
        case .toolServer: return openUnless(s.toolServerAdded)
        case .channels: return s.channelConfigured.map { openUnless($0) } ?? .hidden
        case .skills: return openUnless(s.skillOrPluginAdded)
        case .orchestratorFolder: return openUnless(s.orchestratorHasFolder)
        case .computerUse: return openUnless(s.computerOrBrowserOn)
        }
    }

    /// The card's title.
    static func title(_ item: DiscoveryItem, names: [Teammate: String]) -> String {
        switch item {
        case .tryWorkflow: return L("Try a Default Workflow")
        case .turnOnWorkflow: return L("Turn On a Default Workflow")
        case .keeperFolders: return String(format: L("Give %@ Your Documents and Desktop"), names[.keeper] ?? "Keeper")
        case .keeperRedaction:
            return String(format: L("Let %@ Spot Private Details"), names[.keeper] ?? "Keeper")
        case .history: return L("Bring Your History")
        case .people: return L("Add People, for Your Contacts")
        case .navigator: return L("Add Navigator, for Places and Travel Time")
        case .builder: return L("Add Builder")
        case .ownAgent: return L("Make an Agent of Your Own")
        case .privacyAI: return L("Catch Names and Addresses Too")
        case .search: return String(format: L("Better Search for %@"), names[.scout] ?? "Scout")
        case .shortcuts: return L("Add a Shortcuts Teammate")
        case .store: return L("Try Something from the Store")
        case .messages: return String(format: L("Connect Your Texts to %@"), names[.courier] ?? "Courier")
        case .phone: return L("Reach Osaurus from Your Phone")
        case .encryption: return L("Encrypt What Is Stored on This Mac")
        case .music: return L("Add a Music Teammate")
        case .voice: return L("Talk Instead of Typing")
        case .memory: return L("What Osaurus Remembers")
        case .toolServer: return L("Connect a Tool Server")
        case .channels: return L("Reach Osaurus from Telegram or Slack")
        case .skills: return L("Add a Skill or Plugin")
        case .orchestratorFolder: return L("Give the Orchestrator a Working Folder")
        case .computerUse: return L("Let an Agent Use Your Apps or the Web")
        }
    }

    static func icon(_ item: DiscoveryItem) -> String {
        switch item {
        case .tryWorkflow: return "play.circle"
        case .turnOnWorkflow: return "clock"
        case .keeperFolders: return "folder.badge.plus"
        case .keeperRedaction: return "eye.slash"
        case .history: return "tray.and.arrow.down"
        case .people: return "person.crop.circle"
        case .navigator: return "map"
        case .builder: return "hammer"
        case .ownAgent: return "person.badge.plus"
        case .privacyAI: return "shield.lefthalf.filled"
        case .search: return "magnifyingglass"
        case .shortcuts: return "square.stack.3d.up"
        case .store: return "bag"
        case .messages: return "message"
        case .phone: return "iphone"
        case .encryption: return "lock"
        case .music: return "music.note"
        case .voice: return "mic"
        case .memory: return "brain"
        case .toolServer: return "server.rack"
        case .channels: return "bubble.left.and.bubble.right"
        case .skills: return "puzzlepiece.extension"
        case .orchestratorFolder: return "folder"
        case .computerUse: return "cursorarrow.click.2"
        }
    }

    /// The authored line a card opens with.
    static func line(_ item: DiscoveryItem, names: [Teammate: String]) -> String {
        let keeper = names[.keeper] ?? "Keeper"
        let courier = names[.courier] ?? "Courier"
        let scout = names[.scout] ?? "Scout"
        switch item {
        case .tryWorkflow:
            return L("Osaurus came with workflows that do a whole job in one go. Run one here to see what it gives you.")
        case .turnOnWorkflow:
            return L("A workflow you ran can run on its own on a schedule. You approve it first.")
        case .keeperFolders:
            return String(
                format: L(
                    "%@ reads your Downloads. Pick another folder, such as Documents or Desktop, and I will add a teammate that reads it."
                ),
                keeper
            )
        case .keeperRedaction:
            return String(
                format: L(
                    "%@ can point out the names, numbers, and addresses in a file. Its folder stays read only, so the file is never changed."
                ),
                keeper
            )
        case .history:
            return L("Bring your chats from ChatGPT, Claude, or another app, so they are here with the rest.")
        case .people:
            return L("People is a teammate for your contacts: phone numbers, email addresses, and birthdays.")
        case .navigator:
            return L("Navigator is a teammate for places, directions, and travel time.")
        case .builder:
            return L("Builder is a teammate for code. It works in a project folder you choose.")
        case .ownAgent:
            return L("Make an agent with its own instructions, apps, and folder.")
        case .privacyAI:
            return L(
                "The Privacy Filter catches emails and numbers. A detection model also catches names and addresses before anything leaves this Mac."
            )
        case .search:
            return String(format: L("%@ searches the web. A search provider gives it better results."), scout)
        case .shortcuts:
            return L("A Shortcuts teammate runs the shortcuts you already have.")
        case .store:
            return L("The Store has workflows other people made. Installing one takes a click.")
        case .messages:
            return String(
                format: L("%@ can read and draft your texts too. macOS asks for Full Disk Access first."),
                courier
            )
        case .phone:
            return L("Pair your iPhone to talk to Osaurus when you are away from this Mac.")
        case .encryption:
            return L("Encrypt your chats and memory on this Mac, so they are unreadable without your key.")
        case .music:
            return L("A Music teammate plays, finds, and queues your music.")
        case .voice:
            return L("Set up voice to talk to Osaurus instead of typing. It runs on this Mac.")
        case .memory:
            return L(
                "Osaurus can remember what you tell it, such as your name and how you like answers, and use it in later chats. You can see and delete each memory."
            )
        case .toolServer:
            return L(
                "A tool server, also called MCP, gives Osaurus new tools, such as GitHub, Linear, or Notion. Pick one from the directory."
            )
        case .channels:
            return L("Connect Telegram, Slack, Discord, or another chat app, and message Osaurus from there.")
        case .skills:
            return L(
                "A skill teaches Osaurus how to do one kind of task. A plugin gives it new tools. You can add either one."
            )
        case .orchestratorFolder:
            return L("Give the Orchestrator a folder, and it can read and work on the files there in your chats.")
        case .computerUse:
            return L(
                "Computer Use lets an agent click and type in the apps you allow. Browser Use lets an agent browse websites for you."
            )
        }
    }
}
