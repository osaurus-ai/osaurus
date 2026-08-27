//
//  WhatsNewModels.swift
//  osaurus
//
//  Data types and static release notes for the "What's New" modal.
//

import Foundation
import OsaurusRepository

/// Optional call-to-action a `WhatsNewPage` can carry. The host UI handles
/// each case as a deep link (open Settings on a specific tab, open a URL,
/// etc.) so the view stays purely declarative.
public enum WhatsNewAction: Hashable, Sendable {
    /// Open Settings → Sandbox.
    case openSandboxSettings
    /// Open Settings → Server (where API keys are listed).
    case openAPIKeysSettings
    /// Open an arbitrary documentation URL in the system browser.
    case openSecurityDoc(URL)
    /// Open Settings → Storage (encryption key + plaintext export).
    case openStorageSettings
    /// Trigger a one-shot plaintext export of conversation/memory data.
    case exportPlaintextBackup
    /// Open Settings → Privacy (Privacy Filter master switch + custom rules).
    case openPrivacySettings
    /// Open Settings → Computer Use.
    case openComputerUseSettings
    /// Open Management → Credits.
    case openCredits
    /// Open Management → Image Generation.
    case openImageGeneration
    /// Open Settings (where the Subagents / Spawn card lives).
    case openSubagentSettings
    /// Open Settings → Search (native web search providers).
    case openSearchSettings
    /// Open Management → Knowledge (collections list + curation inbox).
    case openKnowledgeSettings
    /// Open Settings → Browser (Browser Use sessions + guidance).
    case openBrowserSettings
    /// Open Management → Channels.
    case openChannelsSettings
    /// Reveal the chat sidebar's Projects tab.
    case openProjects
    /// Open Settings → Orchestrator (identity + delegation helpers).
    case openOrchestratorSettings
}

public struct WhatsNewPage: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    /// Muted lead-in rendered before `title` in the headline (e.g.
    /// "Introducing" ahead of "Knowledge Base"). Nil for a plain title.
    public let titlePrefix: String?
    /// Overrides the uppercase "What's New" eyebrow above the headline.
    public let eyebrow: String?
    public let description: String
    /// If nil, the page shows a sparkling stars background instead of an image.
    public let imageURL: URL?
    /// SF Symbol rendered over the accent gradient when `imageURL` is nil.
    /// Gives each page its own glyph instead of a single shared sparkle.
    /// Falls back to a generic sparkle in the view when nil.
    public let systemImage: String?
    /// When set, the modal renders a prominent button labelled `actionLabel`
    /// in the footer that invokes `action`. Use sparingly — most pages should
    /// be informational only.
    public let actionLabel: String?
    public let action: WhatsNewAction?

    public init(
        id: String,
        title: String,
        titlePrefix: String? = nil,
        eyebrow: String? = nil,
        description: String,
        imageURL: URL? = nil,
        systemImage: String? = nil,
        actionLabel: String? = nil,
        action: WhatsNewAction? = nil
    ) {
        self.id = id
        self.title = title
        self.titlePrefix = titlePrefix
        self.eyebrow = eyebrow
        self.description = description
        self.imageURL = imageURL
        self.systemImage = systemImage
        self.actionLabel = actionLabel
        self.action = action
    }
}

public struct WhatsNewRelease: Identifiable, Hashable, Sendable {
    public let version: String
    public let pages: [WhatsNewPage]

    public var id: String { version }

    public init(version: String, pages: [WhatsNewPage]) {
        self.version = version
        self.pages = pages
    }
}

public enum WhatsNewContent {
    /// Release notes keyed by app version. Add a `WhatsNewRelease` entry
    /// here whose `version` matches `CFBundleShortVersionString` for each
    /// release that should announce changes on first launch after update.
    public static let releases: [WhatsNewRelease] = [
        browserUse_0_22_9,
        channels_0_22_13,
        projects_0_22_23,
        orchestrator_0_24_0,
    ]

