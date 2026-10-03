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
    /// Open Management → Models (curated download catalog). A non-nil
    /// `modelId` also opens that model's detail sheet on arrival.
    case openModelDownloads(modelId: String?)
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
    /// Bundled asset-catalog image rendered over the accent gradient instead
    /// of `systemImage` (e.g. the Osaurus logo). Takes precedence over
    /// `systemImage`; `imageURL` still wins over both.
    public let assetImage: String?
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
        assetImage: String? = nil,
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
        self.assetImage = assetImage
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
        raptor_0_24_4,
    ]

    /// First-launch announcement for native Browser Use in 0.22.9.
    /// Two pages: what it does plus the persistent per-agent sessions, and
    /// the safe-by-default consent gate plus how to turn it on per custom
    /// agent. The final CTA deep-links to Settings → Browser.
    private static let browserUse_0_22_9 = WhatsNewRelease(
        version: "0.22.9",
        pages: [
            WhatsNewPage(
                id: "browser-use-0.22.9:summary",
                title: "Browser Use",
                titlePrefix: "Introducing",
                description:
                    "Your agents can browse the web for you — navigating pages, reading content, and filling forms, with every step shown in a live feed. Each agent keeps its own persistent browser session, separate from other agents and your regular browser.",
                systemImage: "globe"
            ),
            WhatsNewPage(
                id: "browser-use-0.22.9:enable",
                title: "Safe by default, on per agent",
                eyebrow: "Introducing Browser Use",
                description:
                    "Reading and navigation run automatically; typing pauses for approval, and submitting, purchasing, or sending always asks first. Turn it on for a custom agent under Abilities → Subagents, and review each agent's session in Settings → Browser.",
                systemImage: "checkmark.shield.fill",
                actionLabel: "Open Browser settings",
                action: .openBrowserSettings
            ),
        ]
    )

    /// First-launch announcement for native Channels in 0.22.13.
    /// Two pages: the supported services, then per-channel routing plus the
    /// global safety and audit controls. The final CTA deep-links to
    /// Management → Channels.
    private static let channels_0_22_13 = WhatsNewRelease(
        version: "0.22.13",
        pages: [
            WhatsNewPage(
                id: "channels-0.22.13:summary",
                title: "Channels",
                titlePrefix: "Introducing",
                description:
                    "Connect Discord, Slack, Telegram, WhatsApp, and iMessage — plus n8n and custom JSON agents — so your agents can read and reply where conversations already happen. Set up every service in one place and check its status at a glance.",
                systemImage: "bubble.left.and.bubble.right.fill"
            ),
            WhatsNewPage(
                id: "channels-0.22.13:control",
                title: "You choose who and where",
                eyebrow: "Introducing Channels",
                description:
                    "Pick which agent answers each channel and which people may trigger it; agents can only start new messages in destinations you allow. Pause sending everywhere with one switch and review incoming activity and the outbox.",
                systemImage: "checkmark.shield.fill",
                actionLabel: "Open Channels",
                action: .openChannelsSettings
            ),
        ]
    )

    /// First-launch announcement for Projects in 0.22.23. Two pages: what a
    /// project bundles (including the shared memory that carries across
    /// every chat and agent), and how to start one. The final CTA reveals
    /// the sidebar's Projects tab via `openProjects`.
    private static let projects_0_22_23 = WhatsNewRelease(
        version: "0.22.23",
        pages: [
            WhatsNewPage(
                id: "projects-0.22.23:summary",
                title: "Projects",
                titlePrefix: "Introducing",
                description:
                    "Group related chats into a project so they share one set of instructions, knowledge collections, and memory. A fact learned in one chat is recalled in another right away, even across different agents.",
                systemImage: "folder.fill"
            ),
            WhatsNewPage(
                id: "projects-0.22.23:start",
                title: "Start in the sidebar",
                eyebrow: "Introducing Projects",
                description:
                    "Open the Projects tab to create one, set its instructions, knowledge, and default agent, then pull in existing chats or start new ones. Existing chats and memory are untouched until you add them.",
                systemImage: "folder.badge.plus",
                actionLabel: "Open Projects",
                action: .openProjects
            ),
        ]
    )

    /// First-launch announcement for the Orchestrator in 0.24.0. Two
    /// pages: the default agent's new role (declarative config + delegation
    /// to your agents and allowed models), and the Settings → Orchestrator
    /// tab for identity + delegation. The final CTA deep-links to
    /// Settings → Orchestrator.
    private static let orchestrator_0_24_0 = WhatsNewRelease(
        version: "0.24.0",
        pages: [
            WhatsNewPage(
                id: "orchestrator-0.24.0:summary",
                title: "The Orchestrator",
                titlePrefix: "Introducing",
                description:
                    "Your default agent now manages your whole configuration as one reviewable document — it plans each change, shows exactly what would happen, and applies only after you approve. It can also delegate work to your custom agents and allowed local or cloud models, in parallel, within budgets you set.",
                systemImage: "point.3.connected.trianglepath.dotted"
            ),
            WhatsNewPage(
                id: "orchestrator-0.24.0:settings",
                title: "Make it yours",
                eyebrow: "Introducing the Orchestrator",
                description:
                    "Settings → Orchestrator is its home: name it, write its persona, tune generation, and choose exactly which helpers it may delegate to. Delegation stays off until you allow specific agents or models.",
                systemImage: "slider.horizontal.3",
                actionLabel: "Open Orchestrator settings",
                action: .openOrchestratorSettings
            ),
        ]
    )

    /// First-launch announcement for the Raptor model family, first shipped
    /// as v0.5 in 0.24.4. Two pages: what the family is (agentic tool use
    /// tuned for Macs with less RAM) and where to get it. The copy names the
    /// current default (Raptor 0.6) rather than the version announced at
    /// the time, because the notes are read by users arriving at the latest
    /// release and v0.5 has since been retired from the catalog. The final
    /// CTA deep-links to Management → Models.
    private static let raptor_0_24_4 = WhatsNewRelease(
        version: "0.24.4",
        pages: [
            WhatsNewPage(
                id: "raptor-0.24.4:summary",
                title: "Raptor",
                titlePrefix: "Introducing",
                description:
                    "Meet Raptor, our own model family built for Macs with less memory. It is quick and light, so your assistant can use tools, work through multi-step tasks, and keep up with long conversations without slowing down your Mac.",
                assetImage: "osaurus-logo"
            ),
            WhatsNewPage(
                id: "raptor-0.24.4:download",
                title: "Get it from the model catalog",
                eyebrow: "Introducing Raptor",
                description:
                    "Raptor 0.6 is a Top Pick in the model catalog, and new setups on mainstream hardware start with it by default. Already set up? Grab it any time from Settings… (⌘,) → Local Models.",
                systemImage: "arrow.down.circle.fill",
                actionLabel: "Open Models",
                action: .openModelDownloads(modelId: "OsaurusAI/Raptor-0.6-4B-JANG_6M")
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