    /// First-launch announcement for native Browser Use in 0.22.9.
    /// Three pages: what it does and the persistent per-agent sessions
    /// (superseding the osaurus.browser plugin, whose profiles were
    /// migrated automatically), the safe-by-default consent gate plus the
    /// direct sign-in window, and how to turn it on per custom agent.
    /// The final CTA deep-links to Settings → Browser.
    private static let browserUse_0_22_9 = WhatsNewRelease(
        version: "0.22.9",
        pages: [
            WhatsNewPage(
                id: "browser-use-0.22.9:summary",
                title: "Browser Use",
                titlePrefix: "Introducing",
                description:
                    "Your agents can now browse the web for you — navigating pages, reading content, and filling forms, with every step shown in a live feed. Each agent gets its own persistent browser session, so cookies and sign-ins carry over between chats but are never shared with other agents or your regular browser. If you used the browser plugin before, your sessions were migrated automatically.",
                systemImage: "globe"
            ),
            WhatsNewPage(
                id: "browser-use-0.22.9:safety",
                title: "Safe by default",
                eyebrow: "Introducing Browser Use",
                description:
                    "Reading and ordinary navigation run automatically, following your Computer Use autonomy level — but typing pauses for your approval, and submitting, purchasing, sending, or clearing data always asks first. Sign-ins happen in a window you type into directly, so agents never see your passwords. And you can stop a run any time from the feed.",
                systemImage: "checkmark.shield.fill"
            ),
            WhatsNewPage(
                id: "browser-use-0.22.9:enable",
                title: "Turn it on per agent",
                eyebrow: "Introducing Browser Use",
                description:
                    "Browser Use is off by default and only custom agents can use it. Open a custom agent's Subagents tab and flip on Browser Use — optionally with a dedicated model for browsing. Review or reset each agent's session in the new Browser settings tab.",
                systemImage: "person.2.fill",
                actionLabel: "Open Browser settings",
                action: .openBrowserSettings
            ),
        ]
    )

    /// First-launch announcement for native Channels in 0.22.13.
    /// Three pages introduce supported services, per-channel reply routing
    /// and outbound destinations, and the global safety and audit controls.
    /// The final CTA deep-links to Management → Channels.
    private static let channels_0_22_13 = WhatsNewRelease(
        version: "0.22.13",
        pages: [
            WhatsNewPage(
                id: "channels-0.22.13:summary",
                title: "Channels",
                titlePrefix: "Introducing",
                description:
                    "Connect Discord, Slack, Telegram, and iMessage so your agents can read and reply where conversations already happen. Set up every service in one place and check its status at a glance.",
                systemImage: "bubble.left.and.bubble.right.fill"
            ),
            WhatsNewPage(
                id: "channels-0.22.13:routing",
                title: "Route replies to the right agent",
                eyebrow: "Introducing Channels",
                description:
                    "Choose which agent answers each connected channel and which people may trigger it. Agents can also start new messages only in destinations you explicitly allow.",
                systemImage: "arrow.triangle.branch"
            ),
            WhatsNewPage(
                id: "channels-0.22.13:control",
                title: "You stay in control",
                eyebrow: "Introducing Channels",
                description:
                    "Pause sending everywhere with one switch, review incoming activity and the outbox, and keep access limited to the channels, people, and destinations you choose.",
                systemImage: "checkmark.shield.fill",
                actionLabel: "Open Channels",
                action: .openChannelsSettings
            ),
        ]
    )

    /// First-launch announcement for Projects in 0.22.23. Three pages:
    /// what a project bundles, the shared memory that carries across every
    /// chat and agent, and how to start one. The final CTA reveals the
    /// sidebar's Projects tab via `openProjects`.
    private static let projects_0_22_23 = WhatsNewRelease(
        version: "0.22.23",
        pages: [
            WhatsNewPage(
                id: "projects-0.22.23:summary",
                title: "Projects",
                titlePrefix: "Introducing",
                description:
                    "Group related chats into a project so they share one set of instructions, knowledge collections, and memory. Everything you work on in a project stays together, and every new chat starts with the same context instead of a blank slate.",
                systemImage: "folder.fill"
            ),
            WhatsNewPage(
                id: "projects-0.22.23:memory",
                title: "Memory shared across every chat",
                eyebrow: "Introducing Projects",
                description:
                    "Chats in a project pool their memory, so a fact learned in one chat is recalled in another right away, even across different agents. It works even for agents whose own memory is off. They read and add to the project's shared memory without building any personal memory of their own.",
                systemImage: "brain"
            ),
            WhatsNewPage(
                id: "projects-0.22.23:start",
                title: "Start in the sidebar",
                eyebrow: "Introducing Projects",
                description:
                    "Open the Projects tab in the sidebar to create one, set its instructions, knowledge, and default agent, then pull in existing chats or start new ones. Your existing chats and memory are untouched until you add them.",
                systemImage: "folder.badge.plus",
                actionLabel: "Open Projects",
                action: .openProjects
            ),
        ]
    )

    /// First-launch announcement for the Orchestrator in 0.24.0. Three
    /// pages: the default agent's new role (declarative config + delegation),
    /// the delegation helpers and their safety rails, and the new
    /// Settings → Orchestrator tab for identity + delegation. The final CTA
    /// deep-links to Settings → Orchestrator.
    private static let orchestrator_0_24_0 = WhatsNewRelease(
        version: "0.24.0",
        pages: [
            WhatsNewPage(
                id: "orchestrator-0.24.0:summary",
                title: "The Orchestrator",
                titlePrefix: "Introducing",
                description:
                    "Your default agent grew up. Beyond setting up Osaurus and answering questions, it now manages your whole configuration as one reviewable document — it plans every change, shows you exactly what would happen, and applies only after you approve — and it can delegate real work to your agents.",
                systemImage: "point.3.connected.trianglepath.dotted"
            ),
            WhatsNewPage(
                id: "orchestrator-0.24.0:delegation",
                title: "Delegates work to your agents",
                eyebrow: "Introducing the Orchestrator",
                description:
                    "Ask for something bigger and the Orchestrator can spawn your custom agents and allowed local or cloud models as helpers — in parallel, each within budgets you set for tokens, turns, tool calls, and time. A RAM-safety preflight keeps parallel local models from overwhelming your Mac, and results flow back into one conversation.",
                systemImage: "square.stack.3d.up.fill"
            ),
            WhatsNewPage(
                id: "orchestrator-0.24.0:settings",
                title: "Make it yours",
                eyebrow: "Introducing the Orchestrator",
                description:
                    "The Orchestrator has its own home in Settings: give it a name, write its persona, tune its generation, and choose exactly which agents and models it may delegate to. Delegation stays off until you allow specific helpers.",
                systemImage: "slider.horizontal.3",
                actionLabel: "Open Orchestrator settings",
                action: .openOrchestratorSettings
            ),
        ]
    )

    /// Returns the release notes for `version`, if any.
    public static func release(for version: String) -> WhatsNewRelease? {
        releases.first { $0.version == version }
    }

    /// Returns every release whose version is strictly greater than `stored`
    /// and less than or equal to `current`, sorted oldest → newest.
    /// Used to aggregate notes when a user skips one or more versions
    public static func releases(
        after stored: SemanticVersion,
        upTo current: SemanticVersion
    ) -> [WhatsNewRelease] {
        releases
            .compactMap { release -> (SemanticVersion, WhatsNewRelease)? in
                guard let v = SemanticVersion.parse(release.version) else { return nil }
                guard v > stored, v <= current else { return nil }
                return (v, release)
            }
            .sorted { $0.0 < $1.0 }
            .map { $0.1 }
    }

    /// Most recent release that has notes. used by the "Show What's New"
    /// menu action when the user wants to re-view the latest notes.
    public static var latest: WhatsNewRelease? { releases.last }
}
