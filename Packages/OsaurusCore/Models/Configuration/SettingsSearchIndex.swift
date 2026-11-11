//
//  SettingsSearchIndex.swift
//  osaurus
//
//  Declarative index of searchable settings across every management tab.
//  Phase 1 of global settings search: the sidebar search field queries this
//  index and presents cross-tab results, so a setting like "Transcription"
//  (which lives in the Voice tab) is findable from anywhere — not just the
//  Settings tab. Selecting a result navigates to its tab.
//
//  Each entry is declared once here. Keep it in sync with the UI; the leaf
//  `title`/`section` strings should mirror what the tab actually shows. A
//  future phase can add a deep-link `anchor` so selecting a result also
//  scrolls to and glows the specific control.
//

import Foundation

/// A single searchable setting, addressable by the tab (and human-readable
/// section) it lives in. `keywords` widen matching beyond the visible title
/// (synonyms, related terms) so natural queries land.
public struct SettingsSearchEntry: Identifiable, Sendable, Hashable {
    public let id: String
    public let tab: ManagementTab
    /// Human-readable area within the tab, e.g. "Speech to Text". May be empty
    /// for flat tabs.
    public let section: String
    /// The setting's visible title, e.g. "Transcription Model".
    public let title: String
    /// Extra match terms (synonyms, related words) beyond title/section/tab.
    public let keywords: [String]
    /// For tabs with their own inner navigation (e.g. Voice), the raw value of
    /// the sub-tab to open on landing. `nil` for flat tabs.
    public let subTab: String?
    /// Short "not this" note when aliases collide (shown in search + `osaurus_help` find).
    public let disambiguation: String?
    /// `ConfigSectionID.rawValue` when `osaurus_config` can change this setting.
    /// `nil` means Settings UI only.
    public let declarativeSection: String?

    public init(
        id: String,
        tab: ManagementTab,
        section: String = "",
        title: String,
        keywords: [String] = [],
        subTab: String? = nil,
        disambiguation: String? = nil,
        declarativeSection: String? = nil
    ) {
        self.id = id
        self.tab = tab
        self.section = section
        self.title = title
        self.keywords = keywords
        self.subTab = subTab
        self.disambiguation = disambiguation
        self.declarativeSection = declarativeSection
    }

    /// Breadcrumb shown in results, e.g. ["Voice", "Speech to Text", "Transcription Model"].
    /// A section that just repeats the tab label (e.g. the "General" card inside
    /// the General tab) is collapsed so results don't read "General › General".
    public var breadcrumb: [String] {
        let destination = tab == .workflows ? "Main window › Workflows" : tab.label
        return section.isEmpty || section == tab.label
            ? [destination, title]
            : [destination, section, title]
    }

    /// Management path the Orchestrator should quote, e.g. `Server › Cache › Context Window Cap`.
    public var breadcrumbPath: String {
        breadcrumb.joined(separator: " › ")
    }

    public var isSettingsUIOnly: Bool { declarativeSection == nil }
}

public enum SettingsSearchIndex {

    /// Returns entries matching `query`, ranked so title hits come before
    /// section/keyword-only hits. Token/substring matching (no fuzzy
    /// subsequence) keeps results aligned with what the user typed; when that
    /// finds fewer than three, typo-tolerant matches ("hotky",
    /// "transcripton") follow every strict hit.
    public static func search(_ query: String) -> [SettingsSearchEntry] {
        searchScored(query).map(\.entry)
    }

    /// One `search` hit with its match tier: 0 title, 1 section or keyword,
    /// 2 tab label, 3 typo-tolerant title, 4 typo-tolerant section/keyword.
    public struct ScoredHit: Sendable, Hashable {
        public let entry: SettingsSearchEntry
        public let rank: Int
    }

    /// `search` with the rank kept, in the same order.
    public static func searchScored(_ query: String) -> [ScoredHit] {
        let prepared = SearchService.PreparedQuery(query)
        guard !prepared.tokens.isEmpty else { return [] }

        func matches(_ target: SearchService.PreparedTarget) -> Bool {
            SearchService.matches(prepared, in: target)
        }
        // Tab labels are localized, so they are prepared per search.
        var tabLabels: [ManagementTab: SearchService.PreparedTarget] = [:]

        var ranked: [(entry: SettingsSearchEntry, rank: Int)] = []
        for (entry, fields) in zip(catalog, searchFields) {
            if matches(fields.title) {
                ranked.append((entry, 0))
            } else if matches(fields.section) || fields.keywords.contains(where: matches) {
                ranked.append((entry, 1))
            } else {
                let tab = tabLabels[entry.tab] ?? SearchService.PreparedTarget(entry.tab.label)
                tabLabels[entry.tab] = tab
                if matches(tab) { ranked.append((entry, 2)) }
            }
        }
        if ranked.count < 3 {
            let strictIDs = Set(ranked.map(\.entry.id))
            ranked += typoTolerantMatches(prepared.tokens).filter { !strictIDs.contains($0.entry.id) }
        }
        // Stable sort by rank, preserving declaration order within a rank.
        return
            ranked
            .enumerated()
            .sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }
            .map { ScoredHit(entry: $0.element.entry, rank: $0.element.rank) }
    }

    /// Rows relevant to a whole sentence ("how do I turn on the hotkey?").
    /// `search` needs every word to match, so a sentence rarely hits; this
    /// tries the full text, then each adjacent word pair and each content
    /// word, and sums a per-tier weight per row. Best rows first.
    public static func relevant(toMessage message: String, limit: Int = 6) -> [SettingsSearchEntry] {
        relevantScored(toMessage: message, limit: limit).map(\.entry)
    }

    /// `relevant` with each row's summed weight kept. The whole message
    /// matching one title is worth 4; a word pair 2; a single word 1, each
    /// scaled by the tier it matched in (title 1.0 down to typo-tolerant
    /// keyword 0.25).
    public static func relevantScored(
        toMessage message: String, limit: Int = 6
    ) -> [(entry: SettingsSearchEntry, score: Double)] {
        let words = SearchService.tokenize(message).filter { $0.count > 2 && !messageStopWords.contains($0) }
        guard !words.isEmpty else { return [] }
        var queries: [(text: String, weight: Double)] = [(words.joined(separator: " "), 4)]
        if words.count > 1 {
            for index in 0..<(words.count - 1) {
                queries.append(("\(words[index]) \(words[index + 1])", 2))
            }
        }
        queries += words.map { ($0, 1) }

        var scores: [String: Double] = [:]
        var firstSeen: [String: Int] = [:]
        var byId: [String: SettingsSearchEntry] = [:]
        var order = 0
        for query in queries {
            for hit in searchScored(query.text).prefix(40) {
                let tierWeight: Double = [1.0, 0.6, 0.15, 0.4, 0.25][min(hit.rank, 4)]
                scores[hit.entry.id, default: 0] += query.weight * tierWeight
                if firstSeen[hit.entry.id] == nil {
                    firstSeen[hit.entry.id] = order
                    order += 1
                }
                byId[hit.entry.id] = hit.entry
            }
        }
        return scores.keys
            .sorted { lhs, rhs in
                let (l, r) = (scores[lhs]!, scores[rhs]!)
                return l != r ? l > r : firstSeen[lhs]! < firstSeen[rhs]!
            }
            .prefix(limit)
            .compactMap { id in byId[id].map { ($0, scores[id]!) } }
    }

    /// Function words that match half the catalog and carry no intent.
    static let messageStopWords: Set<String> = [
        "the", "and", "for", "you", "your", "can", "how", "what", "where", "which", "when", "why",
        "does", "did", "please", "want", "would", "could", "should", "with", "from", "that", "this",
        "there", "here", "about", "into", "make", "use", "using", "get", "set", "turn", "change",
        "show", "tell", "let", "need", "have", "has", "are", "was", "will", "its", "it's", "any",
        "all", "some", "more", "less", "than", "then", "also", "just", "now", "osaurus", "setting",
        "settings", "option", "options",
    ]

    /// Every query word must be in a title (rank 3) or section/keyword (rank 4)
    /// word, exactly or within `typoBudget` edits.
    private static func typoTolerantMatches(_ tokens: [String]) -> [(entry: SettingsSearchEntry, rank: Int)] {
        guard tokens.contains(where: { typoBudget(for: $0) > 0 }) else { return [] }
        let prepared = tokens.map { (scalars: Array($0.unicodeScalars), budget: typoBudget(for: $0)) }

        func covers(_ words: [[Unicode.Scalar]]) -> Bool {
            prepared.allSatisfy { token in
                words.contains { word in
                    SearchService.contains(word, token.scalars)
                        || (token.budget > 0 && editDistance(token.scalars, word, limit: token.budget) <= token.budget)
                }
            }
        }

        var ranked: [(entry: SettingsSearchEntry, rank: Int)] = []
        for (entry, fields) in zip(catalog, searchFields) {
            if covers(fields.titleWords) {
                ranked.append((entry, 3))
            } else if covers(fields.allWords) {
                ranked.append((entry, 4))
            }
        }
        return ranked
    }

    /// Each entry's title, section and keywords, prepared once, in `catalog` order.
    private struct SearchFields {
        let title: SearchService.PreparedTarget
        let section: SearchService.PreparedTarget
        let keywords: [SearchService.PreparedTarget]
        /// Title words, then with section and keyword words, for typo-tolerant matching.
        let titleWords: [[Unicode.Scalar]]
        let allWords: [[Unicode.Scalar]]
    }

    private static let searchFields: [SearchFields] = catalog.map { entry in
        let titleWords = SearchService.tokenize(entry.title).map { Array($0.unicodeScalars) }
        let otherWords = SearchService.tokenize(([entry.section] + entry.keywords).joined(separator: " "))
        return SearchFields(
            title: .init(entry.title),
            section: .init(entry.section),
            keywords: entry.keywords.map { .init($0) },
            titleWords: titleWords,
            allWords: titleWords + otherWords.map { Array($0.unicodeScalars) })
    }

    /// Short words must match exactly: one typo in "tts" is another word.
    static func typoBudget(for token: String) -> Int {
        switch token.count {
        case ..<4: 0
        case ..<8: 1
        default: 2
        }
    }

    /// Levenshtein distance, giving up (returning `limit + 1`) once it can't
    /// come in under `limit`.
    static func editDistance(_ lhs: String, _ rhs: String, limit: Int) -> Int {
        editDistance(Array(lhs.unicodeScalars), Array(rhs.unicodeScalars), limit: limit)
    }

    private static func editDistance(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar], limit: Int) -> Int {
        if abs(a.count - b.count) > limit { return limit + 1 }
        if a.isEmpty || b.isEmpty { return max(a.count, b.count) }
        var previous = Array(0...b.count)
        var current = previous
        for i in 1...a.count {
            current[0] = i
            var rowMin = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                rowMin = min(rowMin, current[j])
            }
            if rowMin > limit { return limit + 1 }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// Index rows that land on a tab (or section) rather than a single control.
    /// Completeness tests allow these to lack a dedicated `settingsLandingAnchor`.
    public static let tabLevelEntryIDs: Set<String> = [
        "keys.overview",
        "models.overview",
        "modelDefaults.overview",
        "providers.overview",
        "knowledge.overview",
        "projects.overview",
        "tools.overview",
        "skills.overview",
        "commands.overview",
        "automations.overview",
        "tasks.overview",
        "approvals.overview",
        "automations.queueing",
        "automations.reply",
        "automations.filter",
        "automations.runs",
        "sandbox.overview",
        "insights.overview",
        "agents.overview",
        "agentRuntimes.overview",
        "agents.configure",
        "agents.description",
        "agents.database",
        "imageGeneration.tab",
        "imageGeneration.download",
        "search.providers",
        "search.premium",
        "credits.webSearch",
        "privacy.tab",
        "tools.services",
        "server.connection",
        "server.cors",
        "server.auth",
        "server.generation",
        "server.residency",
        "server.concurrency",
        "server.proxy",
        "server.cache",
        "server.memorySafety",
        "server.decode",
        "server.speculative",
        "server.liveActivity",
        "server.multimodal",
        "server.tools",
        "server.power",
        "server.requestLimits",
        "server.peerInference",
        "computerUse.enable",
        "themes.appearance",
        "memory.settings",
        "workspaces.overview",
        "identity.keys",
        "settings.agents.delegation",
        "settings.agents.delegation.mainChat",
        "settings.agents.delegation.handoff",
        "settings.agents.delegation.starterAgents",
        "settings.agents.delegation.permission",
        "settings.agents.delegation.limits",
        "settings.agents.delegation.advanced",
    ]

    /// Every searchable setting.
    public static var entries: [SettingsSearchEntry] { catalog }

    /// Every searchable setting, grouped by tab in declaration order.
    static let catalog: [SettingsSearchEntry] = [
        // MARK: Settings (General)
        .init(
            id: "settings.general.appearance",
            tab: .settings,
            section: "Appearance",
            title: "Appearance",
            keywords: [
                "theme", "themes", "dark mode", "light mode", "night mode", "system appearance", "color scheme",
                "match macos", "auto dark", "custom theme",
            ],
            disambiguation:
                "System, Light or Dark for every Osaurus window. Custom themes were removed; also in View → Appearance."
        ),
        .init(
            id: "settings.general.textSize",
            tab: .settings,
            section: "Appearance",
            title: "Text Size",
            keywords: [
                "font size", "zoom", "zoom in", "zoom out", "bigger text", "smaller text", "text scale",
                "actual size", "accessibility",
            ],
            disambiguation: "Scales text in every window. Same value as View → Zoom In / Zoom Out."
        ),
        .init(
            id: "settings.general.hotkey",
            tab: .settings,
            section: "Startup",
            title: "Global Hotkey",
            keywords: ["shortcut", "keybinding", "hotkey"],
            declarativeSection: "app"
        ),
        .init(
            id: "settings.general.login",
            tab: .settings,
            section: "Startup",
            title: "Start at Login",
            keywords: ["launch", "startup", "autostart"],
            declarativeSection: "app"
        ),
        .init(
            id: "settings.general.updates",
            tab: .settings,
            section: "Updates",
            title: "Beta Updates",
            keywords: ["beta", "prerelease", "updates", "channel"]
        ),
        .init(
            id: "settings.general.coreModel",
            tab: .modelDefaults,
            section: "Text",
            title: "Core Model",
            keywords: [
                "default model", "core model", "background model", "background jobs", "titles",
                "chat titles", "memory distillation", "transcript cleanup",
            ],
            declarativeSection: "model_defaults"
        ),
        .init(
            id: "server.cli",
            tab: .server,
            section: "Overview",
            title: "Command Line Tool",
            keywords: ["cli", "install cli", "terminal", "symlink", "install", "command line", "osaurus cli"]
        ),
        .init(
            id: "settings.general.reset",
            tab: .settings,
            section: "Danger Zone",
            title: "Factory Reset",
            keywords: ["reset", "wipe", "erase", "maintenance", "danger zone"]
        ),
        .init(
            id: "settings.general.dock",
            tab: .settings,
            section: "Startup",
            title: "Hide Dock Icon",
            keywords: ["dock", "menu bar", "menubar", "hide dock"]
        ),

        // MARK: Devices (sidebar Sharing ▸ "Devices"; ManagementTab.devices)
        .init(
            id: "settings.sync.network",
            tab: .devices,
            section: "Sync",
            title: "Sync Chats",
            keywords: ["sync", "syncing", "other devices", "multiple macs", "second mac", "cross device", "iphone sync"],
            disambiguation: "Devices ▸ Sync Chats sends and receives chats with this account's other devices, end-to-end encrypted. Off keeps chats on this Mac until it is turned back on. API, automation, channel, schedule and other headless chats never sync; they stay on this Mac. Not Knowledge git sync or workspace sharing."
        ),
        .init(
            id: "settings.sync.networkMode",
            tab: .devices,
            section: "Sync",
            title: "Find Devices",
            keywords: ["same network", "anywhere", "anywhere (beta)", "relay", "relay servers", "osaurus servers", "discovery server", "different networks", "local network", "lan", "iphone can't reach mac", "iphone on cellular", "turn on anywhere"],
            disambiguation: "Same Network finds devices on the local network only. Anywhere (Beta) also connects through Osaurus relay and discovery servers (a list Osaurus publishes, applied the next time sync starts) so devices on different networks sync, an iPhone on cellular included. Chats stay end-to-end encrypted. Not Sharing ▸ Access ▸ Remote Access, which gives an agent a public URL for other people."
        ),
        .init(
            id: "settings.sync.hostAgents",
            tab: .devices,
            section: "Sync",
            title: "Run Agents for My Other Devices",
            keywords: ["host agents", "hosted runs", "run on this mac", "agents on my other mac", "use agents from another mac", "remote agent", "own devices", "on my mac", "iphone agents", "phone uses mac"],
            disambiguation: "On (default): this Mac lists its agents to the account's other devices, and runs a chat there when one of them is picked under \"On <this Mac>\" in the chat sidebar. Runs use this Mac's models, tools and files; tool approvals are answered on the device the user is chatting on. The iPhone app needs this on to use this Mac's agents. Off: the list empties and new requests get a short reply saying so. Not workspace sharing, which shares agents with other people."
        ),
        .init(
            id: "settings.sync.status",
            tab: .devices,
            section: "Sync",
            title: "Status",
            keywords: [
                "sync status", "connected devices", "waiting to send", "pending messages", "earlier chats", "import progress",
                "older messages", "history download", "relay", "connected directly", "your devices aren't connecting",
            ]
        ),
        .init(
            id: "settings.sync.devices",
            tab: .devices,
            section: "Devices",
            title: "Devices",
            keywords: [
                "my devices", "device list", "remove device", "revoke device", "lost device", "stolen device",
                "remove and change phrase", "remove only",
            ]
        ),
        .init(
            id: "settings.sync.addDevice",
            tab: .devices,
            section: "Add a Device",
            title: "Add a Device",
            keywords: [
                "pair", "pairing", "pairing code", "show code", "qr code", "link device", "new device",
                "add iphone", "pair iphone", "iphone", "ios", "mobile", "osaurus connect", "iosaurus",
            ],
            disambiguation: "One flow for a Mac or an iPhone: scan the code with the Osaurus iPhone app, or paste the link into Join Another Device on another Mac. Not Devices ▸ Mobile, the 6-digit code kept for one release for an iPhone app that doesn't offer Sync yet."
        ),
        .init(
            id: "settings.sync.join",
            tab: .devices,
            section: "Add a Device",
            title: "Join Another Device",
            keywords: ["pairing link", "join account", "enter pairing code"]
        ),
        .init(
            id: "settings.devices.iPhoneApp",
            tab: .devices,
            section: "Add a Device",
            title: "Osaurus for iPhone",
            keywords: ["iphone app", "testflight", "ios app", "download iphone", "mobile app", "iosaurus"]
        ),
        .init(
            id: "settings.devices.keepAwake",
            tab: .devices,
            section: "iPhone",
            title: "Keep Mac Awake for iPhone",
            keywords: ["sleep", "awake", "reachable", "phone", "remote", "idle sleep", "paired iphone"],
            disambiguation: "Keeps this Mac from idle-sleeping while an iPhone is one of the account's devices, so the iPhone can use its agents. Not General ▸ Chat ▸ Keep Mac Awake While Agents Run, which only covers runs in progress."
        ),
        .init(
            id: "settings.devices.continuePhoneChats",
            tab: .devices,
            section: "iPhone",
            title: "Continue iPhone Chats on This Mac",
            keywords: [
                "handoff", "continue", "resume", "iphone", "phone", "bring to front", "focus", "come back",
                "return", "unlock", "continue phone chats",
            ]
        ),
        .init(
            id: "settings.connect.pairing",
            tab: .connect,
            section: "Pair an iPhone",
            title: "Generate 6-Digit Code",
            keywords: [
                "iphone", "ios", "mobile", "phone", "pair", "pairing code", "6 digit", "six digit",
                "iosaurus", "osaurus connect", "legacy pairing", "old iphone app",
            ],
            disambiguation: "The 6-digit code for an Osaurus iPhone app that doesn't offer Sync yet, kept for one release. It turns off once an iPhone joins in Devices ▸ Add a Device, which is the way to add an iPhone that has Sync."
        ),
        .init(
            id: "settings.connect.pairedDevice",
            tab: .connect,
            section: "Your iPhone",
            title: "Unpair",
            keywords: ["unpair", "revoke phone", "paired device", "remove iphone", "mobile access"]
        ),
        .init(
            id: "settings.connect.reachAnywhere",
            tab: .connect,
            section: "Availability",
            title: "Remote Access for This iPhone",
            keywords: ["relay", "remote access", "away from home", "cellular", "tunnel", "outside network"],
            disambiguation: "Relay for the iPhone paired with the 6-digit code. An iPhone added in Devices reaches this Mac through Sync instead."
        ),
        .init(
            id: "settings.connect.keepAwake",
            tab: .connect,
            section: "Availability",
            title: "Keep Mac Awake for This iPhone",
            keywords: ["sleep", "awake", "reachable", "phone", "remote", "idle sleep"],
            disambiguation: "Only for the iPhone paired with the 6-digit code. Not Devices ▸ iPhone ▸ Keep Mac Awake for iPhone, which covers an iPhone added through Sync."
        ),
        .init(
            id: "settings.sync.recoveryPhrase",
            tab: .devices,
            section: "Recovery",
            title: "Recovery Phrase",
            keywords: ["24 words", "backup phrase", "seed phrase", "recovery words"]
        ),
        .init(
            id: "settings.sync.restorePhrase",
            tab: .devices,
            section: "Recovery",
            title: "Restore From Phrase",
            keywords: ["restore sync", "recover chats", "restored backup", "enter recovery phrase"]
        ),
        .init(
            id: "settings.sync.useWalletPhrase",
            tab: .devices,
            section: "Recovery",
            title: "Use My Osaurus Recovery Phrase",
            keywords: [
                "one recovery phrase", "wallet phrase", "link wallet", "osaurus id phrase", "two phrases",
                "unlock chats", "unlock with my osaurus recovery phrase", "lost keychain",
            ],
            disambiguation:
                "Makes the Osaurus ID recovery phrase (Osaurus ID ▸ Master Address) restore sync too, so there is one phrase. Shown when this Mac has an Osaurus ID that isn't linked yet. Not Restore From Phrase, which reads another sync account's chats."
        ),
        .init(
            id: "settings.sync.storage",
            tab: .devices,
            section: "Storage",
            title: "Synced Chats",
            keywords: ["sync storage", "this mac only", "chat storage", "disk usage", "attachments size"]
        ),
        .init(
            id: "settings.sync.supportReport",
            tab: .devices,
            section: "Support",
            title: "Support Report",
            keywords: ["sync logs", "sync diagnostics", "bug report", "sync problem"]
        ),
        .init(
            id: "settings.sync.signOutKeep",
            tab: .devices,
            section: "Sign Out",
            title: "Sign Out and Keep Chats",
            keywords: ["sign out of sync", "stop syncing", "leave sync", "unpair"]
        ),
        .init(
            id: "settings.sync.signOutRemove",
            tab: .devices,
            section: "Sign Out",
            title: "Sign Out and Remove Chats",
            keywords: ["reset sync", "delete synced chats", "remove sync data"]
        ),

        // MARK: Access (sidebar Sharing ▸ "Access"; ManagementTab.access)
        .init(
            id: "access.remoteAccess",
            tab: .access,
            section: "Remote Access",
            title: "Remote Access",
            keywords: [
                "reach from anywhere", "public url", "relay", "agent url", "remote", "tunnel",
                "expose agent", "share outside", "internet access", "agent.osaurus.ai",
            ],
            disambiguation: "Per agent: gives the agent a public address through the Osaurus relay so guests and teammates can reach it when they aren't on your network. Off, only people on your network and your own devices (through Sync) reach it. Not Devices ▸ Find Devices, which is how your own devices sync."
        ),
        .init(
            id: "access.guests",
            tab: .access,
            section: "Guests",
            title: "Guests",
            keywords: [
                "guest link", "invite link", "who has access", "revoke access", "remote connections",
                "paired clients", "access keys", "shared links", "guest list",
            ],
            disambiguation: "Everyone who redeemed a guest link to one of your agents, with when they last used it; revoke one to cut them off. Guest links are made from an agent's Share… menu. Teammates are under Workspaces, your own Macs and iPhones under Devices."
        ),
        .init(
            id: "access.sharedWithYou",
            tab: .access,
            section: "Shared With You",
            title: "Shared With You",
            keywords: ["agents shared with me", "added agents", "remote agents", "guest agents", "other people's agents"],
            disambiguation: "Agents other people shared with you through a guest link. They run on the owner's Mac. Agents teammates share are under Workspaces."
        ),
        .init(
            id: "server.peerInference",
            tab: .access,
            section: "Model Sharing",
            title: "Share My Models for Inference",
            keywords: ["peer inference", "share models", "share my models", "lan inference", "expose models", "model sharing"],
            disambiguation: "Lets teammates, guests and peers on your network run the models you expose in Server ▸ Models through this Mac. Off, they see no models. Chatting with agents you share works either way."
        ),

        // MARK: Chat (sidebar "Chat"; ManagementTab.chat)
        .init(
            id: "settings.orchestrator.systemPrompt",
            tab: .orchestrator,
            section: "Instructions",
            title: "System Prompt",
            keywords: ["persona", "instructions", "system prompt", "orchestrator"],
            declarativeSection: "default_agent"
        ),
        .init(
            id: "settings.orchestrator.name",
            tab: .orchestrator,
            section: "Identity",
            title: "Orchestrator Name",
            keywords: ["name", "rename", "display name", "orchestrator", "default agent", "osaurus"],
            declarativeSection: "default_agent"
        ),
        .init(
            id: "settings.orchestrator.avatar",
            tab: .orchestrator,
            section: "Identity",
            title: "Orchestrator Avatar",
            keywords: [
                "avatar", "picture", "photo", "image", "icon", "mascot", "dino", "upload image",
                "pick a dino", "orchestrator",
            ],
            disambiguation: "Avatar for the Orchestrator. Other agents set theirs in Agents ▸ the agent ▸ Identity."
        ),
        .init(
            id: "settings.orchestrator.restoreDefaults",
            tab: .orchestrator,
            section: "Danger Zone",
            title: "Restore Defaults",
            keywords: ["reset orchestrator", "restore orchestrator", "orchestrator defaults", "danger zone"],
            disambiguation: "Orchestrator → Danger Zone. Restores the Orchestrator's identity settings.",
            declarativeSection: "default_agent"
        ),

        // MARK: Architect (sidebar "Architect"; ManagementTab.architect)
        .init(
            id: "settings.architect.name",
            tab: .architect,
            section: "Identity",
            title: "Architect Name",
            keywords: ["name", "rename", "display name", "architect", "workflow designer"]
        ),
        .init(
            id: "settings.architect.avatar",
            tab: .architect,
            section: "Identity",
            title: "Architect Avatar",
            keywords: [
                "avatar", "picture", "photo", "image", "icon", "mascot", "dino", "upload image",
                "pick a dino", "architect",
            ]
        ),
        .init(
            id: "settings.architect.instructions",
            tab: .architect,
            section: "Instructions",
            title: "Extra Instructions",
            keywords: [
                "architect instructions", "architect prompt", "system prompt", "persona", "workflow designer",
                "house style",
            ],
            disambiguation: "Added to the Architect's built-in instructions; it cannot replace them."
        ),
        .init(
            id: "settings.architect.model",
            tab: .architect,
            section: "Model",
            title: "Architect Model",
            keywords: ["architect", "workflow designer", "design a workflow", "new workflow", "model"],
            disambiguation: "Model for the Architect agent only; each workflow binds its own models in setup."
        ),
        .init(
            id: "settings.architect.restoreDefaults",
            tab: .architect,
            section: "Danger Zone",
            title: "Restore Defaults",
            keywords: ["reset architect", "restore architect", "architect defaults", "danger zone"],
            disambiguation: "Architect → Danger Zone. Restores the Architect's name, avatar and instructions."
        ),
        .init(
            id: "settings.architect.permissions.draft",
            tab: .architect,
            section: "Permissions",
            title: "Edit the Draft",
            keywords: [
                "workflow_draft", "architect permissions", "approval", "ask before", "always allow", "deny",
                "tool permission",
            ]
        ),
        .init(
            id: "settings.architect.permissions.test",
            tab: .architect,
            section: "Permissions",
            title: "Run Test Workflows",
            keywords: [
                "workflow_test", "architect permissions", "approval", "ask before", "always allow", "deny",
                "test run", "tool permission",
            ]
        ),

        // MARK: Configurator (Agents ▸ Configurator; ManagementTab.configurator)
        .init(
            id: "settings.configurator.name",
            tab: .configurator,
            section: "Identity",
            title: "Name",
            keywords: ["configurator", "settings helper", "osaurus help", "configurator name"],
            disambiguation: "The Configurator's name is fixed. It answers Osaurus questions and makes settings changes when you ask in chat."
        ),
        .init(
            id: "settings.configurator.instructions",
            tab: .configurator,
            section: "Instructions",
            title: "Extra Instructions",
            keywords: [
                "configurator instructions", "configurator prompt", "system prompt", "persona", "settings helper",
            ],
            disambiguation: "Added to the Configurator's built-in instructions; it cannot replace them.",
            declarativeSection: "configurator"
        ),
        .init(
            id: "settings.configurator.model",
            tab: .configurator,
            section: "Model & Generation",
            title: "Configurator Model",
            keywords: ["configurator", "settings helper", "settings changes", "osaurus questions", "model"],
            disambiguation: "Model that answers Osaurus questions and makes settings changes. Unset uses the Orchestrator's model.",
            declarativeSection: "configurator"
        ),
        .init(
            id: "settings.configurator.temperature",
            tab: .configurator,
            section: "Model & Generation",
            title: "Temperature",
            keywords: ["configurator temperature", "settings helper", "randomness", "sampling"],
            disambiguation: "Temperature for the Configurator only. Off uses the model's own default.",
            declarativeSection: "configurator"
        ),
        .init(
            id: "settings.configurator.history",
            tab: .configurator,
            section: "Configuration History",
            title: "Configuration History",
            keywords: [
                "configuration history", "settings history", "version history", "versions", "undo settings",
                "revert settings", "restore configuration", "roll back", "rollback", "what changed",
                "compare configuration", "diff", "export configuration", "name a version", "snapshot",
            ],
            disambiguation: "Agents → Configurator → Configuration History. Every recorded version of the agents, models, tools, automations and other declarative settings: compare two versions, name one so it is always kept, export it as YAML, or revert to it through the approval card. Server runtime, secrets, themes and working folders are not versioned."
        ),
        .init(
            id: "settings.configurator.restoreDefaults",
            tab: .configurator,
            section: "Danger Zone",
            title: "Restore Defaults",
            keywords: ["reset configurator", "restore configurator", "configurator defaults", "danger zone"],
            disambiguation: "Configurator → Danger Zone. Clears the Configurator's instructions, model and temperature.",
            declarativeSection: "configurator"
        ),
        .init(
            id: "settings.chat.autoGenerateTitles",
            tab: .chat,
            section: "Behavior",
            title: "Automatically Name Chats",
            keywords: ["title", "auto title", "rename", "chat name", "summary"],
            declarativeSection: "chat"
        ),
        .init(
            id: "settings.chat.generateFollowUps",
            tab: .chat,
            section: "Behavior",
            title: "Suggest Follow-Up Questions",
            keywords: ["follow up", "followup", "suggestions", "next question", "prompts", "suggested"],
            declarativeSection: "chat"
        ),
        .init(
            id: "settings.chat.cmdNNewChat",
            tab: .chat,
            section: "Composer",
            title: "⌘+N Starts a New Chat in the Current Window",
            keywords: ["cmd n", "new chat", "shortcut", "keyboard", "new window", "hotkey"]
        ),
        .init(
            id: "settings.chat.smoothStreaming",
            tab: .chat,
            section: "Transcript",
            title: "Smooth Streaming",
            keywords: ["typewriter", "streaming pace", "token reveal", "smooth tokens"],
            declarativeSection: "chat"
        ),
        .init(
            id: "settings.chat.thinkingDisplay",
            tab: .chat,
            section: "Transcript",
            title: "Expand Thinking While Streaming",
            keywords: [
                "thinking", "reasoning", "expand thinking", "show thinking",
                "chain of thought",
            ],
            declarativeSection: "chat"
        ),
        .init(
            id: "settings.chat.activityRollup",
            tab: .chat,
            section: "Transcript",
            title: "Group Thinking & Tool Activity",
            keywords: [
                "group thinking", "tool activity", "rollup", "worked for",
                "collapse tools", "activity row",
            ],
            declarativeSection: "chat"
        ),
        .init(
            id: "settings.chat.clipboard",
            tab: .chat,
            section: "Behavior",
            title: "Clipboard Monitoring",
            keywords: ["clipboard", "copied text", "grab selection", "paste context"],
            declarativeSection: "chat"
        ),
        .init(
            id: "settings.chat.discoveryCards",
            tab: .chat,
            section: "Behavior",
            title: "Show Discovery Cards",
            keywords: [
                "discovery", "tips", "suggestions card", "what to try", "new chat card", "skip setup",
                "setup suggestions", "hide set up osaurus",
            ],
            disambiguation: "Not Suggest Follow-Up Questions, which offers next questions after a reply."
        ),
        .init(
            id: "settings.chat.setUpOsaurus",
            tab: .chat,
            section: "Behavior",
            title: "Set Up Osaurus",
            keywords: ["setup", "onboarding", "getting started", "what is left", "first run"],
            disambiguation: "Lists what is left to discover in a new chat; it does not restart the first run."
        ),
        .init(
            id: "settings.chat.collapseLongPastes",
            tab: .chat,
            section: "Composer",
            title: "Collapse Long Pastes",
            keywords: [
                "paste", "pasted", "pasted content", "long paste", "large paste",
                "paste chip", "paste attachment", "collapse", "dictation",
                "typewhisper", "insert as text", "composer", "input",
            ],
            disambiguation:
                "Controls what happens when you paste into the message box. Clipboard Monitoring is separate and only offers text you copied elsewhere."
        ),
        .init(
            id: "settings.chat.keepAwakeForAgentRuns",
            tab: .settings,
            section: "Power",
            title: "Keep Mac Awake While Agents Run",
            keywords: ["sleep", "awake", "caffeinate", "idle sleep", "power", "keep awake"],
            declarativeSection: "chat"
        ),
        .init(
            id: "settings.chat.compactionModel",
            tab: .modelDefaults,
            section: "Text",
            title: "Compaction Model",
            keywords: [
                "compaction", "compact", "summarize", "context", "summary model",
                "auto compact", "compact conversation", "fallback", "context full",
                "summary thinking off", "empty summary", "truncated summary",
            ],
            disambiguation:
                "Which model writes the summary. Unset means the chat's current model. Summary requests use Thinking Off when supported; chat and agent settings are unchanged. Compaction runs automatically near the limit and from the Compact button in the context budget popover.",
            declarativeSection: "model_defaults"
        ),
        .init(
            id: "settings.orchestrator.temperature",
            tab: .orchestrator,
            section: "Generation",
            title: "Temperature",
            keywords: ["randomness", "creativity", "sampling"],
            declarativeSection: "default_agent"
        ),
        .init(
            id: "settings.orchestrator.maxTokens",
            tab: .orchestrator,
            section: "Generation",
            title: "Max Output Tokens",
            keywords: [
                "response length", "output tokens", "generation config",
                "max new tokens", "max tokens",
            ],
            disambiguation:
                "Per-response length for the Orchestrator — not the chat context window, KV retention, or Server Sampling Defaults.",
            declarativeSection: "default_agent"
        ),
        .init(
            id: "settings.chat.contextLength",
            tab: .server,
            section: "Cache",
            title: "Context Window Cap (tokens)",
            keywords: [
                "context window", "context", "context length", "context budget",
                "token budget", "model maximum", "context window cap",
                "context cap", "max context", "limit context",
            ],
            subTab: "cache",
            disambiguation:
                "Lowers every model's chat window. Not Memory Budget, not Orchestrator max output tokens, not KV retention."
        ),
        .init(
            id: "settings.server.contextMetadataFallback",
            tab: .server,
            section: "Cache",
            title: "Unknown-Model Metadata Fallback (tokens)",
            keywords: [
                "metadata fallback", "unknown model", "context length fallback",
            ],
            subTab: "cache",
            disambiguation:
                "Used only when a model does not report a maximum. Does not constrain local bundles — use Context Window Cap for that."
        ),
        .init(
            id: "settings.server.kvRetention",
            tab: .server,
            section: "Cache",
            title: "KV Retention Override (tokens)",
            keywords: ["kv retention", "cache window", "kv cap", "retention override"],
            subTab: "cache",
            disambiguation:
                "GPU/SSD KV retention, not the semantic chat context window."
        ),
        .init(
            id: "settings.chat.topP",
            tab: .chat,
            section: "Advanced",
            title: "Top P Override",
            keywords: ["nucleus sampling", "top-p", "top p"]
        ),
        .init(
            id: "settings.chat.toolAttempts",
            tab: .chat,
            section: "Advanced",
            title: "Max Tool Attempts",
            keywords: ["tool calls", "agent loop", "attempts", "step limit"],
            disambiguation: "The Architect always gets at least 80 steps per message; a higher value here applies to it too."
        ),
        // The control that answers "make every tool always allowed" — 83 tools
        // ship `enabled: true` with an EMPTY policy map, and
        // `ToolConfiguration.policy(for:)` defaults to `.ask`, so without this
        // toggle every one of them prompts. Lives at the top of Tools & MCP →
        // All Tools, beside the per-tool policies it overrides.
        .init(
            id: "tools.autoAllowAll",
            tab: .tools,
            section: "All Tools",
            title: "Auto-Allow All Tool Calls",
            keywords: [
                "auto allow", "auto-allow", "allow all tools", "allow tools",
                "tool permission", "tool permissions", "approve tools",
                "approval", "always allow", "never ask", "tool prompt",
            ],
            subTab: "All"
        ),
        .init(
            id: "settings.chat.spellCheck",
            tab: .chat,
            section: "Composer",
            title: "Check Spelling While Typing",
            keywords: [
                "spell", "spelling", "spellcheck", "spell check", "spell checker",
                "grammar", "typo", "typos", "dictionary", "underline", "misspelled",
                "composer", "input",
            ],
            declarativeSection: "chat"
        ),

        // MARK: Keys
        .init(
            id: "keys.overview",
            tab: .keys,
            title: "Vault",
            keywords: [
                "credentials", "credential", "secrets", "secret", "environment variable", "environment variables",
                "env", "env var", "variables", "api key", "api keys", "token", "tokens", "password",
                "keychain", "mcp credentials", "plugin secrets",
            ],
            disambiguation: "Vault (General ▸ Vault) is the one place for API keys, tokens, passwords and variables that agents, MCP servers, plugins, channels and workflows use. A key is shared by all agents unless an agent has its own value. Model provider, web search, voice, Hugging Face and GitHub keys are listed under App Keys and still saved where they were. Not Access Keys (Server → Access Keys), which let other apps call this Osaurus."
        ),
        .init(
            id: "keys.add",
            tab: .keys,
            title: "Add Key",
            keywords: ["new key", "add secret", "add credential", "add variable", "add environment variable"]
        ),
        .init(
            id: "keys.missing",
            tab: .keys,
            section: "Your Keys",
            title: "Missing Keys",
            keywords: ["needs setup", "missing secret", "missing credential", "not set", "needs a key"],
            subTab: "keys",
            disambiguation: "Top of the Your Keys tab: every MCP server, plugin, channel or workflow that needs a key before it can run. Set fills it for all agents."
        ),
        .init(
            id: "keys.allAgents",
            tab: .keys,
            section: "Your Keys",
            title: "All Agents",
            keywords: [
                "your keys", "shared keys", "global secrets", "global credentials", "shared secrets", "reveal secret",
                "show value", "copy secret", "view password", "touch id", "edit key", "delete key",
            ],
            subTab: "keys",
            disambiguation: "The Your Keys tab: keys shared by every agent. Click a key to edit it. An agent with its own value for the same name uses that instead. Show and Copy on a key ask for Touch ID or your Mac password; the value hides again after a few seconds and a copied value is cleared from the clipboard after a minute."
        ),
        .init(
            id: "keys.agentOverrides",
            tab: .keys,
            section: "Your Keys",
            title: "Use a Different Value For",
            keywords: [
                "agent secrets", "agent keys", "agent override", "per agent key", "override secret",
                "agent credentials", "only for this agent",
            ],
            subTab: "keys",
            disambiguation: "On the Your Keys tab, the agent picker beside the search field shows the keys one agent uses. Use a Different Value For (in a key's … menu) gives one agent its own value; Use the Value for All Agents removes it. Agent ▸ Sandbox ▸ Keys lists the same keys."
        ),
        .init(
            id: "keys.search",
            tab: .keys,
            title: "Search keys",
            keywords: ["find key", "find secret", "find credential"]
        ),
        .init(
            id: "keys.editor.name",
            tab: .keys,
            section: "Add Key",
            title: "Name",
            keywords: ["key name", "secret name", "variable name", "rename key"],
            disambiguation: "In the Add/Edit Key sheet: the name programs read the value by, such as GITHUB_TOKEN. Renaming keeps the MCP servers, plugins and workflows that use it connected."
        ),
        .init(
            id: "keys.editor.scope",
            tab: .keys,
            section: "Add Key",
            title: "Who Can Use It",
            keywords: ["all agents", "one agent", "agent only key", "key scope"],
            disambiguation: "In the Add Key sheet: All agents, or only one agent. A value for one agent replaces the value for all agents for that agent."
        ),
        .init(
            id: "keys.editor.value",
            tab: .keys,
            section: "Add Key",
            title: "Value",
            keywords: ["secret value", "key value", "paste api key", "change secret"],
            disambiguation: "In the Add/Edit Key sheet. When editing, leave it blank to keep the saved value."
        ),
        .init(
            id: "keys.editor.hideValue",
            tab: .keys,
            section: "Add Key",
            title: "Hide Value",
            keywords: ["variable", "plain value", "secret vs variable", "masked"],
            disambiguation: "In the Add/Edit Key sheet. On (the default) keeps the value hidden like a password; off makes it a variable shown as plain text, such as a region or account id."
        ),
        .init(
            id: "keys.editor.exposeToSandbox",
            tab: .keys,
            section: "Add Key",
            title: "Agents Can Use This When Running Code",
            keywords: ["sandbox environment", "expose to sandbox", "sandbox secret", "inject env"],
            disambiguation: "In the Add/Edit Key sheet and a key's … menu. When on, agents get the key as an environment variable when they run commands or plugins in the sandbox. Off by default for keys an MCP server, plugin, channel or workflow created."
        ),
        .init(
            id: "keys.accounts",
            tab: .keys,
            section: "Accounts",
            title: "Accounts",
            keywords: [
                "accounts", "oauth", "signed in", "sign-ins", "mcp sign in", "provider sign in", "sessions",
                "add session", "second account", "make default", "sign out", "sign in again", "discord bot",
                "telegram bot", "slack workspace", "workflow connections",
            ],
            subTab: "accounts",
            disambiguation:
                "The Accounts tab of the Vault: every sign-in (MCP servers, model providers, workflow connections, channel bots) as sessions grouped by service, each with Add Session, a Default, Rename, Sign In Again, Sign Out and Remove. Discord and Telegram bots and Slack workspaces are listed here so an agent can post as one, but they are added, renamed and removed in Channels (Manage in Channels, or Open in Channels on a bot). API keys are on Your Keys."
        ),
        .init(
            id: "keys.accounts.manageInChannels",
            tab: .keys,
            section: "Accounts",
            title: "Manage in Channels",
            keywords: ["add discord bot", "add telegram bot", "add slack workspace", "remove bot", "rename bot"],
            subTab: "accounts",
            disambiguation:
                "On the Discord, Telegram and Slack cards of Vault → Accounts. Opens Settings → Channels, where bots and workspaces are added (Add Bot / Add Workspace on the channel's heading), renamed (Name) and removed. Open in Channels on a bot's … menu opens that bot's own settings."
        ),
        .init(
            id: "keys.accounts.agent",
            tab: .keys,
            section: "Accounts",
            title: "This agent uses",
            keywords: [
                "agent session", "assign session", "which account", "agent account", "per agent sign in",
                "compartmentalize", "run as account",
            ],
            subTab: "accounts",
            disambiguation:
                "The agent picker beside the search field on Vault → Accounts. Pick an agent, then pick the session it uses for each service; agents without one, the Orchestrator, and runs on shared keys use the service's default."
        ),
        .init(
            id: "keys.appKeys",
            tab: .keys,
            title: "App Keys",
            keywords: [
                "provider api key", "openai key", "anthropic key", "web search key", "tts key", "voice key",
                "hugging face token", "github token",
            ],
            subTab: "appKeys",
            disambiguation: "The App Keys tab: keys Osaurus itself uses for model providers, web search, voice, Hugging Face and GitHub. Edit them here or where they were; agents cannot override them."
        ),
        .init(
            id: "keys.appKeys.tts",
            tab: .keys,
            section: "Voice",
            title: "Text-to-Speech Server",
            keywords: [
                "tts api key", "voice api key", "remote voice server", "speech server key", "openai tts key",
                "text to speech key",
            ],
            subTab: "appKeys",
            disambiguation: "The API key sent to the OpenAI-compatible text-to-speech server when Voice reads replies aloud. Listed under App Keys only while Voice → Text to Speech → Advanced → Engine uses that server (or a key is still saved); Open Voice Settings goes to the server's address, model and voice. Not needed for the on-device engine."
        ),

        // MARK: Settings (Notifications / Legal)
        // Usage-analytics + crash-reporting consent now live at the top of the
        // Privacy tab's Overview, so these route there (and glow on landing).
        .init(
            id: "settings.privacy.usage",
            tab: .privacy,
            section: "Data Collection",
            title: "Share Anonymous Usage Data",
            keywords: ["telemetry", "analytics", "tracking"]
        ),
        .init(
            id: "settings.privacy.crash",
            tab: .privacy,
            section: "Data Collection",
            title: "Send Crash Reports",
            keywords: ["crash", "diagnostics", "freeze"]
        ),
        .init(
            id: "settings.notifications.toasts",
            tab: .settings,
            section: "Notifications",
            title: "Show Notifications",
            keywords: ["toast", "toasts", "notifications", "alerts", "banners", "popups"],
            disambiguation: "General → Notifications → Show Notifications: the master switch for every toast inside the app. Off, the In the app choice in each row below (Approvals, Questions from Agents…) can't be picked. Desktop notifications and the iPhone follow each row's menu, not this switch; Desktop Notifications Only in the Background keeps desktop notifications quiet while Osaurus is frontmost.",
            declarativeSection: "app"
        ),
        .init(
            id: "settings.notifications.approvals",
            tab: .settings,
            section: "Notifications",
            title: "Approvals",
            keywords: [
                "approval notifications", "tool approval", "owner approval", "teammate approval", "approve from phone",
                "notification channels", "desktop notification", "push",
            ],
            disambiguation: "General → Notifications → Approvals menu: check In the app (a toast and the Inbox badge), Desktop (macOS notifications with Allow / Deny) or iPhone; Push is listed as coming soon. Includes a teammate's tool call on your shared agent when that agent has Require Approval for Teammate Tool Calls on. Whether a tool needs approval is per tool under Tools, not here."
        ),
        .init(
            id: "settings.notifications.questions",
            tab: .settings,
            section: "Notifications",
            title: "Questions from Agents",
            keywords: ["clarify", "clarifying question", "needs your input", "workflow form", "waiting for input"],
            disambiguation: "Where an agent's clarifying question or a workflow form reaches you. Desktop notifications offer a Reply field."
        ),
        .init(
            id: "settings.notifications.messages",
            tab: .settings,
            section: "Notifications",
            title: "Inbound Messages",
            keywords: [
                "slack notifications", "discord notifications", "telegram notifications", "imessage", "whatsapp",
                "email", "channel messages", "message notifications",
            ],
            disambiguation: "Notifications for messages arriving on any channel or from another participant in a shared conversation. Which channel messages run an agent is set by automations, not here."
        ),
        .init(
            id: "settings.notifications.sharedConversations",
            tab: .settings,
            section: "Notifications",
            title: "Shared Agent Conversations",
            keywords: ["teammate using my agent", "shared agent", "workspace", "someone is using", "remote agent"],
            disambiguation: "A notification when a teammate, an invite-link peer, or another person's agent starts talking to one of your shared agents. The conversation also opens as a read-only tab."
        ),
        .init(
            id: "settings.notifications.agentNotices",
            tab: .settings,
            section: "Notifications",
            title: "Agent Notifications",
            keywords: ["notify tool", "agent notify", "ping", "ask owner"],
            disambiguation: "Notifications an agent sends with its notify tool, or a shared agent asking for you."
        ),
        .init(
            id: "settings.notifications.desktopWhenInactive",
            tab: .settings,
            section: "Notifications",
            title: "Desktop Notifications Only in the Background",
            keywords: [
                "focus", "do not disturb", "frontmost", "background notifications",
                "only notify on desktop when osaurus is in the background",
            ],
            disambiguation: "General → Notifications. On (default), macOS notifications for requests that have a card in the chat are skipped while Osaurus is frontmost; the card and the toast (Show Notifications) show it. Off, Desktop notifications post even while you're in the app."
        ),
        .init(
            id: "settings.legal",
            tab: .settings,
            section: "Legal",
            title: "Terms & Privacy Policy",
            keywords: ["terms", "privacy policy", "legal", "about"]
        ),

        // MARK: Voice (subTab values are VoiceTab raw values)
        .init(
            id: "voice.stt.model",
            tab: .voice,
            section: "Setup",
            title: "Speech Model",
            keywords: ["transcription model", "parakeet", "whisper", "speech recognition", "dictation"],
            subTab: "Setup"
        ),
        .init(
            id: "voice.setup.sensitivity",
            tab: .voice,
            section: "Setup",
            title: "Voice Sensitivity",
            keywords: ["sensitivity", "microphone sensitivity", "detection level", "voice detection"],
            subTab: "Setup",
            disambiguation: "Shared by chat voice, Transcription Mode, and Wake Word."
        ),
        .init(
            id: "voice.chat.enable",
            tab: .voice,
            title: "Voice Input in Chat",
            keywords: ["voice input", "microphone button", "mic button", "chat voice", "speech to text"],
            subTab: "Speech To Text"
        ),
        .init(
            id: "voice.transcription.enable",
            tab: .voice,
            section: "Transcription",
            title: "Enable Transcription Mode",
            keywords: ["transcription mode", "dictation", "type with voice", "voice typing", "any app"],
            subTab: "Transcription"
        ),
        .init(
            id: "voice.stt.hotkey",
            tab: .voice,
            section: "Transcription",
            title: "Activation Hotkey",
            keywords: [
                "dictation hotkey", "push to talk", "voice hotkey", "shortcut",
                "global hotkey", "activation hotkey",
            ],
            subTab: "Transcription"
        ),
        .init(
            id: "voice.stt.cleanup",
            tab: .voice,
            section: "Transcription",
            title: "Clean Up Transcription",
            keywords: ["filler words", "clean up", "post process", "um uh", "polish transcript"],
            subTab: "Transcription"
        ),
        .init(
            id: "voice.stt.stopMode",
            tab: .voice,
            section: "Transcription",
            title: "Stop Mode",
            keywords: ["stop mode", "automatic", "manual", "finished speaking", "endpointing"],
            subTab: "Transcription"
        ),
        .init(
            id: "voice.stt.pause",
            tab: .voice,
            section: "Transcription",
            title: "Pause Detection",
            keywords: ["pause", "auto stop", "auto send", "stop after silence"],
            subTab: "Transcription"
        ),
        .init(
            id: "voice.stt.confirmation",
            tab: .voice,
            section: "Transcription",
            title: "Confirmation Delay",
            keywords: ["confirmation", "cancel window", "delay before send"],
            subTab: "Transcription"
        ),
        .init(
            id: "voice.stt.silence",
            tab: .voice,
            section: "Transcription",
            title: "Silence Timeout",
            keywords: ["silence", "timeout", "close voice input", "inactivity"],
            subTab: "Transcription"
        ),
        .init(
            id: "voice.stt.vad",
            tab: .voice,
            section: "Wake Word",
            title: "Wake Word",
            keywords: ["vad", "wake word", "always listening", "agent name", "voice activation"],
            subTab: "VAD Mode"
        ),
        .init(
            id: "voice.tts.voice",
            tab: .voice,
            section: "Text to Speech",
            title: "Spoken Voice",
            keywords: ["tts", "read aloud", "speech synthesis", "voice"],
            subTab: "Text To Speech"
        ),
        .init(
            id: "voice.tts.engine",
            tab: .voice,
            section: "Text to Speech",
            title: "Engine",
            keywords: ["tts engine", "pockettts", "on-device tts", "openai compatible tts"],
            subTab: "Text To Speech"
        ),
        .init(
            id: "voice.tts.remote",
            tab: .voice,
            section: "Text to Speech",
            title: "OpenAI-Compatible Server",
            keywords: [
                "remote tts", "tts endpoint", "endpoint", "openai tts", "speech server",
                "text-to-speech server", "tts api key",
            ],
            subTab: "Text To Speech"
        ),
        .init(
            id: "voice.tts.temperature",
            tab: .voice,
            section: "Text to Speech",
            title: "Voice Temperature",
            keywords: ["tts temperature", "expressiveness", "variation"],
            subTab: "Text To Speech"
        ),
        .init(
            id: "voice.models",
            tab: .voice,
            section: "Models",
            title: "Voice Models",
            keywords: ["download model", "speech model", "parakeet"],
            subTab: "Models"
        ),

        // MARK: Server (subTab values are ServerSettingsSection raw values)
        .init(
            id: "server.connection",
            tab: .server,
            section: "Connection",
            title: "Port & Network",
            keywords: ["port", "expose", "network", "host", "bind"],
            subTab: "connection"
        ),
        .init(
            id: "server.cors",
            tab: .server,
            section: "Connection",
            title: "Allowed Origins (CORS)",
            keywords: ["cors", "origins", "cross origin"],
            subTab: "connection"
        ),
        .init(
            id: "server.auth",
            tab: .server,
            section: "Authentication",
            title: "API Authentication",
            keywords: ["api key", "auth", "token", "bearer"],
            subTab: "authentication"
        ),
        .init(
            id: "server.localRouterSpend",
            tab: .server,
            section: "Overview",
            title: "Allow local API access without a key",
            keywords: [
                "loopback", "unkeyed", "local api", "router spend", "credits", "osaurus router",
                "no access key", "localhost",
            ],
            disambiguation: "Lets local processes spend Osaurus Router credits through the HTTP API without an access key. Formerly on Wallet & Credits."
        ),
        .init(
            id: "server.localAccessKey",
            tab: .server,
            section: "Authentication",
            title: "Require Access Key for Local Admin Routes",
            keywords: [
                "local access key", "local api key", "require key locally", "loopback auth", "localhost key",
                "browser origin", "refuse browser", "protect sessions", "protect agents", "mcp key",
                "admin config key", "local admin routes",
            ],
            subTab: "authentication",
            disambiguation:
                "Makes callers on this Mac send an access key to /sessions, /agents, /attention, /conversations/*, /devices/*, /mcp/*, /admin/config/* and /admin/import/*, and refuses browser origins there unless listed by name in Allowed Origins (CORS). Not the access key list itself (Server → Overview) and not the CORS list (Server → Connection)."
        ),
        .init(
            id: "server.generation",
            tab: .server,
            section: "Sampling Defaults",
            title: "Generation Defaults",
            keywords: [
                "top p", "temperature", "sampling", "sampler", "top k", "min p",
                "defaults", "max tokens",
            ],
            subTab: "sampling",
            disambiguation:
                "Server/API sampling defaults. Orchestrator Max Output Tokens and agent Max Tokens are separate."
        ),
        .init(
            id: "server.residency",
            tab: .server,
            section: "Model Memory",
            title: "Model Residency",
            keywords: ["eviction policy", "idle", "keep model loaded", "unload after", "30 seconds", "close window"],
            subTab: "modelMemory"
        ),
        .init(
            id: "server.concurrency",
            tab: .server,
            section: "Concurrency & Batching",
            title: "Concurrency",
            keywords: ["parallel", "batch", "requests", "threads"],
            subTab: "concurrency"
        ),
        .init(
            id: "settings.server.concurrentSessions",
            tab: .server,
            section: "Concurrency & Batching",
            title: "Concurrent Sessions",
            keywords: ["parallel", "batch engine", "local subagents", "maximum requests"],
            subTab: "concurrency",
            disambiguation: "Shared engine ceiling for same-model local work; memory safety and Continuous Batching can reduce the effective limit."
        ),
        .init(
            id: "settings.server.prefillChunkSize",
            tab: .server,
            section: "Concurrency & Batching",
            title: "Prompt Prefill Chunk Size",
            keywords: ["prompt processing", "prefill step", "tokens per step", "chunk"],
            subTab: "concurrency"
        ),
        .init(
            id: "server.proxy",
            tab: .server,
            section: "Global Proxy",
            title: "Global Proxy",
            keywords: ["proxy", "http proxy", "socks"],
            subTab: "globalProxy"
        ),
        .init(
            id: "server.cache",
            tab: .server,
            section: "Cache",
            title: "Prompt Cache",
            // The controls in this section are labelled "Disk Cache", "SSD
            // Cache (L2)", "Disk Cache Size (% of disk)" and "Clear SSD
            // Cache". None of those phrases resolved, so the section could
            // not be found by any name it shows the user — the same defect
            // D5 fixed for the sampler row.
            keywords: [
                "cache", "kv cache", "prefix",
                "disk cache", "ssd cache", "l2 cache", "disk cache size",
                "clear cache", "clear ssd cache", "disk cache directory",
                "eviction", "evict", "paged kv", "gpu cache",
            ],
            subTab: "cache"
        ),
        .init(
            id: "settings.server.prefixCache",
            tab: .server,
            section: "Cache",
            title: "Prefix Cache",
            keywords: ["prefix reuse", "master reuse switch"],
            subTab: "cache"
        ),
        .init(
            id: "settings.server.gpuCache",
            tab: .server,
            section: "Cache",
            title: "Enable GPU Cache",
            keywords: ["paged kv", "hot tier"],
            subTab: "cache"
        ),
        .init(
            id: "settings.server.gpuCacheBlockSize",
            tab: .server,
            section: "Cache",
            title: "Block Size (tokens)",
            keywords: ["paged block tokens"],
            subTab: "cache"
        ),
        .init(
            id: "settings.server.gpuCacheMaxBlocks",
            tab: .server,
            section: "Cache",
            title: "Max Blocks",
            keywords: ["gpu cache memory"],
            subTab: "cache"
        ),
        .init(
            id: "settings.server.diskCache",
            tab: .server,
            section: "Cache",
            title: "Disk Cache",
            keywords: ["ssd reuse", "l2"],
            subTab: "cache"
        ),
        .init(
            id: "settings.server.clearDiskCache",
            tab: .server,
            section: "Cache",
            title: "Clear SSD Cache",
            keywords: ["purge cached conversations", "save cache directory before clearing"],
            subTab: "cache"
        ),
        .init(
            id: "settings.server.diskCacheDirectory",
            tab: .server,
            section: "Cache",
            title: "Disk Cache Directory",
            keywords: ["ssd path", "cache folder"],
            subTab: "cache"
        ),
        .init(
            id: "settings.server.ssmReDerive",
            tab: .server,
            section: "Cache",
            title: "Re-derive SSM State After Generation",
            keywords: ["hybrid", "mamba", "companion"],
            subTab: "cache"
        ),
        .init(
            id: "settings.server.diskCacheSize",
            tab: .server,
            section: "Cache",
            title: "Disk Cache Size (% of disk)",
            keywords: ["ssd cache size", "increase cache size", "disk cache limit", "cache capacity"],
            subTab: "cache"
        ),
        .init(
            id: "settings.server.diskCacheAutomatic",
            tab: .server,
            section: "Cache",
            title: "Use Automatic Cache Size",
            keywords: ["automatic ssd", "reset cache size", "legacy cache size", "available disk space"],
            subTab: "cache"
        ),
        .init(
            id: "server.memorySafety.keepModelInMemory",
            tab: .server,
            section: "Memory Safety",
            title: "Keep Model in Memory",
            keywords: ["pin weights", "wired memory", "gpu residency", "page eviction"],
            subTab: "memorySafety"
        ),
        .init(
            id: "server.memorySafety",
            tab: .server,
            section: "Memory Safety",
            title: "Memory Safety",
            keywords: ["memory", "ram", "guard", "oom", "limits"],
            subTab: "memorySafety"
        ),
        .init(
            id: "settings.server.memorySafetyMode",
            tab: .server,
            section: "Memory Safety",
            title: "Mode",
            keywords: ["memory safety mode", "safe auto", "strict memory", "performance mode", "no automatic limits"],
            subTab: "memorySafety"
        ),
        .init(
            id: "settings.server.memorySafetyLevel",
            tab: .server,
            section: "Memory Safety",
            title: "Safety Level",
            keywords: ["memory safety level", "memory slider", "ram safety", "oom protection"],
            subTab: "memorySafety"
        ),
        .init(
            id: "settings.server.failClosedUnknownEstimate",
            tab: .server,
            section: "Memory Safety",
            title: "Fail Closed When Estimate Is Unknown",
            keywords: ["unknown memory estimate", "refuse load", "fail closed"],
            subTab: "memorySafety"
        ),
        .init(
            id: "settings.server.physicalMemoryFraction",
            tab: .server,
            section: "Memory Safety",
            title: "Custom Physical Memory Fraction",
            keywords: ["memory fraction", "ram fraction", "physical memory limit", "ram cap"],
            subTab: "memorySafety"
        ),
        .init(
            id: "settings.server.allocatorCacheCap",
            tab: .server,
            section: "Memory Safety",
            title: "Allocator Cache Cap (MB)",
            keywords: ["allocator cache", "mlx cache cap", "metal cache"],
            subTab: "memorySafety"
        ),
        .init(
            id: "settings.server.maxConcurrentSequences",
            tab: .server,
            section: "Memory Safety",
            title: "Max Concurrent Sequences",
            keywords: ["concurrent sequences", "decode slots", "memory concurrency cap"],
            subTab: "memorySafety"
        ),
        .init(
            id: "server.memorySafety.loadAllocatorCap",
            tab: .server,
            section: "Memory Safety",
            title: "Load Allocator Cap",
            keywords: ["load allocator", "inference reuse", "allocator cache", "freed buffers", "memory limit"],
            subTab: "memorySafety",
            disambiguation:
                "Load-time freed-buffer reuse target. Inference has a separate process-wide target. An explicit Allocator Cache Cap bounds the selected target; occupancy can exceed it until the next allocation trims the pool."
        ),
        .init(
            id: "server.decode",
            tab: .server,
            section: "Decode Performance",
            title: "Decode Performance",
            keywords: [
                "decode", "throughput", "speed", "tokens per second",
                "deepseek", "dsv4", "activation qat", "graph fidelity",
            ],
            subTab: "decodePerformance"
        ),
        .init(
            id: "server.decode.tiedHeadCodec",
            tab: .server,
            section: "Decode Performance",
            title: "Tied LM Head Codec",
            keywords: [
                "tied head", "codec", "passthrough", "Passthrough (model load dtype)",
                "model load dtype", "q4", "q6", "q8",
            ],
            subTab: "decodePerformance"
        ),
        .init(
            id: "server.speculative",
            tab: .server,
            section: "Speculative Decoding",
            title: "Speculative Decoding",
            keywords: [
                "speculative", "mtp", "native mtp", "draft model", "speculative depth", "bundle default", "default", "on adaptive", "off ar", "adaptive",
                // The drafter picker lives in this card. Someone who has
                // just downloaded a DFlash 2 checkpoint searches for its
                // name, not for "speculative decoding".
                "dflash", "dflash 2", "drafter", "block diffusion",
            ],
            subTab: "speculative"
        ),
        .init(
            id: "server.liveActivity",
            tab: .server,
            section: "Live Activity",
            title: "Live Activity",
            keywords: [
                "live activity", "dynamic island", "status", "sampler", "sampler last used",
            ],
            subTab: "liveActivity"
        ),
        .init(
            id: "server.multimodal",
            tab: .server,
            section: "Multimodal",
            title: "Multimodal",
            keywords: ["vision", "image", "audio", "multimodal"],
            subTab: "multimodal"
        ),
        .init(
            id: "server.tools",
            tab: .server,
            section: "Tools & Templates",
            title: "Tools & Templates",
            // "Reasoning Parser Override" lives in this section, and reasoning
            // was unfindable by ANY of its own words — `reasoning`, `thinking`,
            // `effort` and `preserve thinking` all returned 0 matches while
            // three real controls existed. Same defect D5 fixed for the
            // sampler row.
            keywords: [
                "tool calling", "templates", "chat template",
                "reasoning", "reasoning parser", "reasoning effort", "effort",
                "thinking", "preserve thinking", "think tags",
            ],
            subTab: "tools"
        ),
        .init(
            id: "server.power",
            tab: .server,
            section: "Power",
            title: "Power",
            keywords: ["power", "battery", "low power", "energy"],
            subTab: "power"
        ),
        .init(
            id: "server.requestLimits",
            tab: .server,
            section: "Request Limits",
            title: "Request Limits",
            keywords: ["body size", "request limits", "max body", "advanced http"],
            subTab: "requestLimits"
        ),

        // MARK: Permissions / Computer Use / Privacy tabs
        .init(
            id: "permissions.tools",
            tab: .permissions,
            title: "macOS Permissions",
            keywords: [
                "system permissions", "tcc", "accessibility", "microphone",
                "screen recording", "full disk access", "privacy",
            ],
            disambiguation:
                "macOS grants (TCC). Not the Tools catalog Auto/Ask/Deny policies, and not Chat folder-tool permissions."
        ),
        .init(
            id: "server.codexCLI",
            tab: .server,
            title: "Use with Codex CLI",
            keywords: [
                "codex", "codex cli", "openai codex", "config.toml", "model_providers",
                "codex profile", "external client", "coding agent",
            ],
            disambiguation:
                "Points OpenAI's Codex CLI at this Osaurus as a local model provider. Not the \"OpenAI Codex\" remote provider under Providers, which is Osaurus using a ChatGPT subscription."
        ),
        .init(
            id: "computerUse.enable",
            tab: .computerUse,
            title: "Computer Use",
            keywords: [
                "screen control", "cursor", "automation", "accessibility", "per-app",
                "autonomy", "app allowlist", "screen context",
            ]
        ),
        .init(
            id: "computerUse.models",
            tab: .computerUse,
            title: "AppleScript Models",
            keywords: ["applescript model", "download applescript", "osascript model", "scripting model"],
            disambiguation: "Opens Local Models → AppleScript. The default AppleScript model is chosen in Models → Model Defaults."
        ),
        .init(
            id: "browser.enable",
            tab: .browser,
            title: "Browser Use",
            keywords: [
                "browser", "web", "browse", "session", "sign in", "login", "cookies", "webkit",
            ]
        ),
        .init(
            id: "browser.sessions",
            tab: .browser,
            title: "Browser Sessions",
            keywords: ["sessions", "profiles", "signed in", "reset browser", "browsing data"]
        ),

        // MARK: Channels / Integrations
        .init(
            id: "agentChannels.overview",
            tab: .agentChannels,
            title: "Channels",
            keywords: [
                "agent channels", "integrations", "channels", "discord", "slack", "telegram",
                "imessage", "whatsapp", "email", "custom json", "custom http", "remote channel",
            ],
            declarativeSection: "channels"
        ),
        .init(
            id: "agentChannels.globalWrites",
            tab: .agentChannels,
            section: "Sending",
            title: "Allow Agents to Send Messages",
            keywords: [
                "kill switch", "disable writes", "remote writes", "channel writes",
                "sending", "read-only", "pause sending",
            ]
        ),
        .init(
            id: "agentChannels.focusOnInbound",
            tab: .agentChannels,
            section: "Incoming",
            title: "Focus Chat on Incoming Messages",
            keywords: [
                "focus", "bring to front", "bring forward", "activate window", "popup",
                "pop up", "attention", "dedicated device", "kiosk", "monitor", "incoming",
                "inbound", "channel window", "channel tab", "new message", "steal focus",
            ],
            disambiguation:
                "Channels-only: brings the channel conversation's chat tab and window forward when a message arrives. Toast notifications are under Settings → General → Notifications."
        ),
        .init(
            id: "agentChannels.discord",
            tab: .agentChannels,
            section: "Native Integrations",
            title: "Discord",
            keywords: ["discord bot token", "discord server ids", "discord channel allowlist"]
        ),
        .init(
            id: "agentChannels.slack",
            tab: .agentChannels,
            section: "Native Integrations",
            title: "Slack",
            keywords: [
                "slack bot token", "slack signing secret", "socket mode",
                "slack workspace ids", "slack channel allowlist",
                "accept messages sent through apps", "slack api", "chat.postmessage",
                "user token", "bot_message_denied", "phone shortcut",
            ]
        ),
        .init(
            id: "agentChannels.telegram",
            tab: .agentChannels,
            section: "Native Integrations",
            title: "Telegram",
            keywords: [
                "telegram bot token", "telegram chat ids", "sender allowlist",
                "telegram channel allowlist", "telegram long polling",
                "telegram getupdates", "store incoming messages",
                "allow sending on telegram", "receive messages", "long poll limit",
                "long poll timeout seconds", "default read limit", "ignore self messages",
                "ignore bot messages",
            ]
        ),
        .init(
            id: "agentChannels.imessage",
            tab: .agentChannels,
            section: "Native Integrations",
            title: "iMessage",
            keywords: [
                "imessage", "messages app", "imessage chats", "full disk access",
                "messages automation", "imsg helper", "sender allowlist",
                "tapback", "unsend", "sip", "library validation",
                "allow sending on imessage", "receive messages", "store incoming messages",
                "default read limit", "poll interval seconds", "ingest attachments",
                "ignore messages you send", "enable advanced actions", "advanced actions",
            ]
        ),
        .init(
            id: "agentChannels.whatsapp",
            tab: .agentChannels,
            section: "Native Integrations",
            title: "WhatsApp",
            keywords: [
                "whatsapp", "whatsapp web", "whatsapp qr code", "qr code", "link device",
                "whatsmeow",
                "osaurus-wa helper", "sender allowlist", "whatsapp chats",
                "phone number", "group jid",
                "allow sending on whatsapp", "receive messages", "default read limit",
                "ignore messages you send", "send read receipts", "handle attachments",
                "max attachment size",
            ]
        ),
        .init(
            id: "agentChannels.email",
            tab: .agentChannels,
            section: "Native Integrations",
            title: "Email",
            keywords: [
                "email", "mail", "mail app", "imap", "smtp", "gmail", "icloud mail", "outlook", "inbox",
                "email trigger", "email automation", "when an email arrives", "reply to email",
                "add account", "add mail account", "delete account", "app password", "test connection",
                "reply server", "reply server security", "reply server port", "from address",
                "watch", "mailboxes", "receive mail", "allowed senders", "@domain", "only unread mail",
                "include the message text", "message length limit", "check every",
                "mail that arrived while osaurus was closed", "default read limit",
                "allow sending email", "open unsent replies as drafts", "mail drafts", "check now",
                "verify incoming message",
            ],
            disambiguation:
                "Channels → Email (replaces the old Email automation trigger). Each Email account watches one Mail app or IMAP account with its own mailboxes, allowed senders and switches; add more with Add Account on its heading in Channels. Each mailbox is a room and each mail thread a conversation. Only allowed senders (addresses or @domain) reach an agent. Agents reply in the thread: Mail app accounts send through Mail, IMAP accounts through their reply server (SMTP over TLS on port 465; no STARTTLS, not copied to Sent). Unsent replies can open as Mail drafts.",
            declarativeSection: "channels"
        ),
        .init(
            id: "agentChannels.discord.addAccount",
            tab: .agentChannels,
            section: "Connected",
            title: "Add Bot",
            keywords: [
                "another discord bot", "second discord bot", "multiple discord bots", "extra discord bot",
                "discord bot per agent", "one bot per agent",
            ],
            disambiguation:
                "Channels → Connected → Discord heading → Add Bot (the Add Channel picker does the same once Discord is connected). Opens the same Discord setup: paste the bot token and press Connect; the bot becomes its own channel connection (discord-<id>), named after the bot, with its own servers, channels, senders, routing rules and sending. The heading appears once the first Discord bot is connected.",
            declarativeSection: "channels"
        ),
        .init(
            id: "agentChannels.telegram.addAccount",
            tab: .agentChannels,
            section: "Connected",
            title: "Add Bot",
            keywords: [
                "another telegram bot", "second telegram bot", "multiple telegram bots", "extra telegram bot",
                "telegram bot per agent",
            ],
            disambiguation:
                "Channels → Connected → Telegram heading → Add Bot (the Add Channel picker does the same once Telegram is connected). Opens the same Telegram setup: paste the bot token and press Connect; the bot becomes its own channel connection (telegram-<id>), named after the bot, with its own chats, senders, routing rules and sending.",
            declarativeSection: "channels"
        ),
        .init(
            id: "agentChannels.slack.addAccount",
            tab: .agentChannels,
            section: "Connected",
            title: "Add Workspace",
            keywords: [
                "another slack workspace", "second slack workspace", "multiple slack workspaces",
                "extra workspace", "slack team",
            ],
            disambiguation:
                "Channels → Connected → Slack heading → Add Workspace (the Add Channel picker does the same once Slack is connected). Opens the same Slack setup: paste the workspace's bot and app tokens and press Connect; it becomes its own channel connection (slack-<team id>), named after the workspace, with its own channels, senders, routing rules and sending.",
            declarativeSection: "channels"
        ),
        .init(
            id: "agentChannels.email.addAccount",
            tab: .agentChannels,
            section: "Connected",
            title: "Add Account",
            keywords: [
                "another email account", "second email account", "multiple email accounts", "add email account",
                "personal mail", "another mailbox account",
            ],
            disambiguation:
                "Channels → Connected → Email heading → Add Account (the Add Channel picker does the same once Email is set up). Opens the same Email setup: choose the mail account and press Add Account; it becomes its own channel connection (email-<mail account id>) with its own mailboxes, allowed senders, receive and send switches and routing rules.",
            declarativeSection: "channels"
        ),
        .init(
            id: "agentChannels.accountName",
            tab: .agentChannels,
            section: "Connect",
            title: "Name",
            keywords: [
                "account name", "bot name", "workspace name", "rename bot", "rename workspace",
                "rename email account", "work mail",
            ],
            disambiguation:
                "Top of a Discord, Telegram, Slack or Email account's Connect tab. Filled in from the bot, workspace or mail account when it connects; what you type replaces it and shows in Channels, routing rules, triggers and history (\"Discord · Support bot\").",
            declarativeSection: "channels"
        ),
        .init(
            id: "agentChannels.removeAccount",
            tab: .agentChannels,
            section: "Connect",
            title: "Remove this bot",
            keywords: [
                "remove bot", "delete bot", "remove this workspace", "remove workspace", "remove this account",
                "remove email account", "remove account",
            ],
            disambiguation:
                "Bottom of an extra bot's, workspace's or Email account's Connect tab (not the channel's first account) → Remove…. Removes its settings, token and listener and deletes the triggers on it, after a confirmation that names them. Messages it received stay in history; an Email account's mail account stays in place.",
            declarativeSection: "channels"
        ),
        .init(
            id: "agentChannels.ruleAccount",
            tab: .agentChannels,
            section: "Routing",
            title: "Account",
            keywords: ["which bot", "which workspace", "which email account", "rule account", "trigger account"],
            disambiguation:
                "In a channel rule's Edit… sheet, shown when the channel has more than one account (bots, workspaces or email accounts). Picks which account the rule listens on; the channel's first account is listed first.",
            declarativeSection: "channels"
        ),
        .init(
            id: "agentChannels.n8n",
            tab: .agentChannels,
            section: "Native Integrations",
            title: "n8n",
            keywords: [
                "n8n", "workflow automation", "webhook bridge", "channel secret",
                "hmac signature", "shared secret header", "poll url", "task poll",
                "host.docker.internal", "plaintext allowed", "secure channel required",
                "http request", "conversation_id", "topology", "docker desktop",
                "name it", "who answers", "pair", "prove it", "display name", "connection id",
                "who may speak", "connect n8n", "remote callers",
            ],
            disambiguation:
                "The n8n channel sheet (Settings → Channels → n8n): Name it → Where is your n8n? → Who answers? → Pair → Prove it. n8n calls Osaurus; the only n8n URL Osaurus stores is the optional Outbound Webhook URL under Who answers?."
        ),
        .init(
            id: "agentChannels.n8n.enabled",
            tab: .agentChannels,
            section: "Native Integrations",
            title: "n8n channel on/off",
            keywords: [
                "enable n8n channel", "disable n8n channel", "channel enabled", "pause n8n",
                "connection_disabled", "turn off n8n", "turn on n8n",
            ],
            disambiguation:
                "The switch on the n8n card in Settings → Channels. Off answers every inbound, poll and ping with 403 connection_disabled. It is no longer inside the setup sheet."
        ),
        .init(
            id: "agentChannels.n8n.callerLocation",
            tab: .agentChannels,
            section: "Native Integrations",
            title: "Where is your n8n?",
            keywords: [
                "where is n8n", "n8n location", "caller location", "this mac", "docker desktop on this mac",
                "another machine on my network", "remote (hosted or another network)", "lan n8n", "remote n8n",
                "hosted n8n",
                "n8n cloud", "relay", "expose to network", "allow plaintext http",
                "plaintext from other machines", "remote callers", "426",
            ],
            disambiguation:
                "Step 2 of the n8n sheet. Picks which URL the pairing code carries (127.0.0.1, host.docker.internal, LAN address, or relay URL), whether Relay is required, and whether the plaintext toggle is shown (LAN only)."
        ),
        .init(
            id: "agentChannels.n8n.plaintextAllowed",
            tab: .agentChannels,
            section: "Native Integrations",
            title: "Allow plaintext HTTP from other machines",
            keywords: [
                "plaintext http", "remote callers", "plaintext allowed", "secure channel required",
                "426", "trusted lan", "lan plaintext", "n8n plaintext",
            ],
            disambiguation:
                "Shown only when Where is your n8n? is 'Another machine on my network'. Off: non-loopback callers must speak Secure Channel or get 426. Remote uses Secure Channel via Relay and never needs this."
        ),
        .init(
            id: "agentChannels.n8n.relay",
            tab: .agentChannels,
            section: "Native Integrations",
            title: "Relay for the bound agent",
            keywords: [
                "enable relay", "n8n relay", "relay connected", "public url", "agent.osaurus.ai",
                "hosted n8n relay", "expose agent to internet", "take over relay",
            ],
            disambiguation:
                "Under Who answers? in the n8n sheet, shown for Remote (required) and LAN (optional). Enables Relay on the agent picked as the default target; the pairing code is issued once the relay reports connected."
        ),
        .init(
            id: "agentChannels.n8n.outboundWebhookURL",
            tab: .agentChannels,
            section: "Native Integrations",
            title: "Outbound Webhook URL",
            keywords: [
                "n8n url", "n8n webhook url", "push replies to n8n", "osaurus trigger", "webhook trigger",
                "sign outbound bodies", "push replies", "where do i enter my n8n url",
            ],
            disambiguation:
                "Under Who answers? → Push replies to n8n (optional). The only place an n8n URL is entered; must be public https. Leave empty for poll-only replies."
        ),
        .init(
            id: "agentChannels.n8n.channelSecret",
            tab: .agentChannels,
            section: "Native Integrations",
            title: "Channel Secret",
            keywords: [
                "channel secret", "rotate secret", "generate secret", "n8n secret", "hmac key",
                "keychain secret", "webhook secret",
            ],
            disambiguation:
                "Under Pair → Advanced in the n8n sheet. Generated automatically for a new channel and carried inside the pairing code; rotating it invalidates every issued code."
        ),
        .init(
            id: "agentChannels.n8n.pairingCode",
            tab: .agentChannels,
            section: "Native Integrations",
            title: "Pair with n8n",
            keywords: [
                "pairing code", "pair n8n", "pair", "n8n node", "n8n credential", "osaurus channel credential",
                "n8n-nodes-osaurus", "@osaurus/n8n-nodes-osaurus", "remote n8n", "hosted n8n",
                "relay url", "secure channel", "channel secret", "rotate secret",
                "end-to-end encrypted", "osrs-n8n", "ping", "credential test", "no pairing code yet",
            ],
            disambiguation:
                "Inside the n8n channel sheet (Settings → Channels → n8n → Pair). One copyable string the Osaurus n8n community node decodes; it contains the channel secret and only the URL valid for Where is your n8n?. Withheld until it can work (e.g. Relay connected for Remote). Not the osk-v1 access key from Share Agent."
        ),
        .init(
            id: "agentChannels.n8n.pendingApprovals",
            tab: .agentChannels,
            section: "Native Integrations",
            title: "Who may speak",
            keywords: [
                "approve workflow", "allow workflow", "deny workflow", "pending approval", "first contact",
                "waiting for approval", "wants to use", "allowed conversations", "allowed senders",
                "allowlist", "edit allowlists by hand", "conversation_id", "sender.id", "accept bot senders",
                "prove it",
            ],
            disambiguation:
                "Step 5 (Prove it) of the n8n sheet. The first run of a workflow appears here as 'Workflow X (sender Y) wants to use <channel> — Allow / Deny'; Allow adds its ids to the allowlists. Manual allowlist editing is under Advanced in the same step."
        ),
        .init(
            id: "agentChannels.custom_http",
            tab: .agentChannels,
            section: "Native Integrations",
            title: "Custom HTTP",
            keywords: [
                "custom http connections", "custom json channels", "custom json", "json-defined http channel",
                "webhook", "agent-channels.json", "secret references",
            ]
        ),
        // Channels → a channel's sheet → Routing ("Who answers messages")
        // and Sending ("Agents that post on their own"). Every channel
        // automation is one row of the routing table; posting is the agent's
        // stored destination bindings for the connection.
        .init(
            id: "agentChannels.routing",
            tab: .agentChannels,
            section: "Routing",
            title: "Who answers messages",
            keywords: [
                "who answers", "answers messages", "routing", "routing rules", "channel routing", "inbound routing",
                "reply routing", "rules table", "per-room agent", "room agent", "channel agents", "agent on channel",
                "many agents", "multiple agents", "several channels", "aliases", "alias", "starts with",
                "only when mentioned", "mention", "replies automatically", "after approval", "reply approval",
                "duplicate rule", "custom routing", "message rules", "channel automations", "workflow on message",
            ],
            disambiguation:
                "Open the channel under Channels (Discord, Slack, Telegram, iMessage, WhatsApp, or an n8n connection) → Routing. One row per rule: Where (rooms or Any room), Who answers (agent or workflow), Replies (Automatically / After approval). Rules that start with an alias win, then room rules, then Any room. Channel messages are not listed under Automations.",
            declarativeSection: "channels"
        ),
        .init(
            id: "agentChannels.addRule",
            tab: .agentChannels,
            section: "Routing",
            title: "Add Rule",
            keywords: [
                "add rule", "add agent to channel", "let agent answer", "agent respond on slack",
                "agent respond on discord", "connect agent to channel", "assign agent", "answer messages",
                "route room to agent", "run workflow on message", "slack trigger", "discord trigger", "imessage rule",
            ],
            disambiguation:
                "In a channel's sheet → Routing. Pick an agent or workflow and the rooms it answers in (or Any room). Edit… on a row opens the full rule (aliases, filters, instructions, queueing).",
            declarativeSection: "channels"
        ),
        .init(
            id: "agentChannels.routingSummary",
            tab: .agentChannels,
            section: "Routing",
            title: "Where messages go",
            keywords: [
                "where messages go", "routing summary", "nobody answers", "unanswered room", "two agents answer",
                "several agents answer", "routing warning", "lost messages", "everywhere else",
            ],
            disambiguation:
                "Under the routing table in a channel's sheet. One line per room (and Everywhere else) with who answers, plus warnings when nobody answers, a readable room has no rule, or several agents answer the same message.",
            declarativeSection: "channels"
        ),
        .init(
            id: "agentChannels.posting",
            tab: .agentChannels,
            section: "Sending",
            title: "Agents that post on their own",
            keywords: [
                "posts on its own", "posting", "agent posting", "proactive", "publish", "destination",
                "destinations", "binding", "outbound", "autonomous", "ask first", "without asking", "auto-send",
                "where it can post", "place", "edit places", "post without asking",
            ],
            disambiguation:
                "In a channel's sheet → Sending, below the room write allowlist. Per agent: Off, Ask first, or Without asking, for every writable room. Replies to messages are set per rule under Routing, not here.",
            declarativeSection: "channels"
        ),
        .init(
            id: "agentChannels.addPostingAgent",
            tab: .agentChannels,
            section: "Sending",
            title: "Add Agent",
            keywords: ["add posting agent", "let agent post", "agent post to slack", "post only agent"],
            disambiguation:
                "In a channel's sheet → Sending → Agents that post on their own. Adds an agent that may post to the channel without answering messages. Needs sending turned on for the channel.",
            declarativeSection: "channels"
        ),
        .init(
            id: "agentChannels.overviewGrouping",
            tab: .agentChannels,
            section: "Connected",
            title: "By agent",
            keywords: [
                "by agent", "by channel", "all channels", "all agents", "channel overview", "which agent answers where",
                "receives from", "routes to", "sends", "answers on", "posts on its own",
            ],
            disambiguation:
                "The switch above the connected channels table on Channels. By channel: Receives from / Routes to / Sends per channel. By agent: where each agent answers and posts across every channel."
        ),
        .init(
            id: "agentChannels.outbox",
            tab: .agentChannels,
            section: "Outbox",
            title: "Channel Outbox",
            keywords: [
                "outbox", "pending approval", "approve message", "queued messages",
                "outbound activity", "drafts",
            ]
        ),

        // MARK: Images & Video tab. The image panel controls (steps, size,
        // sampler, upscale…) render on Local Models → Image, so those rows
        // live on `.models` with the `LocalModelKind` raw value as subTab.
        .init(
            id: "imageGeneration.tab",
            tab: .imageGeneration,
            title: "Images & Video",
            keywords: [
                "image", "image generation", "text to image", "ideogram",
                "diffusion", "mflux", "generate image", "edit image",
            ]
        ),
        .init(
            id: "imageGeneration.models",
            tab: .imageGeneration,
            section: "Models",
            title: "Default Image and Video Models",
            keywords: ["generation model", "edit model", "default image model"],
            disambiguation: "A link to Models → Model Defaults, where the image and video models are chosen."
        ),
        .init(
            id: "imageGeneration.permission",
            tab: .imageGeneration,
            section: "Permissions",
            title: "Image Jobs",
            keywords: ["image permission", "ask", "deny", "always allow"]
        ),
        .init(
            id: "imageGeneration.videoPermission",
            tab: .imageGeneration,
            section: "Permissions",
            title: "Video Jobs",
            keywords: ["video permission", "video jobs", "quoted video", "ask", "deny"]
        ),
        .init(
            id: "imageGeneration.video",
            tab: .imageGeneration,
            section: "Recent Video Jobs",
            title: "Recent Video Jobs",
            keywords: [
                "video", "text to video", "image to video", "video model", "venice", "video jobs", "wan",
                "local video",
            ]
        ),
        .init(
            id: "imageGeneration.loadPolicy",
            tab: .modelDefaults,
            section: "Images & Video",
            title: "Image Model Load Policy",
            keywords: ["load policy", "image jobs", "unload", "residency", "gpu"]
        ),
        .init(
            id: "imageGeneration.previews", tab: .models, section: "Image",
            title: "Live previews", keywords: ["image preview", "denoising preview", "progress image"], subTab: "image"
        ),
        .init(
            id: "imageGeneration.steps", tab: .models, section: "Image",
            title: "Steps", keywords: ["flux 3", "klein", "denoising steps", "sampling steps"], subTab: "image",
            disambiguation: "Denoising steps in the Generate/Edit panel and chat image controls. FLUX 3 accepts any positive count."
        ),
        .init(
            id: "imageGeneration.width", tab: .models, section: "Image",
            title: "Width", keywords: ["flux 3", "klein", "image width", "image size", "pixels"], subTab: "image",
            disambiguation: "FLUX 3 local image dimensions in the Generate/Edit panel and chat size picker."
        ),
        .init(
            id: "imageGeneration.height", tab: .models, section: "Image",
            title: "Height", keywords: ["flux 3", "klein", "image height", "image size", "pixels"], subTab: "image",
            disambiguation: "FLUX 3 local image dimensions in the Generate/Edit panel and chat size picker."
        ),
        .init(
            id: "imageGeneration.sampler",
            tab: .models,
            section: "Image",
            title: "Sampler",
            keywords: ["image sampling", "heun", "euler"],
            subTab: "image"
        ),
        .init(
            id: "imageGeneration.scheduler",
            tab: .models,
            section: "Image",
            title: "Scheduler",
            keywords: ["image schedule", "sigma", "linear"],
            subTab: "image"
        ),
        .init(
            id: "imageGeneration.shift",
            tab: .models,
            section: "Image",
            title: "Timestep shift",
            keywords: ["image shift", "flow matching", "sigma shift"],
            subTab: "image"
        ),
        .init(
            id: "imageGeneration.upscale",
            tab: .models,
            section: "Image",
            title: "Upscale",
            keywords: ["seedvr2", "super resolution", "upscale image", "scale", "2x", "4x"],
            subTab: "image"
        ),
        .init(
            id: "imageGeneration.download",
            tab: .imageGeneration,
            section: "Models",
            title: "Download Image Models",
            keywords: ["download", "image model", "ideogram", "mflux", "catalog", "import"]
        ),

        // MARK: Subagents (Orchestrator delegation policy + runtime knobs)
        // There is no global master switch and no dedicated Spawn tab anymore.
        // Settings → Orchestrator: Model readiness, Working Folder, Subagents
        // (Allowed subagents / Permission / Limits / Advanced), Delegations.
        // Custom-agent spawn policy remains in each agent's Subagents tab.
        .init(
            id: "settings.orchestrator.modelReadiness",
            tab: .orchestrator,
            section: "Model & Generation",
            title: "Model Readiness",
            keywords: [
                "orchestrator model", "context window", "tools ok", "tools limited",
                "recommended model", "model too small", "readiness", "can the orchestrator use tools",
            ]
        ),
        .init(
            id: "settings.orchestrator.workingFolder",
            tab: .orchestrator,
            section: "Working Folder",
            title: "Working Folder",
            keywords: [
                "orchestrator folder", "folder access", "file access", "read files",
                "file_read", "file_search", "deliverables", "project folder",
                "subagent folder", "inherit folder", "choose folder",
            ],
            disambiguation: "The Orchestrator's folder. Custom agents set theirs in Agents → Abilities."
        ),
        .init(
            id: "settings.agents.delegation",
            tab: .delegation,
            section: "Subagents",
            title: "Subagents",
            keywords: [
                "spawn", "delegate", "delegation", "subagent", "subagents",
                "helper jobs", "agent delegation", "allowed agents",
                "allowed subagents", "main chat", "orchestrator",
                "parallel subagents", "child budgets", "spawn_agent",
            ],
            declarativeSection: "delegation"
        ),
        .init(
            id: "settings.agents.delegation.mainChat",
            tab: .delegation,
            section: "Subagents",
            title: "Allowed subagents",
            keywords: [
                "default agent", "built-in chat", "spawn pool", "main chat spawn",
                "allowed agents", "shared workspace agents", "workspace agents",
                "teammate agents", "auto-join", "remove agent",
            ],
            declarativeSection: "delegation"
        ),
        .init(
            id: "settings.agents.delegation.starterAgents",
            tab: .delegation,
            section: "Subagents",
            title: "Create starter agents",
            keywords: [
                "starter agents", "coder", "researcher", "writer", "create agents",
                "no agents yet", "first agents", "quick start",
            ]
        ),
        .init(
            id: "settings.agents.delegation.addAllAgents",
            tab: .delegation,
            section: "Subagents",
            title: "Add all agents",
            keywords: [
                "add all agents", "empty pool", "spawn pool empty", "no spawn_agent",
                "cannot delegate", "orchestrator cannot delegate", "re-add agents",
                "restore delegation", "agents not in list",
            ],
            disambiguation:
                "Shown only while the Orchestrator's allowed list is empty but agents exist; puts every existing agent back in the list so spawn_agent returns.",
            declarativeSection: "delegation"
        ),
        .init(
            id: "settings.agents.delegation.permission",
            tab: .delegation,
            section: "Subagents",
            title: "Permission",
            keywords: [
                "ask before delegating", "always allow", "approval card", "spawn permission",
                "local agents permission", "shared agents permission", "workspace permission",
                "permission for shared (workspace) agents", "deny delegation", "one approval per wave",
            ],
            disambiguation: "Whether to ask before subagents run. For every tool, see Chat → Auto-allow all tools.",
            declarativeSection: "delegation"
        ),
        .init(
            id: "settings.agents.delegation.limits",
            tab: .delegation,
            section: "Subagents",
            title: "Limits",
            keywords: [
                "max output tokens per subagent", "max turns per subagent",
                "time limit per subagent (seconds)", "max local subagents at once",
                "max remote subagents at once", "max parallel", "parallel subagents",
                "remote parallel", "budgets", "subagent limits", "agents end too fast",
                "delegation limits", "max delegate tokens", "elapsed seconds",
            ],
            declarativeSection: "delegation"
        ),
        .init(
            id: "settings.agents.delegation.advanced",
            tab: .delegation,
            section: "Subagents",
            title: "Advanced",
            keywords: [
                "agent-target model override", "model override", "subagent model",
                "run subagents on model", "override model", "advanced delegation",
            ],
            declarativeSection: "delegation"
        ),
        .init(
            id: "settings.agents.delegation.handoff",
            tab: .delegation,
            section: "Subagents",
            title: "Local Models & Memory",
            keywords: [
                "handoff", "swap local models", "swap", "ram safety", "memory check",
                "residency", "unload", "preflight", "coexistence", "keep chat model loaded",
                "check memory before delegating",
            ]
        ),
        .init(
            id: "settings.agents.delegation.swapModels",
            tab: .delegation,
            section: "Local Models & Memory",
            title: "Swap Local Models for Subagents",
            keywords: [
                "handoff", "browser use", "computer use", "applescript", "batch", "unload", "restore", "keep loaded",
                "coexistence",
            ],
            disambiguation:
                "Shared by all agents for text, Browser Use, Computer Use, AppleScript, local image jobs and context compaction. Off retains the invoking model during the job, including under Server Strict; memory admission and image cleanup remain separate.",
            declarativeSection: "delegation"
        ),
        .init(
            id: "settings.agents.delegation.ramSafety",
            tab: .delegation,
            section: "Local Models & Memory",
            title: "Check Memory Before Delegating",
            keywords: [
                "ram safety", "memory pressure", "stable_memory_refusal", "preflight", "subagent",
                "disable memory check",
            ],
            disambiguation:
                "One shared delegation RAM check for the Orchestrator and all agents. Separate from Server → Memory Safety load budgets.",
            declarativeSection: "delegation"
        ),
        .init(
            id: "settings.orchestrator.subagents",
            tab: .orchestrator,
            section: "Subagents",
            title: "Allowed Subagents and Limits",
            keywords: [
                "orchestrator subagents", "orchestrator delegation", "where are subagents",
                "subagents moved", "delegation settings",
            ],
            disambiguation:
                "A link to Agents → Delegation, where the Orchestrator's allowed subagents, permission, and limits are set."
        ),
        .init(
            id: "settings.orchestrator.delegations",
            tab: .orchestrator,
            section: "Delegations",
            title: "Delegations",
            keywords: [
                "delegation history", "sent", "received", "worker runs", "subagent runs",
                "open chat", "tok/s", "artifacts", "delegated tasks", "inbound runs",
                "shared agent runs",
            ]
        ),
        .init(
            id: "privacy.tab",
            tab: .privacy,
            title: "Privacy Filter",
            keywords: ["redaction", "filter", "scrub", "mask", "sensitive data", "custom rules", "pii"]
        ),
        .init(
            id: "privacy.filter.enabled",
            tab: .privacy,
            section: "Filter",
            title: "Scrub Personal Data Before Sending to Cloud Providers",
            keywords: ["privacy filter", "scrub", "redact", "pii", "cloud", "enable filter"],
            subTab: "overview"
        ),
        .init(
            id: "privacy.filter.aiDetection",
            tab: .privacy,
            section: "Filter",
            title: "AI Detection (On-Device Model)",
            keywords: ["ai detection", "on-device model", "names", "addresses", "secrets"],
            subTab: "overview"
        ),
        .init(
            id: "privacy.filter.skipCode",
            tab: .privacy,
            section: "Filter",
            title: "Skip Code Blocks",
            keywords: ["code blocks", "skip code", "fenced code", "inline code"],
            subTab: "overview"
        ),
        .init(
            id: "privacy.filter.alwaysApprove",
            tab: .privacy,
            section: "Filter",
            title: "Always Approve by Default",
            keywords: ["always approve", "review sheet", "skip review", "auto approve redaction"],
            subTab: "overview"
        ),
        .init(
            id: "privacy.filter.providers",
            tab: .privacy,
            section: "Per-Provider",
            title: "Per-Provider",
            keywords: ["per provider", "provider override", "filter per provider", "exempt provider"],
            subTab: "overview"
        ),
        .init(
            id: "privacy.filter.forget",
            tab: .privacy,
            section: "Conversation Privacy",
            title: "Forget Redactions in Every Conversation",
            keywords: ["forget redactions", "clear placeholders", "reset redactions"],
            subTab: "overview"
        ),
        .init(
            id: "privacy.filter.nonInteractive",
            tab: .privacy,
            section: "Advanced",
            title: "Require Review for Background Requests",
            keywords: [
                "non-interactive", "background requests", "http api review", "schedules review",
                "silent approve",
            ],
            subTab: "overview"
        ),
        .init(
            id: "privacy.activityLog.retention",
            tab: .privacy,
            section: "Activity Log",
            title: "Keep Activity History",
            keywords: [
                "activity log", "activity log retention", "audit log retention", "retention", "keep history",
                "how long", "insights retention", "delete old activity", "7 days", "30 days", "keep forever",
                "prune",
            ],
            subTab: "overview",
            disambiguation:
                "Privacy & Security → Activity Log. How many days of Insights activity (model requests, web searches, URL fetches, MCP calls, channel deliveries, Router calls) stay on disk before automatic pruning. Not Memory retention (Memory → Settings) and not File History (General → Advanced)."
        ),
        .init(
            id: "privacy.activityLog.storeContent",
            tab: .privacy,
            section: "Activity Log",
            title: "Store Prompts and Responses",
            keywords: [
                "activity log", "audit log", "store content", "store prompts", "log bodies", "metadata only",
                "prompt logging", "response logging", "wire payload", "insights content",
            ],
            subTab: "overview",
            disambiguation:
                "Privacy & Security → Activity Log. When off, new Insights records keep metadata (destination, bytes, tokens, timing) but replace prompt/response/tool bodies with a withheld marker. Not the Privacy Filter redaction switch."
        ),
        .init(
            id: "privacy.activityLog.openInsights",
            tab: .privacy,
            section: "Activity Log",
            title: "Review Activity in Insights",
            keywords: ["open insights", "review activity", "audit", "export log", "verify chain"],
            subTab: "overview"
        ),
        .init(
            id: "privacy.rules.detectionPatterns",
            tab: .privacy,
            section: "Rules",
            title: "Detection Patterns",
            keywords: [
                "detection patterns", "built-in patterns", "phone numbers", "international phone", "email addresses",
                "urls", "account numbers", "credit card", "luhn", "regex layer",
            ],
            subTab: "rules",
            disambiguation:
                "Privacy & Security → Detection Rules → Detection Patterns. Per-category switches for the built-in regex detectors (phone, email, URL, card numbers). National ID formats such as SSN, NINO or Aadhaar live under Preset Rules, not here."
        ),
        .init(
            id: "privacy.rules.regions",
            tab: .privacy,
            section: "Rules",
            title: "My Regions",
            keywords: [
                "my regions", "region", "country", "locale", "home region", "add region", "remove region",
                "detected region", "which country", "international", "country presets",
            ],
            subTab: "rules",
            disambiguation:
                "Privacy & Security → Detection Rules → My Regions. The countries whose ID / tax / health / bank number presets are on by default. Adding a region enables its presets; removing one never disables anything. Not the Preset Rules list itself and not the app language."
        ),
        .init(
            id: "privacy.rules.presets",
            tab: .privacy,
            section: "Rules",
            title: "Preset Rules",
            keywords: [
                "preset rules", "presets", "country", "national id", "passport", "ssn", "social security",
                "nino", "aadhaar", "iban", "tax id", "vat", "driver's licence", "health number", "bank account",
                "api key", "secret", "aws key", "github token", "enable all", "disable all", "ip address",
                "bitcoin", "ethereum",
            ],
            subTab: "rules",
            disambiguation:
                "Privacy & Security → Detection Rules → Preset Rules. Ready-made patterns grouped My Regions → Global → Other regions, each with Enable all / Disable all and a per-row switch. Not My Regions (which picks the countries) and not Custom Rules (which you write yourself)."
        ),
        .init(
            id: "privacy.rules.custom",
            tab: .privacy,
            section: "Rules",
            title: "Custom Rules",
            keywords: [
                "custom rules", "add rule", "regex", "pattern", "placeholder", "codename", "customer id",
                "rule builder", "my own pattern",
            ],
            subTab: "rules",
            disambiguation:
                "Privacy & Security → Detection Rules → Custom Rules. User-written patterns (regex or builder) with their own placeholder label. Not Preset Rules (ready-made, per country)."
        ),
        .init(
            id: "privacy.rules.test",
            tab: .privacy,
            section: "Rules",
            title: "Test Your Rules",
            keywords: [
                "test rules", "dry run", "preview redaction", "try sample", "what gets redacted", "tester",
            ],
            subTab: "rules"
        ),
        .init(
            id: "privacy.models",
            tab: .privacy,
            section: "Models",
            title: "Detection Models",
            keywords: ["privacy model", "pii model", "rampart", "install detection model", "on-device detector"],
            subTab: "model"
        ),

        // MARK: Identity / Storage / Memory
        .init(
            id: "identity.osaurusId",
            tab: .identity,
            title: "Public Profile",
            keywords: [
                "osaurus id", "public profile", "handle", "username", "profile", "display name", "bio", "claim",
                "public name",
            ]
        ),
        .init(
            id: "identity.keys",
            tab: .identity,
            title: "Master Address",
            keywords: [
                "mnemonic", "seed phrase", "recovery phrase", "agent keys", "signing",
                "cryptographic identity", "keys", "identity & recovery", "agent addresses",
            ],
            disambiguation: "The Osaurus ID's master address and recovery phrase, plus agent addresses. Not Sharing ▸ Devices ▸ Recovery Phrase, which restores synced chats (unless linked with Use My Osaurus Recovery Phrase)."
        ),
        .init(
            id: "identity.signInWithOsaurus",
            tab: .identity,
            title: "Sign In with Osaurus",
            keywords: [
                "log in with osaurus", "login with osaurus", "sign in", "sign-in", "recent sign-ins",
                "web login", "website login", "connected apps", "store.osaurus.ai", "touch id",
                "clear history",
            ],
            disambiguation:
                "Websites asking you to sign in with your identity. Not Access Keys (Server → Access Keys) and not Connections (Main window → Workflows), which are sign-ins Osaurus uses."
        ),
        .init(
            id: "workspaces.overview",
            tab: .workspaces,
            title: "Workspaces",
            keywords: [
                "workspace", "workspaces", "new workspace", "create workspace", "team", "teams",
                "collaboration", "share agents",
            ]
        ),
        .init(
            id: "workspaces.invites",
            tab: .workspaces,
            section: "Members",
            title: "Members",
            keywords: [
                "invite", "invite link", "invite links", "invites & members", "join", "join code", "member",
                "role", "admin", "owner", "viewer", "join workspace", "join team", "teammate",
            ],
            subTab: "members"
        ),
        .init(
            id: "workspaces.agents",
            tab: .workspaces,
            section: "Shared Agents",
            title: "Shared Agents",
            keywords: [
                "share agent", "shared agent", "remote access", "presence", "workspace billing", "team billing",
            ],
            subTab: "sharedAgents"
        ),
        .init(
            id: "workspaces.agents.billPool",
            tab: .workspaces,
            section: "Shared Agents",
            title: "Bill Workspace Credits",
            keywords: [
                "pool billing", "workspace pool", "bill the workspace pool", "workspace credits", "shared credits",
                "bill personal", "personal credits", "own balance", "who pays", "billing toggle", "team credits",
            ],
            subTab: "sharedAgents",
            disambiguation:
                "Per shared agent, shown only for agents hosted on this Mac, and in the Share Agent sheet when sharing. On by default; off bills your own chats with it to your personal balance. Teammates' runs always draw from workspace credits."
        ),
        .init(
            id: "workspaces.agents.askOwnerApproval",
            tab: .workspaces,
            section: "Shared Agents",
            title: "Require Approval for Teammate Tool Calls",
            keywords: [
                "ask me when teammates need approval", "owner approval", "approve teammate", "teammate tool approval", "shared agent approval",
                "ask owner", "approval flow", "approve from phone", "tool denied for teammate",
                "requires interactive approval",
            ],
            subTab: "sharedAgents",
            disambiguation: "Per shared agent hosted on this Mac. When a teammate, a guest or another person's agent hits a tool that needs approval, the run waits for you (inline card, desktop notification, the Inbox, or your iPhone) instead of failing; unanswered requests are declined after Decline Unanswered Requests After (10 minutes by default). Tools set to Deny, and tools never allowed for remote callers, stay blocked. Where the request reaches you is Settings → General → Notifications → Approvals.",
            declarativeSection: "agents"
        ),
        .init(
            id: "workspaces.agents.ownerApprovalTimeout",
            tab: .workspaces,
            section: "Shared Agents",
            title: "Decline Unanswered Requests After",
            keywords: [
                "approval timeout", "owner approval timeout", "approval wait", "how long to wait for approval",
                "teammate approval expires", "declined after", "timeout seconds",
            ],
            subTab: "sharedAgents",
            disambiguation: "Per shared agent hosted on this Mac, under Require Approval for Teammate Tool Calls (available once it is on): how long a teammate's tool call waits for you before it is declined (5 minutes to 24 hours, 10 minutes by default). Declaratively `agents[].shared_tool_approval.timeout_seconds` (30–86400).",
            declarativeSection: "agents"
        ),
        .init(
            id: "workspaces.agents.orchestratorAutoJoin",
            tab: .workspaces,
            section: "Shared Agents",
            title: "Let the Orchestrator delegate to shared agents",
            keywords: [
                "auto-join", "auto join", "workspace auto join", "orchestrator shared agents",
                "delegate to teammates", "shared agents pool", "stop joining", "workspace delegation",
            ],
            subTab: "sharedAgents",
            disambiguation: "Per-workspace switch. The list itself is Agents ▸ Orchestrator ▸ Allowed subagents.",
            declarativeSection: "delegation"
        ),
        .init(
            id: "workspaces.workflows",
            tab: .workspaces,
            section: "Workflows",
            title: "Workflows",
            keywords: [
                "workspace workflows", "team workflows", "shared workflows", "install teammate workflow",
                "workspace catalog", "workspace templates", "shared agent templates", "remove from workspace",
                "open in workflows",
            ],
            subTab: "workflows",
            disambiguation: "Workflows and agent templates members shared with this workspace (Share → Who can see it → Workspace). Any member, viewers included, can Install a copy that runs on their own Mac with their own keys; Update appears when a newer version is shared. The author, and the workspace's owners and admins, can remove a listing; installed copies keep working. A suspended workspace can't install. Open in Workflows shows the same list in the Workflows window's Workspaces tab. To let teammates run your workflow on your Mac instead, use Teammates can run this on the workflow and turn it on for the shared agent."
        ),
        .init(
            id: "workspaces.audit",
            tab: .workspaces,
            section: "Audit (this Mac)",
            title: "Audit (this Mac)",
            keywords: ["audit", "audit trail", "audit log", "who changed what", "history", "verify chain", "export audit"],
            subTab: "audit",
            disambiguation: "What this Mac recorded for one workspace. Other members' Macs keep their own logs."
        ),
        // The standalone Storage tab is gone. The models folder and models
        // already on this Mac live on Local Models → Sources; encryption,
        // backup and file history on Privacy & Security → Data & Storage.
        .init(
            id: "storage.externalModels",
            tab: .models,
            section: "Sources",
            title: "Use Models Already on This Mac",
            keywords: [
                "hugging face", "hf cache", "lm studio", "external", "import models", "external models",
                "models on this mac", "other apps", "model sources", "rescan",
            ]
        ),
        .init(
            id: "storage.location",
            tab: .models,
            section: "Sources",
            title: "Models Folder",
            keywords: [
                "disk", "data location", "models directory", "models folder", "move models", "cleanup",
                "models size", "download location",
            ]
        ),
        .init(
            id: "storage.encryption",
            tab: .privacy,
            section: "Data & Storage",
            title: "Encrypt Local Data at Rest",
            keywords: ["sqlcipher", "encryption", "filevault", "at rest", "storage key", "backup", "data & storage", "storage"],
            subTab: "storage"
        ),
        .init(
            id: "storage.fileHistory.retention",
            tab: .privacy,
            section: "Data & Storage",
            title: "Keep File History",
            keywords: [
                "file history retention", "undo history", "revert history", "file changes", "change history",
                "file snapshots", "keep changes", "delete old changes", "30 days", "90 days",
            ],
            subTab: "storage",
            disambiguation:
                "How long reverting agent file changes stays possible. Deleting a chat always deletes its file history."
        ),
        .init(
            id: "storage.fileHistory.sizeLimit",
            tab: .privacy,
            section: "Data & Storage",
            title: "File History Size Limit",
            keywords: [
                "file history size", "file history disk", "undo storage", "snapshot storage", "revert storage",
                "file changes disk usage",
            ],
            subTab: "storage"
        ),
        .init(
            id: "memory.settings",
            tab: .memory,
            title: "Memory",
            keywords: ["memories", "facts", "recall", "long term memory"],
            declarativeSection: "memory"
        ),
        .init(
            id: "memory.settings.enabled",
            tab: .memory,
            section: "Configuration",
            title: "Enable Memory",
            keywords: ["turn on memory", "disable memory", "memory switch"],
            subTab: "settings",
            declarativeSection: "memory"
        ),
        .init(
            id: "memory.settings.budget",
            tab: .memory,
            section: "Configuration",
            title: "Memory Budget",
            keywords: ["memory tokens", "injection", "memory budget"],
            subTab: "settings",
            disambiguation:
                "Tokens of long-term memory injected per turn — not the chat Context Window Cap.",
            declarativeSection: "memory"
        ),
        .init(
            id: "memory.settings.consolidation",
            tab: .memory,
            section: "Configuration",
            title: "Consolidation Interval",
            keywords: ["consolidation", "decay", "dedup", "eviction interval"],
            subTab: "settings"
        ),
        .init(
            id: "memory.settings.retention",
            tab: .memory,
            section: "Configuration",
            title: "Episode Retention",
            keywords: ["retention", "prune", "days", "history cleanup"],
            subTab: "settings"
        ),

        // MARK: Projects
        // Landing anchors live on `ProjectsView`: list rows land on the
        // list, field rows on the open project (or the first one).
        .init(
            id: "projects.overview",
            tab: .projects,
            title: "Projects",
            keywords: ["project", "group chats", "project settings", "manage projects"],
            disambiguation:
                "Settings → Projects groups chats around shared instructions, knowledge, memory and a working folder; they appear in the chat sidebar below Agents. Not Workspaces (sharing with teammates)."
        ),
        .init(
            id: "projects.new",
            tab: .projects,
            title: "New Project",
            keywords: ["create project", "add project"]
        ),
        .init(
            id: "projects.name",
            tab: .projects,
            section: "General",
            title: "Name",
            keywords: ["project name", "rename project"]
        ),
        .init(
            id: "projects.defaultAgent",
            tab: .projects,
            section: "General",
            title: "Default Agent",
            keywords: ["project agent", "project default agent"],
            disambiguation:
                "The agent New Chat in a project's sidebar group starts with. Not Model Defaults."
        ),
        .init(
            id: "projects.instructions",
            tab: .projects,
            title: "Instructions",
            keywords: ["project instructions", "project prompt", "shared instructions"],
            disambiguation:
                "Added after the agent's own System Prompt in every chat in the project. An agent's System Prompt is edited in Agents."
        ),
        .init(
            id: "projects.knowledge",
            tab: .projects,
            title: "Knowledge",
            keywords: ["project knowledge", "project collections"],
            disambiguation:
                "Collections granted to every chat in the project, on top of the agent's own grants. The collections themselves live in Knowledge."
        ),
        .init(
            id: "projects.workingFolder",
            tab: .projects,
            title: "Working Folder",
            keywords: ["project folder", "project working folder"],
            disambiguation:
                "Folder new chats in the project open in, in place of the agent's own Working Folder. The Orchestrator and each agent have their own."
        ),
        .init(
            id: "projects.sharedMemory",
            tab: .projects,
            title: "Shared Memory",
            keywords: ["project memory", "shared project memory", "open in memory"],
            disambiguation: "Opens the project's memory in Memory → Agents & Projects."
        ),
        .init(
            id: "projects.delete",
            tab: .projects,
            section: "Danger Zone",
            title: "Delete Project",
            keywords: ["remove project"]
        ),

        // MARK: Agents
        // Landing anchors live on the Agents screen (`AgentsView`): the header
        // glows for the overview entry; the agent grid glows for the database
        // entry, where each custom agent card exposes an Open Database
        // shortcut into that agent's Database workspace.
        .init(
            id: "agents.overview",
            tab: .agents,
            title: "Agents",
            keywords: [
                "agent", "assistant", "persona", "custom agent", "create agent", "new agent",
                "system prompt", "agent settings", "make an agent", "agent draft",
            ],
            disambiguation: "New agent in the Agents header opens the New Agent page right here: it asks what the agent should do, then the Configurator drafts it in a card beside its chat that fills in part by part. Every part has Edit, and only Create Agent saves it. An unfinished draft waits on the Agents list with Continue.",
            declarativeSection: "agents"
        ),
        .init(
            id: "agents.builtIn",
            tab: .agents,
            section: "Built-in",
            title: "Built-in agents",
            keywords: ["orchestrator", "architect", "default agent", "built in agents", "system agents"],
            disambiguation: "Orchestrator and Architect, pinned at the top of Agents."
        ),
        .init(
            id: "agents.templates",
            tab: .agents,
            title: "Templates",
            keywords: [
                "agent templates", "import agent template", "agent starter", "share agent", "osaurustemplate",
                "install agent link", "save as template", "export template", "import template", "add template",
            ],
            disambiguation: "Agents header → Templates. Add template (Import Template) takes a file, a paste, or an install link from store.osaurus.ai. Save as Template is in an agent card's … menu and the agent page's Share menu. Workflow templates live in Workflows."
        ),
        .init(
            id: "agents.templates.publish",
            tab: .agents,
            section: "Templates",
            title: "Publish Template",
            keywords: [
                "publish agent", "publish agent template", "share agent template", "share agent online",
                "agent template link", "agent page", "save as file", "live badge", "copy link", "open page",
                "publish version",
            ],
            disambiguation: "Agents → Templates → a template card's Share button → Publish to store.osaurus.ai (also Publish… in its … menu). Needs an Osaurus ID, which signs the template; bundled workflows go with it. Afterward the button reads Live with who can see it and installs, and Manage Published…, Copy Link, Open Page, Publish Version N… and Take Down… are in the … menu. Built-in templates show Export instead; Save to Library first to publish your copy. Workflows publish from Workflows."
        ),
        .init(
            id: "agents.templates.share",
            tab: .agents,
            section: "Templates",
            title: "Share",
            keywords: [
                "share agent template", "share template", "export", "export agent template", "save as a file",
                "two ways to share", "share button", "agent share sheet",
            ],
            disambiguation: "Share is the button on every template in your library. It offers two ways: Save as a file (.osaurustemplate) or Publish to store.osaurus.ai. Built-in templates show Export, which saves a file. Share in an agent's own header is different: it invites someone to use that running agent by a pairing link."
        ),
        .init(
            id: "agents.templates.publishedByYou",
            tab: .agents,
            section: "Templates",
            title: "Your author page",
            keywords: [
                "my published agents", "published agent templates", "agent author page", "agents published by you",
                "agent template installs total",
            ],
            disambiguation: "A quiet line above the Templates grid once an agent template is published: how many are published, total installs, and a link to your page on store.osaurus.ai. The Published chip narrows the grid to them. Workflows has its own line."
        ),
        .init(
            id: "agents.templates.filter",
            tab: .agents,
            section: "Templates",
            title: "Template filter",
            keywords: [
                "filter agent templates", "published templates", "built-in templates", "my templates",
                "yours", "yours chip", "template chips",
            ],
            disambiguation: "All, Published, Built-in and Yours chips above the Templates grid, each with a count. They appear once a template is published or more than eight are in the library."
        ),
        .init(
            id: "agents.templates.shareAfterSave",
            tab: .agents,
            section: "Save as Template",
            title: "Share…",
            keywords: [
                "share after save", "saved template share", "publish after saving template", "share new template",
            ],
            disambiguation: "After Save as Template, the sheet shows Saved with Share… and Done. Share… opens Templates with Share up for the template just saved."
        ),
        .init(
            id: "agents.templates.visibility",
            tab: .agents,
            section: "Templates",
            title: "Who can see it",
            keywords: [
                "agent template visibility", "unlisted agent", "password protected agent", "private agent template",
            ],
            disambiguation: "Chosen when publishing an agent template and changeable in its published dashboard (the Live badge or Manage Published…). Public is reviewed by the Osaurus team first: it starts unlisted (the link works right away) and is listed on store.osaurus.ai under Agents once approved. Unlisted opens only by link; Password asks for a password you set (6–128 characters); Workspace shows it only to members of the workspaces you pick. None of those is reviewed."
        ),
        .init(
            id: "agents.templates.workspaces",
            tab: .agents,
            section: "Templates",
            title: "Workspace",
            keywords: [
                "share agent with workspace", "share agent template with team", "team agent template",
                "workspace agent template", "members only agent",
            ],
            disambiguation: "A Who can see it option when publishing an agent template. Pick workspaces where you're an owner, admin or member. Members install their own copy of the agent from Workspaces → workspace → Workflows; it runs on their Mac. This is different from Shared Agents, where teammates talk to your running agent on your Mac."
        ),
        .init(
            id: "agents.templates.review",
            tab: .agents,
            section: "Templates",
            title: "Store Review",
            keywords: [
                "agent template review", "agent in review", "agent changes requested", "agent approved",
                "submit agent for review", "resubmit agent template", "agent unlisted until approved",
            ],
            disambiguation: "Public agent templates are reviewed by the Osaurus team before the store lists them; until then the link works but it isn't listed. The Store Review panel at the top of its published dashboard tracks the review and shows the reviewer's note when changes are requested. Change the agent, save it as a template with the same name, then Resubmit vN from the panel. Cards read In review or Changes requested, with a dot until you open the decision."
        ),
        .init(
            id: "agents.templates.listingDetails",
            tab: .agents,
            section: "Templates",
            title: "Listing Details",
            keywords: [
                "agent listing name", "agent listing description", "rename published agent", "edit agent listing",
                "agent page title",
            ],
            disambiguation: "In the publish step of an agent template and its published dashboard: the Name and Description its store page shows instead of the template's own. No new version is published and the template people install doesn't change; new versions keep it. Use Original goes back to the template's own name and summary. In the dashboard, Save Listing applies it."
        ),
        .init(
            id: "agents.templates.topics",
            tab: .agents,
            section: "Templates",
            title: "Topics",
            keywords: ["agent topics", "agent tags", "agent categories", "agent template topics"],
            disambiguation: "In the publish step of an agent template and its published dashboard: up to 3 topics people browse store.osaurus.ai by. Not part of the template file. In the dashboard, Save Listing applies them."
        ),
        .init(
            id: "agents.templates.exampleRuns",
            tab: .agents,
            section: "Templates",
            title: "Example Runs",
            keywords: [
                "agent examples", "example conversations", "sample conversations", "agent screenshots",
                "show agent results",
            ],
            disambiguation: "In the publish step of an agent template and its published dashboard: up to 6 conversations with an agent made from (or saved as) the template, each its first request, the reply, and the images it shared. Add Example Runs… picks them; each previews What leaves this Mac, and each image has Include. Secret values and local paths are left out and images lose their location and camera details. Nothing is shared until you confirm."
        ),
        .init(
            id: "agents.templates.publishedStats",
            tab: .agents,
            section: "Templates",
            title: "Installs",
            keywords: [
                "agent template installs", "agent installs", "published agent", "manage published agent",
            ],
            disambiguation: "The published dashboard for an agent template, from its Live badge or Manage Published… in the card's … menu: installs, versions, live since and updated."
        ),
        .init(
            id: "agents.templates.takeDown",
            tab: .agents,
            section: "Templates",
            title: "Take Down",
            keywords: [
                "take down agent", "unpublish agent", "unpublish agent template", "remove agent from registry",
            ],
            disambiguation: "Take Down… is in a published agent template's … menu and at the bottom of its dashboard. The page stops working; people who added it keep their copy. Publish Again brings it back at the same link."
        ),
        .init(
            id: "agents.templates.publishWorkflows",
            tab: .agents,
            section: "Templates",
            title: "Also publishes",
            keywords: [
                "give my workflows their own pages", "publish agent workflows", "publish bundled workflows",
                "cascading share", "agent workflow pages", "link agent to workflow",
            ],
            disambiguation: "In the publish step of an agent template, under Also publishes: each workflow it bundles and what publishing does for it. Give my workflows their own pages (on by default) publishes the ones that are yours and not live yet first, with the agent's visibility (Public or Unlisted; a password-protected agent keeps them bundled only), so the agent's page links to each. Someone else's workflow is never republished; the agent's page links to the original author's page when it carries that exact version."
        ),
        .init(
            id: "agents.templates.visibilityWorkflows",
            tab: .agents,
            section: "Templates",
            title: "Also change its workflows",
            keywords: [
                "agent workflow visibility", "make agent workflows unlisted", "make agent workflows public",
                "change visibility of bundled workflows", "workflow pages follow agent",
            ],
            disambiguation: "In a published agent template's dashboard, under Who can see it, after you pick a new visibility: on by default, Save also moves the workflow pages published with the agent to the same Public or Unlisted, so its page keeps linking to them. Workflow pages you protected with their own password, taken-down ones, and every one when the agent becomes password-protected stay as they are; change a single workflow in its own dashboard."
        ),
        .init(
            id: "agents.templates.bundledPages",
            tab: .agents,
            section: "Templates",
            title: "Workflows it brings",
            keywords: [
                "agent workflow pages", "bundled workflow page", "take down agent workflow",
                "workflows in published agent", "used by agents",
            ],
            disambiguation: "In a published agent template's dashboard: each workflow it bundles, whether it has its own page and whether the agent's page links to it, with Open Page and Take Down… for each. Taking the agent down leaves these pages up. A workflow's own dashboard says when its page came with an agent."
        ),
        .init(
            id: "agents.configure",
            tab: .agents,
            title: "Configure Agent",
            keywords: [
                "per-agent", "capabilities", "max tokens", "temperature",
                "advanced", "agent model", "configure",
            ],
            disambiguation:
                "Per-agent Advanced generation and capability toggles. Orchestrator defaults live under Orchestrator → Generation.",
            declarativeSection: "agents"
        ),
        .init(
            id: "agents.showResponseMetrics",
            tab: .agents,
            section: "Advanced Settings",
            title: "Show Response Metrics",
            keywords: ["tokenizer", "token count", "tokens per second", "tok/s", "response statistics", "agent display"],
            disambiguation: "Custom agent → General → Configure → Advanced Settings. Shows existing measured response statistics in that agent's chats.",
            declarativeSection: "agents"
        ),
        .init(
            id: "agents.followUpSuggestions",
            tab: .agents,
            section: "Follow-Up Suggestions",
            title: "Show Follow-Up Suggestions",
            keywords: [
                "agent follow up", "agent followups", "per-agent suggestions", "suggested replies",
                "follow-up model", "hide follow ups",
            ],
            disambiguation: "Custom agent → General → Configure → Follow-Up Suggestions. On by default; off hides the suggested next questions under that agent's replies. Only narrows Settings → Chat → Suggest Follow-Up Questions, which turns the feature on for every agent. The Architect never shows them, and no agent shows them while it waits on its own question or form. While on, the model picker beneath it chooses the model that writes them (default: the shared Core Model). Declarative key: `follow_up_suggestions` on agents[].",
            declarativeSection: "agents"
        ),
        .init(
            id: "agents.generation.temperature",
            tab: .agents,
            section: "Generation Overrides",
            title: "Temperature",
            keywords: ["agent temperature", "per-agent generation", "agent defaults", "DiffusionGemma", "inactive sampling"],
            disambiguation: "Custom agent → General → Configure → Advanced Settings → Generation Overrides. Inherit preserves existing defaults; reasoning choices depend on the selected model. For native DiffusionGemma, this override stays visible but inactive; saved values remain available for other models.",
            declarativeSection: "agents"
        ),
        .init(
            id: "agents.generation.maxTokens",
            tab: .agents,
            section: "Generation Overrides",
            title: "Max Tokens",
            keywords: ["agent max tokens", "per-agent generation", "agent defaults"],
            disambiguation: "Custom agent → General → Configure → Advanced Settings → Generation Overrides. Inherit preserves existing defaults; reasoning choices depend on the selected model.",
            declarativeSection: "agents"
        ),
        .init(
            id: "agents.generation.topP",
            tab: .agents,
            section: "Generation Overrides",
            title: "Top P",
            keywords: ["agent top p", "per-agent generation", "agent defaults", "DiffusionGemma", "inactive sampling"],
            disambiguation: "Custom agent → General → Configure → Advanced Settings → Generation Overrides. Inherit preserves existing defaults; reasoning choices depend on the selected model. For native DiffusionGemma, this override stays visible but inactive; saved values remain available for other models.",
            declarativeSection: "agents"
        ),
        .init(
            id: "agents.generation.topK",
            tab: .agents,
            section: "Generation Overrides",
            title: "Top K",
            keywords: ["agent top k", "per-agent generation", "agent defaults", "DiffusionGemma", "inactive sampling"],
            disambiguation: "Custom agent → General → Configure → Advanced Settings → Generation Overrides. Inherit preserves existing defaults; reasoning choices depend on the selected model. For native DiffusionGemma, this override stays visible but inactive; saved values remain available for other models.",
            declarativeSection: "agents"
        ),
        .init(
            id: "agents.generation.minP",
            tab: .agents,
            section: "Generation Overrides",
            title: "Min P",
            keywords: ["agent min p", "per-agent generation", "agent defaults", "DiffusionGemma", "inactive sampling"],
            disambiguation: "Custom agent → General → Configure → Advanced Settings → Generation Overrides. Inherit preserves existing defaults; reasoning choices depend on the selected model. For native DiffusionGemma, this override stays visible but inactive; saved values remain available for other models.",
            declarativeSection: "agents"
        ),
        .init(
            id: "agents.generation.repetitionPenalty",
            tab: .agents,
            section: "Generation Overrides",
            title: "Repetition penalty",
            keywords: ["agent repetition penalty", "per-agent generation", "agent defaults", "DiffusionGemma", "inactive sampling"],
            disambiguation: "Custom agent → General → Configure → Advanced Settings → Generation Overrides. Inherit preserves existing defaults; reasoning choices depend on the selected model. For native DiffusionGemma, this override stays visible but inactive; saved values remain available for other models.",
            declarativeSection: "agents"
        ),
        .init(
            id: "agents.generation.frequencyPenalty",
            tab: .agents,
            section: "Generation Overrides",
            title: "Frequency penalty",
            keywords: ["agent frequency penalty", "per-agent generation", "agent defaults", "DiffusionGemma", "inactive sampling"],
            disambiguation: "Custom agent → General → Configure → Advanced Settings → Generation Overrides. Inherit preserves existing defaults; reasoning choices depend on the selected model. For native DiffusionGemma, this override stays visible but inactive; saved values remain available for other models.",
            declarativeSection: "agents"
        ),
        .init(
            id: "agents.generation.presencePenalty",
            tab: .agents,
            section: "Generation Overrides",
            title: "Presence penalty",
            keywords: ["agent presence penalty", "per-agent generation", "agent defaults", "DiffusionGemma", "inactive sampling"],
            disambiguation: "Custom agent → General → Configure → Advanced Settings → Generation Overrides. Inherit preserves existing defaults; reasoning choices depend on the selected model. For native DiffusionGemma, this override stays visible but inactive; saved values remain available for other models.",
            declarativeSection: "agents"
        ),
        .init(
            id: "agents.generation.seed",
            tab: .agents,
            section: "Generation Overrides",
            title: "Seed",
            keywords: ["agent seed", "per-agent generation", "agent defaults"],
            disambiguation: "Custom agent → General → Configure → Advanced Settings → Generation Overrides. Inherit preserves existing defaults; reasoning choices depend on the selected model.",
            declarativeSection: "agents"
        ),
        .init(
            id: "agents.generation.stop",
            tab: .agents,
            section: "Generation Overrides",
            title: "Stop sequences",
            keywords: ["agent stop sequences (json array)", "per-agent generation", "agent defaults", "custom stop strings", "stop chips", "empty array"],
            disambiguation: "Custom agent → General → Configure → Advanced Settings → Generation Overrides. Inherit preserves existing defaults; reasoning choices depend on the selected model.",
            declarativeSection: "agents"
        ),
        .init(
            id: "agents.generation.thinking",
            tab: .agents,
            section: "Generation Overrides",
            title: "Thinking",
            keywords: ["agent thinking", "per-agent generation", "agent defaults"],
            disambiguation: "Custom agent → General → Configure → Advanced Settings → Generation Overrides. Inherit preserves existing defaults; reasoning choices depend on the selected model.",
            declarativeSection: "agents"
        ),
        .init(
            id: "agents.generation.reasoningEffort",
            tab: .agents,
            section: "Generation Overrides",
            title: "Reasoning effort",
            keywords: ["agent reasoning effort", "per-agent generation", "agent defaults"],
            disambiguation: "Custom agent → General → Configure → Advanced Settings → Generation Overrides. Inherit preserves existing defaults; reasoning choices depend on the selected model.",
            declarativeSection: "agents"
        ),
        .init(
            id: "agents.generation.speculativeDecoding",
            tab: .agents,
            section: "Generation Overrides",
            title: "Speculative Decoding",
            keywords: ["agent native mtp", "adaptive on off ar", "dspark", "dflash", "drafter", "per-agent speculation"],
            disambiguation: "Custom agent → General → Configure → Advanced Settings → Generation Overrides. Eligible local bundles only. Inherit uses Server settings; Off uses AR; On requests adaptive drafting for this agent without changing shared defaults.",
            declarativeSection: "agents"
        ),
        .init(
            id: "agents.generation.templateKwargs",
            tab: .agents,
            section: "Generation Overrides",
            title: "Template parameters (JSON)",
            keywords: ["agent template parameters (json)", "per-agent generation", "agent defaults", "custom template variables", "advanced chat template parameters", "empty object"],
            disambiguation: "Custom agent → General → Configure → Advanced Settings → Generation Overrides. Inherit preserves existing defaults; reasoning choices depend on the selected model.",
            declarativeSection: "agents"
        ),
        .init(
            id: "agents.description",
            tab: .agents,
            title: "Brief description (optional)",
            keywords: ["agent description", "purpose", "routing", "delegation", "auto-generated description", "generated description"],
            disambiguation: "Optional one-line summary shown to the orchestrator when it chooses a delegation target. Left blank, Osaurus generates one in the background from the agent's system prompt; typing your own overrides it.",
            declarativeSection: "agents"
        ),
        .init(
            id: "agents.runtime",
            tab: .agents,
            section: "Runtime",
            title: "Runs on",
            keywords: [
                "runtime", "agent runtime", "harness", "external harness", "claude code", "pi", "pi rpc",
                "built-in loop", "osaurus built-in", "run agent on claude code", "spotlight", "splash",
                "manage runtimes", "switch runtime", "switch to claude code", "model picker runtime",
            ],
            disambiguation:
                "Per-agent choice between Osaurus's own loop and a registered harness (Configure tab → Runtime). The chat model picker lists the same runtimes as columns; picking one there changes this setting. Register or test harnesses under Settings → Agent Runtimes. Declarative key: `runtime` (\"builtin\" or a harness_runtimes name) on agents[] and default_agent.",
            declarativeSection: "agents"
        ),
        .init(
            id: "agents.claudeCode.model",
            tab: .agents,
            section: "Claude Code Options",
            title: "Claude model",
            keywords: ["claude code model", "sonnet", "opus", "fable", "haiku", "model alias"],
            disambiguation:
                "Shown only when the agent's runtime is Claude Code. The Claude Code column of the chat model picker sets the same value. Declarative key: `claude_code.model`.",
            declarativeSection: "agents"
        ),
        .init(
            id: "agents.claudeCode.effort",
            tab: .agents,
            section: "Claude Code Options",
            title: "Claude effort",
            keywords: [
                "claude code effort", "effort", "thinking effort", "reasoning effort", "thinking level",
                "extra high", "xhigh", "max effort", "--effort",
            ],
            disambiguation:
                "Shown only when the agent's runtime is Claude Code. Passed to the CLI as `--effort`; Default leaves Claude Code on its own per-model default. Not the chat composer's reasoning control for built-in-loop models. Declarative key: `claude_code.effort`.",
            declarativeSection: "agents"
        ),
        .init(
            id: "agents.claudeCode",
            tab: .agents,
            section: "Claude Code Options",
            title: "Allow file changes",
            keywords: [
                "execution mode", "text only", "allow shell commands", "bash", "allow osaurus read tools",
                "allow osaurus configuration changes", "claude code permissions", "claude code tools", "mcp bridge",
            ],
            disambiguation:
                "Claude Code permission switches on an agent whose runtime is Claude Code. File changes are scoped to the chat folder; shell commands can't be confined. Declarative block: `claude_code` on agents[] and default_agent.",
            declarativeSection: "agents"
        ),
        // MARK: Agent Runtimes
        .init(
            id: "agentRuntimes.overview",
            tab: .agentRuntimes,
            title: "Agent Runtimes",
            keywords: [
                "runtimes", "harness", "harnesses", "external agent", "claude code", "pi", "pi rpc", "rpc mode",
                "spotlight", "splash", "agent backend", "pluggable", "harness_runtimes",
            ],
            declarativeSection: "harness_runtimes"
        ),
        .init(
            id: "agentRuntimes.add",
            tab: .agentRuntimes,
            title: "Add Runtime",
            keywords: [
                "new runtime", "register harness", "executable", "arguments", "environment", "protocol",
                "session id", "chat id placeholder", "system prompt file",
            ],
            declarativeSection: "harness_runtimes"
        ),
        .init(
            id: "agentRuntimes.list",
            tab: .agentRuntimes,
            title: "Test",
            keywords: [
                "test runtime", "check harness", "get_state", "sign in", "claude code sign in", "claude login",
                "edit runtime", "delete runtime",
            ],
            disambiguation: "Per-runtime Test, Sign In (Claude Code), Edit, and Delete buttons in Settings → Agent Runtimes.",
            declarativeSection: "harness_runtimes"
        ),
        .init(
            id: "agentRuntimes.safety",
            tab: .agentRuntimes,
            title: "Runs with your account's access",
            keywords: ["how runtimes work", "harness permissions", "confine", "harness sandbox", "harness folder", "osaurus_agent_token"]
        ),
        .init(
            id: "agents.database",
            tab: .agents,
            section: "Knowledge",
            title: "Agent Database",
            keywords: [
                "database", "tables", "rows", "saved views", "sql", "sqlite",
                "agent data", "structured data", "encrypted database", "db",
            ]
        ),
        // Agents → (custom agent) → Abilities → Tools. The built-in Apple
        // apps are groups in the tool picker (one per app, toggled per app);
        // the anchor sits on the picker. Also writable via
        // `capabilities.apple_apps`.
        .init(
            id: "agents.appleApps",
            tab: .agents,
            section: "Abilities → Tools",
            title: "Apple Apps",
            keywords: [
                "apple apps", "apple", "native apps", "mac apps", "built-in apps", "apple tools",
                "calendar", "reminders", "contacts", "notes", "mail", "messages", "imessage",
                "maps", "location", "music", "shortcuts", "apple_apps",
            ],
            subTab: "capabilities",
            disambiguation:
                "Per-custom-agent groups in Abilities → Tools for the built-in Apple app tools (off by default, toggled per app). The Orchestrator never uses them directly; it enables them on a custom agent via osaurus_config capabilities.apple_apps.",
            declarativeSection: "agents"
        ),
        // Agents → (custom agent) → Abilities: the Workflows section, one
        // switch per installed workflow. Also writable via agents[].workflows.
        .init(
            id: "agents.workflows",
            tab: .agents,
            section: "Abilities",
            title: "Workflows",
            keywords: [
                "agent workflows", "workflow tools", "call a workflow", "enable workflow",
                "workflow_", "workflow tool", "workspace workflow", "runs on their mac", "teammate workflow",
            ],
            subTab: "abilities",
            disambiguation:
                "Which installed workflows this custom agent can call as tools, plus workflows added from a workspace that run on a teammate's Mac (Runs on X's Mac). Installing, adding and setting up workflows lives in Main window → Workflows.",
            declarativeSection: "agents"
        ),

        // Agents → (custom agent) → Sandbox → Execution: the per-agent
        // sandbox switches. Also writable via agents[].sandbox.
        .init(
            id: "agents.sandbox.autonomousExecution",
            tab: .agents,
            section: "Execution",
            title: "Autonomous Execution",
            keywords: ["run commands", "shell access", "code execution", "agent sandbox"],
            subTab: "sandbox",
            disambiguation: "Per custom agent: lets it run commands in its own sandbox container. Declarative key: `agents[].sandbox.enabled`.",
            declarativeSection: "agents"
        ),
        .init(
            id: "agents.sandbox.pluginCreation",
            tab: .agents,
            section: "Execution",
            title: "Plugin Creation",
            keywords: ["create plugins", "agent tools", "make its own tools"],
            subTab: "sandbox",
            disambiguation: "Per custom agent, with Autonomous Execution on: lets it create its own tools as sandbox plugins. Declarative key: `agents[].sandbox.plugin_create`.",
            declarativeSection: "agents"
        ),
        .init(
            id: "agents.sandbox.network",
            tab: .agents,
            section: "Execution",
            title: "Sandbox Network",
            keywords: ["agent internet", "agent network", "outbound network", "egress"],
            subTab: "sandbox",
            disambiguation: "Per custom agent: whether its sandbox commands reach the internet. Applies to this agent only. Developer Tools → Sandbox → Network only shows the result. Declarative key: `agents[].sandbox.network_enabled`.",
            declarativeSection: "agents"
        ),
        .init(
            id: "agents.sandbox.allowedDomains",
            tab: .agents,
            section: "Execution",
            title: "Allowed Domains",
            keywords: ["domain allowlist", "egress allowlist", "allowed hosts", "restrict network"],
            subTab: "sandbox",
            disambiguation: "Per custom agent, VM sandbox only: limits its sandbox web traffic to these domains plus its plugins' domains; SSH and other connections are blocked. Empty means unrestricted. Declarative key: `agents[].sandbox.allowed_domains`.",
            declarativeSection: "agents"
        ),
        .init(
            id: "agents.sandbox.backgroundProcesses",
            tab: .agents,
            section: "Execution",
            title: "Background Processes",
            keywords: ["long running processes", "servers", "watchers", "detached processes"],
            subTab: "sandbox",
            disambiguation: "Per custom agent: lets it start and manage long-lived processes in its sandbox. Declarative key: `agents[].sandbox.background_process_enabled`.",
            declarativeSection: "agents"
        ),
        .init(
            id: "agents.sandbox.hostServices",
            tab: .agents,
            section: "Execution",
            title: "Code Can Use Osaurus",
            keywords: [
                "osaurus-host inference", "host inference", "agent dispatch", "sandbox inference",
                "plugin inference", "host bridge", "osaurus-host plugin create",
            ],
            subTab: "sandbox",
            disambiguation: "Per custom agent, off by default: lets commands and plugins in its sandbox run model completions, start agent tasks, and register plugins through the host bridge. Not Plugin Creation, and not the plugin manifest's `permissions.inference`, which the bridge does not trust."
        ),
        .init(
            id: "agents.sandbox.workspaceFolder",
            tab: .agents,
            section: "Sandbox",
            title: "Workspace Folder",
            keywords: ["agent sandbox home", "agent files", "open agent workspace"],
            subTab: "sandbox",
            disambiguation: "Per custom agent → Sandbox: Open in Finder for this agent's sandbox home folder. Not the agent's Working Folder (a folder on the Mac)."
        ),

        // Agents → (custom agent) → Channels: read-only list of the channels
        // the agent is on, each with Edit in Channels.
        .init(
            id: "agents.channels.onChannels",
            tab: .agents,
            section: "Channels",
            title: "On Channels",
            keywords: [
                "agent channels", "replies", "where it can post", "answers on", "agent slack", "agent discord",
                "agent telegram", "agent imessage", "agent whatsapp", "edit in channels", "posting places",
            ],
            subTab: "channels",
            disambiguation:
                "Shows which channels this agent answers on and where it may post, in words. Nothing is edited here: use Edit in Channels, which opens that channel's sheet at Routing (who answers) and Sending (who posts on its own).",
            declarativeSection: "automations"
        ),

        // Agents → (custom agent) → Abilities → Tools: the per-agent skill
        // allow-list card above the picker. Also writable via
        // `agents[].skills`.
        .init(
            id: "agents.skills",
            tab: .agents,
            section: "Abilities → Tools",
            title: "Limit to selected skills",
            keywords: [
                "skills", "skill allow-list", "allowed skills", "allow list", "allowlist",
                "restrict skills", "choose skills", "agent skills", "skill access",
            ],
            subTab: "capabilities",
            disambiguation:
                "Per-custom-agent switch in Abilities → Tools. Off: the agent sees every installed skill. On: only the ticked skills appear in its prompt, capabilities_load and slash commands. Installing skill content is Skills in the sidebar, not this card. Declarative: agents[].skills (omit = unchanged, null = all skills, list = only these).",
            declarativeSection: "agents"
        ),

        // Agents → (custom agent) → Abilities → Overview: optional built-in
        // tool cards. Also writable via `capabilities.*_enabled`.
        .init(
            id: "agents.calculator",
            tab: .agents,
            section: "Abilities → Overview",
            title: "Calculator",
            keywords: [
                "calculator", "calculate", "math", "arithmetic", "numbers", "sum", "totals",
                "percentages", "finance", "budget", "invoices", "accounting", "unit conversion",
                "calculator_enabled",
            ],
            subTab: "abilities",
            disambiguation:
                "Per-custom-agent card, off by default. On: the agent gets the `calculate` tool for exact arithmetic. Turn it on for finance, budgeting, invoicing, or data-analysis agents. Declarative: capabilities.calculator_enabled.",
            declarativeSection: "agents"
        ),
        .init(
            id: "agents.redactionTools",
            tab: .agents,
            section: "Abilities → Overview",
            title: "Redaction Tools",
            keywords: [
                "redaction", "redact", "pii", "personal data", "anonymize", "mask", "scrub",
                "privacy", "detect_pii", "redact_file", "redaction_tools_enabled",
            ],
            subTab: "abilities",
            disambiguation:
                "Per-custom-agent card, off by default. On: in chats with a working folder the agent gets detect_pii and redact_file to find and mask personal data in files. Not the Privacy filter (Privacy in the sidebar), which screens what leaves for cloud models. Declarative: capabilities.redaction_tools_enabled.",
            declarativeSection: "agents"
        ),
        .init(
            id: "agents.taskChecklist",
            tab: .agents,
            section: "Abilities → Overview",
            title: "Task Checklist",
            keywords: [
                "todo", "checklist", "task list", "plan", "progress", "complete", "steps",
                "task_checklist_enabled",
            ],
            subTab: "abilities",
            disambiguation:
                "Per-custom-agent card, on by default. On: the agent can keep a todo checklist for multi-step work and close a blocked task with complete. Declarative: capabilities.task_checklist_enabled.",
            declarativeSection: "agents"
        ),
        .init(
            id: "agents.clarify",
            tab: .agents,
            section: "Abilities → Overview",
            title: "Clarifying Questions",
            keywords: [
                "clarify", "ask questions", "clarification", "ambiguous", "ask user", "clarify_enabled",
            ],
            subTab: "abilities",
            disambiguation:
                "Per-custom-agent card, on by default. On: the agent can pause a task to ask you a question. Delegated runs never ask regardless. Declarative: capabilities.clarify_enabled.",
            declarativeSection: "agents"
        ),
        .init(
            id: "agents.workingFolderReadOnly",
            tab: .agents,
            section: "Abilities → Overview → Working Folder",
            title: "Read Only",
            keywords: [
                "read only", "read-only", "readonly", "working folder read only", "no writes",
                "write protect", "protect folder", "can't edit files", "working_folder_read_only",
            ],
            subTab: "abilities",
            disambiguation:
                "Per-custom-agent switch under Working Folder, off by default. On: the agent can read and search its working folder, and file_write, file_edit, file_copy, shell_run, git_commit, file_undo, and redact_file are removed and refused, including in workflow steps that run as the agent. Not a macOS permission. Declarative: agents[].working_folder_read_only.",
            declarativeSection: "agents"
        ),
        .init(
            id: "agents.artifacts",
            tab: .agents,
            section: "Abilities → Overview",
            title: "Share Artifacts",
            keywords: [
                "artifacts", "share artifact", "share_artifact", "file cards", "deliverables",
                "attachments", "artifacts_enabled",
            ],
            subTab: "abilities",
            disambiguation:
                "Per-custom-agent card, on by default. On: the agent can post finished files, images, and reports as cards in the chat. Files it writes still land in the working folder either way. Declarative: capabilities.artifacts_enabled.",
            declarativeSection: "agents"
        ),

        // MARK: Search
        .init(
            id: "search.providers",
            tab: .search,
            title: "Search Providers",
            keywords: [
                "web search", "search engine", "tavily", "exa", "brave", "serper", "parallel",
                "google", "kagi", "duckduckgo", "bing", "api key", "internet",
            ]
        ),
        .init(
            id: "search.premium",
            tab: .search,
            title: "Premium Search",
            keywords: [
                "premium search", "hosted search", "osaurus search", "router search",
                "paid search", "web search credits",
            ]
        ),
        .init(
            id: "credits.router",
            tab: .credits,
            section: "Osaurus Router",
            title: "Use Osaurus Router",
            keywords: [
                "osaurus router", "router", "turn off router", "run fully local", "offline mode",
                "cloud models", "routed services",
            ],
            disambiguation:
                "Master switch for Osaurus-routed services. Off hides cloud models routed through Osaurus and every wallet card. Osaurus ID needs it on."
        ),
        .init(
            id: "credits.webSearch",
            tab: .credits,
            section: "Web Search",
            title: "Search Credits",
            keywords: [
                "web search", "premium search", "free searches", "search credits",
                "auto pay", "search billing", "page extract", "grant",
            ]
        ),
        .init(
            id: "search.tryIt",
            tab: .search,
            title: "Test Search",
            keywords: ["test query", "search playground", "try search"]
        ),
        .init(
            id: "search.routing",
            tab: .search,
            title: "Category Preferences",
            keywords: [
                "per-category provider order", "try first", "fallback", "ranking", "routing", "news",
                "images", "priority",
            ]
        ),
        .init(
            id: "search.custom",
            tab: .search,
            section: "Custom Providers",
            title: "Add Custom Provider",
            keywords: [
                "custom search provider", "custom api", "json definition", "searxng", "perplexity",
                "self-hosted",
            ],
            declarativeSection: "search_providers"
        ),

        // MARK: Tab-level rows for Management areas that had zero search hits
        .init(
            id: "models.automaticUpdates",
            tab: .modelDefaults,
            section: "Downloads & Updates",
            title: "Automatically Check Model Updates",
            keywords: ["background model updates", "huggingface", "model revision", "automatic checks", "offline"],
            disambiguation: "Checks installed OsaurusAI model metadata only. Does not update the Osaurus application or download model files."
        ),
        .init(
            id: "models.overview",
            tab: .models,
            title: "Local Models",
            keywords: ["install model", "download model", "mlx", "huggingface", "catalog", "add model", "import model"],
            disambiguation: "Local Models header → Add model imports a model from Hugging Face.",
            declarativeSection: "models"
        ),
        .init(
            id: "models.kind",
            tab: .models,
            title: "Model kind",
            keywords: [
                "language models", "image models", "speech models", "privacy detection models",
                "applescript models", "on device", "catalog", "whisper", "parakeet", "ideogram",
            ],
            disambiguation: "Switches Local Models between Language, Image, Speech, Privacy Detection and AppleScript models."
        ),

        // MARK: Model Defaults (which model Osaurus uses for each kind of job)
        .init(
            id: "modelDefaults.overview",
            tab: .modelDefaults,
            title: "Model Defaults",
            keywords: [
                "default model", "default models", "which model", "model for", "fallback model",
                "background model", "model roles",
            ],
            disambiguation: "One page for every \"which model is used for X\" choice. Agents can override these per agent."
        ),
        .init(
            id: "modelDefaults.imageGeneration",
            tab: .modelDefaults,
            section: "Images & Video",
            title: "Image Generation Model",
            keywords: ["default image model", "text to image", "generate image", "ideogram", "mflux"]
        ),
        .init(
            id: "modelDefaults.imageEdit",
            tab: .modelDefaults,
            section: "Images & Video",
            title: "Edit Model",
            keywords: ["image edit model", "edit image", "qwen image edit", "inpaint"]
        ),
        .init(
            id: "modelDefaults.textToVideo",
            tab: .modelDefaults,
            section: "Images & Video",
            title: "Text-to-Video Model",
            keywords: ["video model", "text to video", "venice", "video generation"]
        ),
        .init(
            id: "modelDefaults.imageToVideo",
            tab: .modelDefaults,
            section: "Images & Video",
            title: "Image-to-Video Model",
            keywords: ["video model", "image to video", "animate image"]
        ),
        .init(
            id: "modelDefaults.speech",
            tab: .modelDefaults,
            section: "Speech",
            title: "Speech-to-Text Model",
            keywords: ["transcription model", "dictation model", "whisper", "parakeet", "default speech model"]
        ),
        .init(
            id: "modelDefaults.detection",
            tab: .modelDefaults,
            section: "Privacy Detection",
            title: "Detection Model",
            keywords: ["privacy model", "pii model", "rampart", "redaction model", "ai detection"]
        ),
        .init(
            id: "modelDefaults.appleScript",
            tab: .modelDefaults,
            section: "AppleScript",
            title: "AppleScript Model",
            keywords: ["applescript model", "scripting model", "osascript", "automation model"]
        ),
        .init(
            id: "modelDefaults.appleScriptResidency",
            tab: .modelDefaults,
            section: "AppleScript",
            title: "AppleScript Model Residency",
            keywords: ["applescript load policy", "keep loaded", "unload applescript", "residency"]
        ),
        .init(
            id: "providers.overview",
            tab: .providers,
            title: "Providers",
            keywords: ["cloud models", "provider", "api key", "openai", "anthropic", "openrouter", "xai"],
            declarativeSection: "providers"
        ),
        .init(
            id: "knowledge.overview",
            tab: .knowledge,
            title: "Knowledge",
            keywords: ["collections", "documents", "rag", "index files"],
            declarativeSection: "knowledge_collections"
        ),
        .init(
            id: "tools.overview",
            tab: .tools,
            title: "Tools & MCP",
            keywords: [
                "tool catalog", "enable tools", "ask deny", "auto ask deny",
                "mcp", "plugins", "tool policy", "tools",
            ],
            disambiguation:
                "Global tool enablement and Auto/Ask/Deny. Not macOS Permissions.",
            declarativeSection: "tools"
        ),
        .init(
            id: "tools.services",
            tab: .tools,
            section: "Services",
            title: "Services",
            keywords: [
                "mcp services", "mcp servers", "connections", "connected services", "remote tools",
                "mcp",
            ],
            subTab: "Services",
            declarativeSection: "mcp_servers"
        ),
        .init(
            id: "tools.addService",
            tab: .tools,
            section: "Services",
            title: "Add Service",
            keywords: ["add mcp", "add connection", "add provider", "connect service", "new mcp server"],
            subTab: "Services"
        ),
        .init(
            id: "tools.directory",
            tab: .tools,
            section: "Services",
            title: "Directory",
            keywords: [
                "browse services", "mcp directory", "discover mcp", "provider catalog", "linear",
                "github", "notion", "custom server", "connectors", "legal connectors",
                "accounting connectors", "finance connectors", "healthcare connectors", "quickbooks",
                "xero", "docusign", "google drive", "gmail", "slack", "dropbox", "gusto",
                "microsoft 365", "outlook", "harvey",
            ],
            subTab: "Services"
        ),
        .init(
            id: "tools.allTools",
            tab: .tools,
            section: "All Tools",
            title: "All Tools",
            keywords: [
                "tool list", "per tool permission", "folder permissions", "write files", "edit files",
                "shell", "git commit", "working folder", "auto ask deny",
            ],
            subTab: "All",
            disambiguation:
                "Every tool with its own Auto/Ask/Deny policy, including the folder tools (write/edit/shell/git).",
            declarativeSection: "tools"
        ),
        .init(
            id: "tools.plugins",
            tab: .tools,
            title: "Plugins",
            keywords: ["native plugins", "install plugin", "plugin registry", "browse plugins", "dylib"],
            subTab: "Native Plugins",
            disambiguation: "Tools & MCP header → Plugins. Installed native plugins and the plugin catalog.",
            declarativeSection: "plugins"
        ),
        .init(
            id: "skills.overview",
            tab: .skills,
            title: "Skills",
            keywords: ["skill packs", "install skill", "skill.md", "add skill", "create skill", "import skill", "import claude plugin"],
            disambiguation: "Skills header → Add skill: Create skill, Import skill, or Import Claude plugin from GitHub."
        ),
        .init(
            id: "commands.overview",
            tab: .commands,
            title: "Commands",
            keywords: ["slash commands", "custom command", "prompt command"],
            declarativeSection: "commands"
        ),
        .init(
            id: "approvals.overview",
            tab: .approvals,
            title: "Needs You",
            keywords: [
                "inbox", "approvals", "waiting for me", "waiting on me", "needs attention", "pending approvals",
                "approve requests", "allow requests", "agent questions", "attention", "requests for action",
                "teammate requests", "unanswered",
            ],
            disambiguation:
                "Inbox → Needs You, under Automations in the sidebar: everything waiting on your answer, from every agent and teammate (tool calls, a teammate's tool call on your shared agent, an agent's question, a workflow form, a configuration change, a Computer Use step, a secret request, an MCP form). Approvals show Deny and Allow, with Allow for This Conversation under ⋯; questions take a Reply; forms open. The first answer from here, the chat card, the desktop notification or your iPhone wins. Messages and notices are not listed; they arrive as notifications and are in Insights → Interactions. Not the same as General → Notifications → Approvals (where these requests reach you) or the Approvals filter in a workspace's Audit (this Mac)."
        ),
        .init(
            id: "approvals.waitingOnOthers",
            tab: .approvals,
            title: "Waiting on Others",
            keywords: [
                "waiting on owner", "waiting for approval", "owner approval pending", "paused chat",
                "someone else's agent", "shared agent waiting",
            ],
            disambiguation:
                "Inbox → Waiting on Others: your chats with someone else's shared agent that are paused while its owner decides whether to allow a tool. Open Chat goes to the conversation; the row clears when the owner answers or the chat stops."
        ),
        .init(
            id: "approvals.liveNow",
            tab: .approvals,
            title: "Live Now",
            keywords: [
                "who is using my agent", "active guests", "active teammates", "live runs", "iphone using agent",
                "people using my agents", "current sessions",
            ],
            disambiguation:
                "Inbox → Live Now: people using your agents on this Mac right now: teammates in a workspace, guests on a guest link, and your own iPhone or other Macs over Sync. Open shows the conversation. Who may use an agent is under Sharing → Access."
        ),
        .init(
            id: "approvals.history",
            tab: .approvals,
            title: "Past Requests",
            keywords: [
                "past approvals", "answered", "timed out", "approval history", "what I approved", "denied requests",
            ],
            disambiguation:
                "Inbox → Past Requests opens Insights → Interactions: every request you answered, denied, dismissed or let time out, with who asked and where."
        ),
        .init(
            id: "automations.overview",
            tab: .automations,
            title: "Automations",
            keywords: [
                "events", "schedules", "schedule", "cron", "interval", "timed job", "recurring", "watchers",
                "folder watcher", "file events", "watch folder", "triggers", "trigger", "listeners", "automation",
                "automate", "when do result", "what it triggers",
            ],
            disambiguation:
                "Things that run on their own, grouped as Schedules, Folder watchers, Webhooks, Feeds, Event streams, Failure handlers and App events. Each reads When → Do → Result: the trigger, the agent or workflow it runs, and what comes of it. Channel messages and email are not here: who answers on a channel (Email included) is Channels → the channel → Routing.",
            declarativeSection: "automations"
        ),
        .init(
            id: "automations.channelRulesNote",
            tab: .automations,
            title: "Open Channels",
            keywords: [
                "message rules", "channel automations", "channel message", "message automation", "custom routing",
                "aliases", "per-room agent", "where did channel automations go", "channel routing rules",
            ],
            disambiguation:
                "The note under the Automations list when channel routing rules exist. Rules that answer channel messages live on their channel: Channels → the channel → Routing.",
            declarativeSection: "channels"
        ),
        .init(
            id: "automations.add",
            tab: .automations,
            title: "Add Automation",
            keywords: [
                "add event", "new event", "new automation", "new schedule", "new watcher", "create trigger",
                "trigger workflow", "trigger agent",
            ],
            disambiguation:
                "Pick Schedule, Folder, Webhook, RSS Feed, Event Stream, Run Failed or App Event (or a service under App Webhooks), then an agent or a workflow. To answer channel messages or email, use Channels → the channel (or Email) → Routing → Add Rule.",
            declarativeSection: "automations"
        ),
        .init(
            id: "automations.webhookUrl",
            tab: .automations,
            title: "Webhook URL",
            keywords: [
                "webhook", "incoming webhook", "http trigger", "relay url", "event url", "hmac",
                "signing secret", "rotate token", "github webhook", "zapier",
            ],
            disambiguation:
                "Shown on a Webhook automation's detail. POST to /events/<token> locally or through the agent relay; HMAC-SHA256 or a shared-secret header is checked when set. The same card shows the secret (Show / Copy / Rotate Secret) and Try it, a ready-to-run curl command. Not the n8n outbound webhook (Channels → n8n).",
            declarativeSection: "automations"
        ),
        .init(
            id: "automations.webhookVerification",
            tab: .automations,
            title: "How does the sender prove it's them?",
            keywords: [
                "webhook verification", "verification", "hmac", "hmac-sha256", "hmac-sha256 signature", "signature",
                "signature header", "shared secret header",
                "shared secret", "secret header", "x-hub-signature-256", "github webhook secret", "header name",
                "verify webhook", "url token only",
            ],
            disambiguation:
                "In the Add/Edit Automation sheet for a Webhook: HMAC-SHA256 signature (recommended), Shared secret header, or URL token only. Advanced holds the header name (empty uses X-Osaurus-Signature or X-Osaurus-Event-Secret; GitHub needs X-Hub-Signature-256) and the body and rate limits. The secret is created on save and shown on the automation's detail under Webhook URL.",
            declarativeSection: "automations"
        ),
        .init(
            id: "automations.runNow",
            tab: .automations,
            title: "Run Now",
            keywords: ["fire now", "test automation", "test event", "trigger now", "run schedule now", "test webhook"],
            disambiguation:
                "On an automation's detail. Runs it once immediately, even when it is turned off; a Webhook automation runs with its sample body (What does the sender post?), or an empty JSON body when none is set. An RSS Feed runs with the feed's newest item; Run Failed and App Event run with an example.",
            declarativeSection: "automations"
        ),
        .init(
            id: "automations.historyButton",
            tab: .automations,
            title: "Automation History",
            keywords: ["history button", "past runs", "automation history", "schedule history", "why didn't it run"],
            disambiguation:
                "The History button in the Automations header opens Tasks → History filtered to automations: every run, skip and failure, newest first. Channel messages that never reached an automation are Automations → ⋯ → Channel Messages."
        ),
        .init(
            id: "automations.history",
            tab: .automations,
            title: "Channel Messages",
            keywords: [
                "channel activity", "unclaimed messages", "denied messages", "allowlist rejections",
                "incoming messages", "redacted export", "received", "duplicates", "form answers",
            ],
            subTab: "history",
            disambiguation:
                "Automations → ⋯ → Channel Messages. Channel messages that never reached an automation (refused by an allowlist, failed, or claimed by no automation) and those taken as a workflow form's answer, with the reason and the fix; Received/Denied/Duplicates counts and Copy redacted export. Replaces the old Channels → Activity tab. Automation runs themselves are in Tasks → History.",
            declarativeSection: "automations"
        ),
        .init(
            id: "tasks.overview",
            tab: .tasks,
            title: "Tasks",
            keywords: [
                "task queue", "queues", "background tasks", "running tasks", "what is running", "job queue",
                "task board", "waiting tasks", "stop a task", "recently finished", "foreground", "what is using the model",
            ],
            disambiguation:
                "Developer Tools → Tasks. Every automation run, background agent turn, workflow run and helper is a task. Tasks shows what holds a model in the foreground right now (chats, API and plugin requests), one row per queue (running, waiting, the last few finished), and History (Failed narrows it to failures). What waits on your answer is the Approvals page. A task's detail has its timeline, related tasks and links to the chat that started it, the chat it ran in, its workflow run, automation and Insights. Chats and API requests are not tasks and are never queued."
        ),
        .init(
            id: "tasks.addQueue",
            tab: .tasks,
            title: "Add Queue",
            keywords: ["new queue", "create queue", "another queue", "separate queue"],
            disambiguation:
                "Developer Tools → Tasks → Add queue. A queue holds tasks until a slot frees up; automations pick one in their Queue section (the picker appears once a second queue exists). Tasks without a queue of their own run on Default."
        ),
        .init(
            id: "tasks.queue.default",
            tab: .tasks,
            title: "Default Queue",
            keywords: ["default queue", "main queue"],
            disambiguation:
                "Developer Tools → Tasks → Default. The system queue every automation, background chat, plugin dispatch and helper uses unless it names another. It can be tuned but not renamed or deleted."
        ),
        .init(
            id: "tasks.queue.settings",
            tab: .tasks,
            title: "Queue Settings",
            keywords: ["edit queue", "queue options", "pause queue", "delete queue"],
            disambiguation:
                "Developer Tools → Tasks → a queue's settings button. Max Concurrent Tasks, Max Waiting Tasks, When Full, Start Order and Paused; user queues also have Name and Delete Queue."
        ),
        .init(
            id: "tasks.queue.maxConcurrent",
            tab: .tasks,
            title: "Max Concurrent Tasks",
            keywords: [
                "max concurrent background tasks", "max concurrent tasks", "concurrent tasks", "background task limit",
                "how many run at once", "parallel tasks",
            ],
            disambiguation:
                "Developer Tools → Tasks → Default (or another queue) → settings → Max Concurrent Tasks (Default: 20). How many of that queue's tasks run at the same time, across automations, background chats and plugin dispatch; each agent still runs at most 5 at once. Not Server → Concurrent Sessions, which caps simultaneous model generations. Formerly under Notifications."
        ),
        .init(
            id: "tasks.queue.maxWaiting",
            tab: .tasks,
            title: "Max Waiting Tasks",
            keywords: ["queue size", "max queued tasks", "queue limit", "pending limit"],
            disambiguation:
                "Developer Tools → Tasks → a queue → settings. How many tasks may wait for a turn; 0 means no limit. When Full decides what happens past it."
        ),
        .init(
            id: "tasks.queue.overflow",
            tab: .tasks,
            title: "When Full",
            keywords: ["queue full", "overflow", "drop oldest", "refuse new tasks", "keep only the newest"],
            disambiguation:
                "Developer Tools → Tasks → a queue → settings, shown once Max Waiting Tasks is set: Refuse new tasks, Keep only the newest per conversation, or Drop the oldest waiting task."
        ),
        .init(
            id: "tasks.queue.ordering",
            tab: .tasks,
            title: "Start Order",
            keywords: ["fifo", "in order", "any order", "one at a time per conversation", "queue ordering"],
            disambiguation:
                "Developer Tools → Tasks → a queue → settings. In order (first in, first out), One at a time per conversation, or Any order."
        ),
        .init(
            id: "tasks.queue.paused",
            tab: .tasks,
            title: "Paused",
            keywords: ["pause queue", "hold tasks", "resume queue"],
            disambiguation:
                "Developer Tools → Tasks → a queue → settings. Holds new tasks without starting them; running tasks finish. The queue shows a Paused chip."
        ),
        .init(
            id: "tasks.history",
            tab: .tasks,
            title: "History",
            keywords: [
                "task history", "run history", "every run", "event history", "agent runs", "workflow runs history",
                "skipped runs", "tasks from this chat", "what this chat started",
            ],
            disambiguation:
                "Developer Tools → Tasks → History. Every task newest first, filtered by where it came from, its result (Ran / Skipped / Failed), its queue (once there is more than one), one agent or workflow, or the chat that started it. Automations → History, an agent's Recent Tasks → See All, a workflow's All Tasks and a chat's Tasks from This Chat (chat sidebar context menu) open it pre-filtered."
        ),
        .init(
            id: "agents.automation.recentTasks",
            tab: .agents,
            title: "Recent Tasks",
            keywords: ["agent run history", "what the agent ran", "agent tasks"],
            subTab: "automation",
            disambiguation:
                "Agents → the agent → Automations → Recent Tasks. The agent's last few tasks; See All opens Tasks → History for it."
        ),
        .init(
            id: "automations.runs",
            tab: .automations,
            title: "Runs",
            keywords: [
                "run log", "event log", "skipped", "filtered", "duplicate", "rate limited", "queue full", "ledger",
            ],
            disambiguation:
                "On an automation's detail. Its recent tasks, including ones that were filtered, de-duplicated, refused (bad signature, rate limit, queue full) or cancelled; each opens the task's detail. All automations together: Tasks → History.",
            declarativeSection: "automations"
        ),
        .init(
            id: "automations.queueing",
            tab: .automations,
            title: "Queue",
            keywords: [
                "queueing", "allow overlapping runs", "serial", "parallel", "one per conversation", "max queued",
                "duplicate check", "dedupe", "idempotency", "missed run", "if the app was closed", "busy",
            ],
            disambiguation:
                "In the Add/Edit Automation sheet, the Queue section: which queue its runs wait on (shown once Developer Tools → Tasks has a second queue; otherwise Default), Allow Overlapping Runs (off runs one at a time), Queued Messages for channel rules, the duplicate check, and for schedules whether a slot missed while the app was closed still runs. How many tasks a queue runs at once is the queue's Max Concurrent Tasks in Tasks.",
            declarativeSection: "automations"
        ),
        .init(
            id: "automations.reply",
            tab: .automations,
            title: "Send the agent's reply without asking",
            keywords: [
                "auto reply", "reply automatically", "auto-reply", "channel reply", "approve reply",
                "send workflow output", "reply with workflow output", "replies from its steps",
                "workflow reply step",
            ],
            disambiguation:
                "In the Edit Routing Rule sheet (Reply step); the same choice is the Replies menu (Automatically / After approval) on the rule's row under Channels → the channel → Routing. After approval holds the reply in the chat. For workflow rules the choice is Posts the output / Doesn't reply (shown as Replies from its steps when the workflow has its own Reply step; the output is then posted only when no Reply step posted). A workflow's Reply step is part of the workflow, edited in the Architect, not a setting.",
            declarativeSection: "channels"
        ),
        .init(
            id: "automations.filter",
            tab: .automations,
            title: "Only When (optional)",
            keywords: [
                "event filter", "automation filter", "keyword filter", "sender allowlist", "only from",
                "payload condition", "file glob", "only pdf", "match text",
            ],
            disambiguation:
                "In the Add/Edit Automation sheet. Narrows when an automation runs: text keywords, senders, changed-file globs, or payload conditions such as webhook.body.action = opened. Who may reach a channel at all is still the channel's sender allowlist.",
            declarativeSection: "automations"
        ),
        .init(
            id: "automations.importExport",
            tab: .automations,
            title: "Export Automations…",
            keywords: [
                "import automations", "export automations", "import events", "export events", "automations yaml",
                "backup automations", "share automations", "more", "overflow menu",
            ],
            disambiguation:
                "The ⋯ menu next to Add Automation: Import Automations… and Export Automations….",
            declarativeSection: "automations"
        ),
        .init(
            id: "automations.webhookSampleBody",
            tab: .automations,
            title: "What does the sender post?",
            keywords: [
                "sample body", "example payload", "sample payload", "webhook body", "json sample", "webhook fields",
                "body fields", "test payload",
            ],
            disambiguation:
                "In the Add/Edit Automation sheet for a Webhook. An example of the JSON the sender posts. Its fields become trigger values (Body: issue.title) for agent instructions and workflow inputs, and Run Now and Try it send it.",
            declarativeSection: "automations"
        ),
        .init(
            id: "automations.workflowInputs",
            tab: .automations,
            title: "Inputs",
            keywords: [
                "workflow inputs", "workflow parameters", "parameters", "input mapping", "bind input", "bind",
                "trigger values", "required input", "fixed value", "custom template", "input_mapping",
                "workflow arguments",
            ],
            disambiguation:
                "In the Add/Edit Automation sheet when Do is Run a workflow. One row per workflow input: bind it to a trigger value (Scheduled time, Changed files, Body: …), a custom template, or a fixed value. Required inputs must be bound or every run fails; the sample run preview shows the values.",
            declarativeSection: "automations"
        ),
        .init(
            id: "automations.runAs",
            tab: .automations,
            title: "Run as",
            keywords: [
                "run workflow as agent", "workflow agent keys", "automation agent", "shared keys", "agent keys",
                "agent sessions", "which keys", "run as agent",
            ],
            disambiguation:
                "In the Add/Edit Automation sheet when Do is Run a workflow. No agent (the default) runs the workflow with the shared keys in the Vault and each service's default session; picking an agent uses that agent's own keys and sign-ins where it has them. Not the agent a Run Agent automation talks to."
        ),
        .init(
            id: "automations.action",
            tab: .automations,
            title: "Do",
            keywords: [
                "run agent", "run workflow", "ask a model", "automation action", "what it does",
                "no agent automation", "without an agent", "prompt automation", "model answer", "tool-less",
            ],
            disambiguation:
                "In the Add/Edit Automation sheet: Run Agent (a custom agent with its tools), Run Workflow (an installed workflow with bound inputs), or Ask a Model (one answer with no tools and no agent, saved as a chat). Routing rules offer only Run Agent and Run Workflow.",
            declarativeSection: "automations"
        ),
        .init(
            id: "automations.promptModel",
            tab: .automations,
            title: "Model",
            keywords: [
                "ask a model model", "automation model", "prompt model", "which model answers", "default model",
            ],
            disambiguation:
                "In the Add/Edit Automation sheet when Do is Ask a Model. Default model uses the default model for new agents; pick another to pin one. Not an agent's model or the Architect Model.",
            declarativeSection: "automations"
        ),
        .init(
            id: "automations.appWebhooks",
            tab: .automations,
            title: "App Webhooks",
            keywords: [
                "github trigger", "stripe trigger", "slack events api", "shopify trigger", "twilio trigger",
                "microsoft graph", "outlook trigger", "meta webhook", "facebook webhook", "instagram webhook",
                "whatsapp cloud", "amazon sns", "sns topic", "provider webhook", "service webhook",
            ],
            disambiguation:
                "In Add Automation, below the triggers: a Webhook preset for GitHub, Stripe, Slack, Shopify, Twilio, Microsoft Graph, Meta or Amazon SNS. Each checks the service's own signature and answers its setup handshake (Slack URL check, Graph validation, Meta hub challenge, SNS subscription). The same choice is Sender on any Webhook automation.",
            declarativeSection: "automations"
        ),
        .init(
            id: "automations.webhookProvider",
            tab: .automations,
            title: "Sender",
            keywords: ["webhook provider", "webhook sender", "who sends the webhook", "any sender"],
            disambiguation:
                "In the Add/Edit Automation sheet for a Webhook. Any sender uses the verification you pick; a named service (GitHub, Stripe, Slack, …) is checked the way that service signs, so the verification choices are hidden.",
            declarativeSection: "automations"
        ),
        .init(
            id: "automations.webhookProviderSecret",
            tab: .automations,
            title: "Signing Secret",
            keywords: [
                "paste webhook secret", "stripe signing secret", "whsec", "slack signing secret", "shopify signing key",
                "twilio auth token", "meta app secret", "provider secret",
            ],
            disambiguation:
                "For Stripe, Slack, Shopify, Twilio and Meta webhooks, which issue their own secret: paste it in the Add/Edit Automation sheet or later on the automation's detail under Webhook URL. Stored in the Keychain; requests are refused until it is saved. GitHub and Microsoft Graph use the secret Osaurus creates instead.",
            declarativeSection: "automations"
        ),
        .init(
            id: "automations.rssFeedUrl",
            tab: .automations,
            title: "Feed URL",
            keywords: ["rss", "rss feed", "atom feed", "json feed", "feed trigger", "new blog post", "podcast feed"],
            disambiguation:
                "In the Add/Edit Automation sheet for an RSS Feed automation. An RSS, Atom or JSON Feed address; each item published after the first check runs the automation once.",
            declarativeSection: "automations"
        ),
        .init(
            id: "automations.rssPollInterval",
            tab: .automations,
            title: "Check Every",
            keywords: ["feed poll interval", "rss interval", "how often to check the feed"],
            disambiguation:
                "In the Add/Edit Automation sheet for an RSS Feed automation: minutes between checks (1 to 1440).",
            declarativeSection: "automations"
        ),
        .init(
            id: "automations.rssMaxItems",
            tab: .automations,
            title: "Items per Check",
            keywords: ["max items per check", "feed burst", "rss item limit"],
            disambiguation:
                "In the Add/Edit Automation sheet for an RSS Feed automation: new items one check hands on (1 to 100); older ones in a burst are skipped.",
            declarativeSection: "automations"
        ),
        .init(
            id: "automations.rssCatchUp",
            tab: .automations,
            title: "After a Restart",
            keywords: ["feed catch up", "missed feed items", "items published while closed"],
            disambiguation:
                "In the Add/Edit Automation sheet for an RSS Feed automation: what the first check after Osaurus restarts does with items published while it was closed (everything, only the newest, or skip).",
            declarativeSection: "automations"
        ),
        .init(
            id: "automations.sseUrl",
            tab: .automations,
            title: "Stream URL",
            keywords: [
                "sse", "server-sent events", "event stream", "text/event-stream", "sse trigger", "streaming endpoint",
            ],
            disambiguation:
                "In the Add/Edit Automation sheet for an Event Stream automation. Osaurus stays connected while it is on, reconnects after drops and resumes from the last event id.",
            declarativeSection: "automations"
        ),
        .init(
            id: "automations.sseEventNames",
            tab: .automations,
            title: "Event Names",
            keywords: ["sse event filter", "event type filter", "only some stream events"],
            disambiguation:
                "In the Add/Edit Automation sheet for an Event Stream automation: the SSE event: names that run it, comma separated; empty runs on every message.",
            declarativeSection: "automations"
        ),
        .init(
            id: "automations.sseHeaders",
            tab: .automations,
            title: "Request Headers",
            keywords: ["sse headers", "stream headers", "connect headers"],
            disambiguation:
                "In the Add/Edit Automation sheet for an Event Stream automation: Name: value lines sent when connecting. Stored and exported as written, so not for secrets.",
            declarativeSection: "automations"
        ),
        .init(
            id: "automations.sseHeartbeat",
            tab: .automations,
            title: "Reconnect When Silent",
            keywords: ["sse heartbeat", "stream timeout", "idle reconnect"],
            disambiguation:
                "In the Add/Edit Automation sheet for an Event Stream automation: reconnect when nothing, not even a comment, arrives for this many seconds; 0 is off.",
            declarativeSection: "automations"
        ),
        .init(
            id: "automations.runFailedWorkflows",
            tab: .automations,
            title: "Workflows (none picked: any workflow)",
            keywords: [
                "run failed", "error trigger", "on failure", "workflow failed", "failure handler", "alert on failure",
                "notify on error",
            ],
            disambiguation:
                "In the Add/Edit Automation sheet for a Run Failed automation: the workflows whose failed runs start it; none picked means any workflow. Its own runs and test runs never start it.",
            declarativeSection: "automations"
        ),
        .init(
            id: "automations.runFailedIncludeAutomations",
            tab: .automations,
            title: "Also when an automation's run fails",
            keywords: ["agent automation failed", "automation failure alert"],
            disambiguation:
                "In the Add/Edit Automation sheet for a Run Failed automation: also start it when an automation that runs an agent fails (workflow failures are already covered).",
            declarativeSection: "automations"
        ),
        .init(
            id: "automations.appEventReasons",
            tab: .automations,
            title: "Run when",
            keywords: [
                "app event", "on launch", "osaurus starts", "startup automation", "activation trigger",
                "this automation is turned on", "this automation is changed",
            ],
            disambiguation:
                "In the Add/Edit Automation sheet for an App Event automation: Osaurus starts, This automation is turned on, This automation is changed. Saves that change nothing fire nothing.",
            declarativeSection: "automations"
        ),
        .init(
            id: "workflows.overview",
            tab: .workflows,
            title: "Workflows",
            keywords: [
                "workflow", "installed workflows", "pipeline", "dag", "run workflow", "workflow tab",
                "run history", "workflow runs", "past runs", "see all runs", "run with different input",
                "manage workflows", "make workflows", "publish workflows", "studio", "library", "workflow library",
                "my workflows",
            ],
            subTab: "workflows",
            disambiguation: "Main window ▸ Workflows: one page with Import and New Workflow (⌘N) in its header, Running now while anything runs, then the workflows in tabs: All, Drafts while any are unfinished, and Published once anything is. It opens on the tab last used. Run starts a workflow at once when it needs nothing, else asks for its input; a row opens to show its last runs, and See all runs opens the workflow's page. With no workflows and no drafts the page is New Workflow alone."
        ),
        .init(
            id: "workflows.runningNow",
            tab: .workflows,
            section: "Workflows",
            title: "Running now",
            keywords: [
                "live runs", "running workflows", "what is running", "automation runs", "waiting on you", "respond",
                "stop a run", "workflow progress", "triggered by automation",
            ],
            subTab: "workflows",
            disambiguation: "At the top of Workflows, above the tabs, while any workflow is running: each run with its step progress, who started it (you, an agent, or an automation, with a bolt), Stop, and Respond when it waits on a form. Shown only while something runs."
        ),
        .init(
            id: "workflows.all",
            tab: .workflows,
            section: "Workflows",
            title: "All",
            keywords: [
                "all workflows", "ready to run", "installed workflows", "update workflow", "needs setup", "set up",
                "nothing to run yet",
            ],
            subTab: "workflows.all",
            disambiguation: "The Workflows page's first tab: every installed workflow with an Update to vN chip when one is available, a Live badge once published, when it last ran, and Run (Set Up while it needs setup), plus its … menu (Publish…, Save as File…, Version History, and the rest)."
        ),
        .init(
            id: "workflows.new",
            tab: .workflows,
            section: "Workflows",
            title: "New Workflow",
            keywords: [
                "describe a task", "new workflow", "start something new", "create a workflow", "ready-made workflows",
                "or add a ready-made workflow", "add a workflow", "starter workflows", "templates to add",
                "create your first workflow", "ready to add",
            ],
            subTab: "new",
            disambiguation: "The New Workflow page, opened from New Workflow in the Workflows header or ⌘N, with ‹ Workflows in the title bar to go back: the Architect's composer (sending starts a new draft with your words as its first message), then Or add a ready-made workflow, the templates not set up yet, each opening a preview with Add, and Import a workflow. With no workflows and no drafts it is the whole Workflows page, titled Create your first workflow."
        ),
        .init(
            id: "workflows.drafts",
            tab: .workflows,
            section: "Workflows",
            title: "Drafts",
            keywords: [
                "unfinished workflow", "continue editing", "continue where you left off", "delete draft", "draft workflows",
                "resume draft",
            ],
            subTab: "workflows.drafts",
            disambiguation: "The Workflows page's Drafts tab, shown while any draft is unfinished: each with where it stands (Design → Test → Save → Publish), when it was last edited, Continue, and Delete Draft… in its … menu."
        ),
        .init(
            id: "workflows.published",
            tab: .workflows,
            section: "Workflows",
            title: "Published",
            keywords: [
                "published workflows", "my published workflows", "published filter", "manage published", "live workflows",
            ],
            subTab: "workflows.published",
            disambiguation: "The Workflows page's Published tab, shown once this Mac has published a workflow: the same rows as All, narrowed to what you've published, each with its Live badge (click it to manage the listing)."
        ),
        .init(
            id: "workflows.workspaces",
            tab: .workflows,
            section: "Workflows",
            title: "Workspaces",
            keywords: [
                "workspace workflows", "team workflows", "shared with my workspace", "install from workspace",
                "teammate workflows", "shared in workspace", "nothing shared yet", "workspace settings",
            ],
            subTab: "workflows.workspaces",
            disambiguation: "The Workflows page's Workspaces tab, shown while you belong to a workspace: one section per workspace with what members shared there (Install a copy, then Update, Set Up or Open) and what teammates' agents run on their own Macs (Runs on X's Mac). Installed copies show Shared in <workspace> under All. The same list is in Settings → Workspaces → (workspace) → Workflows, which has Open in Workflows."
        ),
        .init(
            id: "workflows.addHosted",
            tab: .workflows,
            section: "Workspaces",
            title: "Add to My Workflows",
            keywords: [
                "runs on their mac", "run on a teammate's mac", "hosted workflow", "run without installing",
                "on teammates' macs", "remove from my workflows",
            ],
            subTab: "workflows.workspaces",
            disambiguation: "On a workflow a teammate's shared agent runs for the workspace: adds it without installing a copy. It then lists under All → On teammates' Macs and in each agent's Abilities → Workflows; every run goes to its owner's Mac, which asks them first and uses their keys and folders. Remove from My Workflows is in its menu. Install instead keeps a copy that runs here."
        ),
        .init(
            id: "workflows.importExport",
            tab: .workflows,
            section: "Workflows",
            title: "Import",
            keywords: [
                "import template", "export template", "export workflow", "save as file", "workflow file",
                "osaurustemplate", "workflow templates", "version history", "restore version",
                "import and add", "open template file", "templates-import", "template link", "sign template",
                "suggest models", "mcp server hints", "include server setup", "show in finder", "import workflow",
                "import a workflow",
            ],
            subTab: "workflows",
            disambiguation: "Import is in the Workflows header (and Import a workflow on the New Workflow page); a workflow file dropped anywhere on Workflows imports too. Saving a workflow as a file is Save as File… in a workflow's … menu, or Share… ▸ Save as a file on its page. Agent templates live in Agents ▸ Templates. Template files also open from Finder. osaurus://templates-import links are accepted only from the store registry (store.osaurus.ai Install button)."
        ),
        .init(
            id: "workflows.architect",
            tab: .workflows,
            section: "Workflows",
            title: "New Workflow",
            keywords: [
                "create workflow", "architect", "build workflow", "describe a task", "build with the architect",
            ],
            subTab: "new",
            disambiguation: "New Workflow (in the Workflows header, ⌘N in Workflows) opens the New Workflow page with its composer focused: describe the task and the Architect starts a new draft from it."
        ),
        .init(
            id: "workflows.automations",
            tab: .workflows,
            section: "Workflows",
            title: "Automations",
            keywords: ["run workflow on schedule", "workflow trigger", "schedule workflow", "workflow webhook", "run it automatically"],
            subTab: "workflows",
            disambiguation: "A link under the Workflows title (and Run it automatically under an open workflow row) to Automations, where a workflow is started by a schedule, folder, webhook or channel message. Runs automations start show up live in Workflows ▸ Running now."
        ),
        .init(
            id: "workflows.connections",
            tab: .workflows,
            section: "Workflows",
            title: "Connections",
            keywords: [
                "connections", "connection", "oauth", "sign in", "sign-in", "shared secret",
                "access token", "refresh token", "keep as a connection", "workflow secrets",
                "connect account", "reuse sign-in", "sign in again", "expired sign-in", "replace value",
                "manage all sign-ins in vault", "needs setup",
            ],
            subTab: "workflows",
            disambiguation: "Connections is a link under the Workflows title that opens the Connections sheet in the Workflows window. It lists each sign-in workflows use with its status, its service and the workflows that use it, with Sign In Again (or Replace Value for a pasted key) right there, and a Needs Setup list of workflows still missing a sign-in, each with Set Up. Manage All Sign-Ins in Vault opens General ▸ Vault ▸ Accounts to rename or remove a session, make it the default, or pick the session an agent uses. A workflow's setup offers the existing sessions for its secrets, can sign in as a new named session, and can keep a pasted value as one. Plain workflow secrets are saved in General ▸ Vault ▸ Your Keys."
        ),
        .init(
            id: "workflows.setup.agents",
            tab: .workflows,
            section: "Setup",
            title: "Agents",
            keywords: [
                "agent step", "ask an agent", "hand off to agent", "workflow agent", "choose an agent",
                "shared agent in workflow", "teammate agent step", "not reachable",
            ],
            disambiguation: "A step in a workflow's setup when it has agent steps. Each row is an agent the workflow asks, Reachable or Not reachable from this Mac; Choose… runs it as the workflow names it, as one of your agents, or as an agent shared in your workspaces. A teammate's shared agent runs on their Mac and gets only the task text. The Architect adds agent steps; Edit Step on one changes its Agent and Task."
        ),
        .init(
            id: "workflows.setup.agentsUnattended",
            tab: .workflows,
            section: "Setup",
            title: "Allow Without Asking",
            keywords: [
                "agent step approval", "unattended agent step", "scheduled workflow agent", "skip agent approval",
                "always allow agent step",
            ],
            disambiguation: "In a workflow's Agents setup step. On lets this workflow's agent steps run without an approval card, including scheduled and event runs nobody watches. It is saved on the workflow and covers only its steps: it does not change Agents → Delegation → Permission or the Orchestrator's own hand-offs. An agent's Deny still applies, runs a teammate starts still need your approval, and an update that asks a new agent turns it off again."
        ),
        .init(
            id: "workflows.stepBadges",
            tab: .workflows,
            section: "Workflow Details",
            title: "Step badges",
            keywords: [
                "risk badges", "cost badges", "what a step reaches", "hosts reached", "writes files", "runs shell",
                "drives the browser", "cloud model", "local model", "estimated tokens", "estimated time",
                "step risk", "step cost", "badges", "reaches", "sends to cloud", "your mac", "sandbox",
                "where it runs", "runs commands",
            ],
            disambiguation: "Badges under each step in a workflow's details (Osaurus does) and in the Architect's Draft steps: where it runs (Your Mac when it reads or saves files outside the run's workspace or acts on the Mac; Sandbox · Runs commands for shell steps), the hosts it reaches, secrets it reads, files it writes, browser use, whether its model runs here or in the cloud, and the time and tokens past runs took. Not a setting; they are computed from the steps and run history."
        ),
        .init(
            id: "workflows.yourFiles",
            tab: .workflows,
            section: "Architect Draft",
            title: "Your files",
            keywords: [
                "your files", "file access", "what it reads", "what it writes", "what it saves", "deletes",
                "replaces files", "folder access", "your mac", "sandbox", "access summary", "least access",
                "write scope", "read only folder",
            ],
            disambiguation: "A section in the Architect's Design tab: what the draft reads, writes, deletes, and replaces on your Mac, read from its steps, and whether it works in the sandbox. Runs enforce it: file steps save only where it says, read-only folders stay read-only, and replacing an existing file asks first. The same rows show under What It Does in a saved workflow's details, in the import review, and as one line in the save card, starter previews, and the publish review. Not a setting. Folders always allowed for a saved workflow are in Workflow Details under Before It Runs."
        ),
        .init(
            id: "workflows.draftChanges",
            tab: .workflows,
            section: "Architect Draft",
            title: "Changes",
            keywords: [
                "change summary", "what changed", "why it changed", "architect edits", "edit history", "undo",
                "review changes", "patch summary", "draft history", "diff",
            ],
            disambiguation: "A section in the Architect's Design tab: every edit to the draft, newest first, with who made it (the Architect or you), why in the Architect's words, and each change in plain language. Undo is on the newest. Version history of saved workflows is in Workflow Details."
        ),
        .init(
            id: "workflows.saveEvidence",
            tab: .workflows,
            section: "Architect Draft",
            title: "Test evidence",
            keywords: [
                "evidence", "test evidence", "tests passed", "passing test", "save requires test", "tested before save",
                "save disabled", "not tested since", "save card", "proof", "examples run",
            ],
            disambiguation: "Shown in the save card (the Architect's Save and workflow_propose_save): the test runs since the steps last changed, with the example, pass or fail, time, failed step and output. Save waits until one passes when the steps changed; a rename or summary edit alone needs no test."
        ),
        .init(
            id: "workflows.runFix",
            tab: .workflows,
            section: "Runs",
            title: "Fix with the Architect",
            keywords: [
                "fix failed run", "repair workflow", "workflow failed", "step failed", "fix workflow", "architect fix",
                "retry from failed step", "failed step", "why did it fail", "error hint",
            ],
            disambiguation: "On a failed run (its run page, the Architect's Test tab, and the Runs list's … menu): opens an Architect chat that reads the run's error, failed step, logs, and where the fix belongs (the step, setup, an app setting, a retry, or you), fixes it, re-tests from the failed step, and proposes the next version. The line under the error says what to change. Retry from Failed Step re-runs from that step without changing anything. Saving stays your click."
        ),
        .init(
            id: "workflows.share",
            tab: .workflows,
            title: "Share",
            keywords: [
                "share workflow", "share online", "export", "export workflow", "save as a file", "save as file",
                "share sheet", "share button", "two ways to share", "share a workflow",
            ],
            disambiguation: "Share… is in a workflow's page footer; each row on the Workflows page carries Publish… (or Manage Published… once live) and Save as File… in its … menu. Share offers two ways: Save as a file (.osaurustemplate) or Publish to store.osaurus.ai. Once published, the row's Live badge shows who can see it and installs, and opens the published dashboard. Theme sharing lives in Themes."
        ),
        .init(
            id: "workflows.publish",
            tab: .workflows,
            section: "Share",
            title: "Publish to store.osaurus.ai",
            keywords: [
                "publish workflow", "publish", "store.osaurus.ai", "store registry", "registry", "share link",
                "qr code", "copy link", "open page", "publish version", "update published version", "publish again",
                "live badge", "install link", "install workflow link", "share card", "author page", "@handle",
            ],
            disambiguation: "Publish… is in a workflow row's … menu on the Workflows page and the second option in Share. It needs an Osaurus ID, which signs the workflow. Pick who can see it before publishing. Afterward the row shows a Live badge and appears under Published; Manage Published…, Copy Link, Open Page, Publish Version N… and Take Down… are in its … menu."
        ),
        .init(
            id: "workflows.visibility",
            tab: .workflows,
            section: "Share",
            title: "Who can see it",
            keywords: [
                "visibility", "public", "unlisted", "hidden", "password", "password protected", "private workflow",
                "who can see", "listed on registry", "anyone with the link", "change visibility", "set password",
            ],
            disambiguation: "Chosen when publishing (Share ▸ Publish) and changeable any time in the published dashboard (a Live badge or Manage Published…). Public is reviewed by the Osaurus team first: it starts unlisted (the link works right away) and is listed and searchable once approved, so the button reads Submit for Review. Unlisted opens only by link; Password asks for a password you set (6–128 characters); Workspace shows it only to members of the workspaces you pick. None of those is reviewed. Saving the change asks for your Osaurus ID."
        ),
        .init(
            id: "workflows.shareWorkspaces",
            tab: .workflows,
            section: "Share",
            title: "Workspace",
            keywords: [
                "share workflow with workspace", "share with team", "share with teammates", "workspace visibility",
                "team only workflow", "members only", "workspace listing",
            ],
            disambiguation: "A Who can see it option when publishing. Pick up to 20 workspaces where you're an owner, admin or member (viewers can install but not share). Members see it in Workspaces → workspace → Workflows and install their own copy, which runs on their Mac. Not listed on the store and not reviewed. Change the workspaces later under Who can see it in the published dashboard. Leaving a workspace takes your listings out of it. To let teammates run it on your Mac instead, use Teammates can run this."
        ),
        .init(
            id: "workflows.review",
            tab: .workflows,
            section: "Published",
            title: "Store Review",
            keywords: [
                "review", "in review", "submitted for review", "submit for review", "changes requested",
                "rejected", "approved", "approval", "pending review", "unlisted until approved", "resubmit",
                "revise with architect", "reviewer note", "why not listed", "not in the store",
            ],
            disambiguation: "Public workflows are reviewed by the Osaurus team before the store lists them. Until then the listing is unlisted: its link works, but it isn't in the store. The Store Review panel at the top of the published dashboard (and the Submitted view right after publishing) tracks Listing → Signed and uploaded → Review → In the store. Decisions arrive within seconds as a toast or notification. When changes are requested it shows the reviewer's note with Revise with Architect and, once a newer version is saved, Resubmit vN. Cards read In review or Changes requested, with a dot until you open the decision. An update to a listed workflow waits the same way while the approved version stays in the store."
        ),
        .init(
            id: "workflows.listingDetails",
            tab: .workflows,
            section: "Share",
            title: "Listing Details",
            keywords: [
                "listing name", "listing description", "store name", "store description",
                "rename published workflow", "edit listing", "edit store listing", "page title", "use original",
            ],
            disambiguation: "In the publish step (Share ▸ Publish) and the published dashboard (Manage Published…): the Name and Description its store page shows instead of the workflow's own. No new version is published and the workflow people install doesn't change; new versions keep it. Use Original goes back to the workflow's own name and summary. In the dashboard, Save Listing applies it."
        ),
        .init(
            id: "workflows.topics",
            tab: .workflows,
            section: "Share",
            title: "Topics",
            keywords: [
                "store topics", "store tags", "listing tags", "categories", "browse by topic",
                "writing", "research", "productivity", "automation",
            ],
            disambiguation: "In the publish step and the published dashboard: up to 3 topics (Writing, Research, Coding, Data, Design, Media, Marketing, Productivity, Education, Finance, Automation, Fun) people browse store.osaurus.ai by. Not part of the workflow file. In the dashboard, Save Listing applies them."
        ),
        .init(
            id: "workflows.exampleRuns",
            tab: .workflows,
            section: "Share",
            title: "Example Runs",
            keywords: [
                "examples", "example runs", "sample runs", "test runs", "show results", "screenshots", "example images",
                "add example runs", "what leaves this mac", "showcase",
            ],
            disambiguation: "In the publish step and the published dashboard: up to 6 real runs from this Mac (Architect test runs included) shown on its page with what went in, what came out, and the images it made. Add Example Runs… picks them; each one previews What leaves this Mac and each image has Include. Secret inputs and local paths are left out and images lose their location and camera details. Nothing is shared until you confirm; remove them any time from the dashboard."
        ),
        .init(
            id: "workflows.publishedStats",
            tab: .workflows,
            section: "Published",
            title: "Installs",
            keywords: [
                "stats", "statistics", "install count", "installs", "how many installed", "published dashboard",
                "manage published", "versions published", "live since", "last updated", "published workflow",
            ],
            disambiguation: "The published dashboard opens from a workflow row's Live badge, Manage Published… in its … menu, or Manage Published… on the workflow's page. It shows installs, versions, live since and updated, with the registry's versions and your local version side by side."
        ),
        .init(
            id: "workflows.takeDown",
            tab: .workflows,
            section: "Published",
            title: "Take Down",
            keywords: [
                "take down", "unpublish", "unpublish workflow", "remove from registry", "delete published",
                "stop sharing", "republish", "publish again", "taken down", "removed by osaurus",
            ],
            disambiguation: "Take Down… is at the bottom of the published dashboard and in a published workflow's … menu. The page stops working for everyone; people who installed it keep their copy. Its row then reads Taken down, and Publish Again brings it back at the same link. A workflow the Osaurus team removed cannot be published again from here."
        ),
        .init(
            id: "workflows.shareCard",
            tab: .workflows,
            section: "Published",
            title: "Copy Image",
            keywords: [
                "share card", "share image", "social card", "preview image", "og image", "copy image", "save image",
                "share to", "post about", "announce workflow",
            ],
            disambiguation: "A 1200×630 image of the published workflow (name, summary, your handle, link and QR) shown after publishing and in the published dashboard. Copy Image puts it on the clipboard, Save Image… writes a PNG, Share… opens the macOS share menu."
        ),
        .init(
            id: "workflows.publishedByYou",
            tab: .workflows,
            section: "Workflows",
            title: "Your author page",
            keywords: [
                "published by you", "my published workflows", "author page", "my page on the registry",
                "published filter", "published tab", "n published", "total installs",
            ],
            subTab: "workflows",
            disambiguation: "A quiet line under the Workflows title once something is published: how many are published, total installs, and a link to your page on store.osaurus.ai. The Published tab narrows the list to them."
        ),
        .init(
            id: "workflows.shareAfterSave",
            tab: .workflows,
            section: "Architect Draft",
            title: "Share…",
            keywords: [
                "share after save", "saved card share", "share from architect", "publish after save", "saved workflow share",
                "resubmit for review", "resubmit after changes requested",
            ],
            disambiguation: "On the Architect's Saved card, next to Try It: opens Workflows with Share up for the workflow just saved. Try It opens its run form in Workflows, filled with its first example. When the Osaurus team asked for changes on its published listing, the button reads Resubmit for Review… and opens Share on the publish step for the new version."
        ),
        .init(
            id: "workflows.orchestratorVisible",
            tab: .workflows,
            section: "Workflow Details",
            title: "Osaurus can run this for you",
            keywords: [
                "visible to the orchestrator", "run_workflow", "orchestrator workflows", "hide workflow",
                "let osaurus run",
            ],
            disambiguation: "Per workflow. Which agents get a workflow as a tool is set on each agent. For a workflow added from a workspace that runs on a teammate's Mac, it's in that row's menu under All → On teammates' Macs."
        ),
        .init(
            id: "workflows.teammatesCanRun",
            tab: .workflows,
            section: "Workflow Details",
            title: "Teammates can run this",
            keywords: [
                "share workflow with workspace", "teammate workflow", "workspace workflow", "guest workflow",
                "shared agent workflow", "let teammates run", "remote workflow run",
            ],
            disambiguation: "Per workflow, off by default. Lets people chatting with one of your shared agents start this workflow through that agent's workflow tool; it runs on this Mac with your keys, connections and folders. Each call needs your approval, so the agent also needs Require Approval for Teammate Tool Calls (Workspaces → workspace → Shared Agents). To give teammates their own copy instead, use Share → Workspace."
        ),
        .init(
            id: "workflows.selfHeal",
            tab: .workflows,
            section: "Workflow Details",
            title: "Fix repeated failures automatically",
            keywords: [
                "self heal", "self-heal", "auto fix", "auto-repair", "repeated failures", "architect fixes",
                "fix with the architect", "failing workflow", "keeps failing",
            ],
            disambiguation: "Per workflow, off by default. After the same step fails three runs in a row, the Architect drafts a fix in a background chat and a notification offers it; nothing is saved without your review. Fix with the Architect in a run's menu does the same for one run, right away."
        ),
        .init(
            id: "workflows.savedAnswers",
            tab: .workflows,
            section: "Workflow Details",
            title: "Saved Answers",
            keywords: ["remembered answers", "clear answers", "workflow form answers"]
        ),
        .init(
            id: "workflows.tags",
            tab: .workflows,
            section: "Workflow Details",
            title: "Tags",
            keywords: [
                "tag a workflow", "label", "labels", "folders", "organize workflows", "group workflows", "categories",
                "add tags", "edit tags",
            ],
            disambiguation: "Per workflow, on its page: comma-separated labels (\"finance, weekly\") kept on this Mac and never exported. The library's filter bar searches them and offers one chip per tag."
        ),
        .init(
            id: "workflows.rename",
            tab: .workflows,
            section: "Workflow Details",
            title: "Rename…",
            keywords: [
                "rename workflow", "workflow name", "change name", "tool name", "workflow_", "name differs",
                "old name", "keep name", "use new name",
            ],
            disambiguation: "Per installed workflow: in its page's footer and its … menu. The name is what Settings shows and what agents and the Orchestrator call (workflow_<name>), separate from the template. Saving a renamed draft in the Architect renames it too; an update never does on its own, so a version with another name shows a notice offering Use or Keep. Old names keep working for steps that call it. Renaming a workflow template that is not installed is the template card's Rename…."
        ),
        .init(
            id: "workflows.edit",
            tab: .workflows,
            section: "Workflow Details",
            title: "Edit",
            keywords: [
                "edit workflow", "change workflow", "modify workflow", "edit with the architect", "change steps",
                "edit steps",
            ],
            disambiguation: "Per installed workflow: Edit in its page's footer, beside Run, and Edit with the Architect near the top of its … menu. Both open the workflow as a draft in the Architect; nothing changes until you save it there. Building a new workflow is New Workflow instead."
        ),
        .init(
            id: "workflows.tagFilter",
            tab: .workflows,
            section: "Workflows",
            title: "Search by name or tag…",
            keywords: [
                "filter workflows", "find a workflow", "search workflows", "tag filter", "tag chips", "workflow search",
            ],
            subTab: "workflows",
            disambiguation: "On the Workflows page's All and Published tabs: the search field sits in the tab row and one chip per tag in use sits above the list. The search field appears when any workflow is tagged or more than eight are installed. The Workflows lens in a chat's inspector has its own search field."
        ),
        .init(
            id: "workflows.storedData",
            tab: .workflows,
            section: "Workflow Details",
            title: "Stored Data",
            keywords: [
                "workflow state", "state step", "variables", "data table", "tables", "counter", "dedupe",
                "already handled", "seen items", "cache", "clear stored data", "persistent state", "kv",
            ],
            disambiguation: "Per workflow: the tables its state steps keep between runs (key, value, when it changed), with Clear per table or for all. Appears when the workflow has a state step or has stored something. Not the same as Saved Answers (remembered form answers) or agent memory."
        ),
        .init(
            id: "sandbox.overview",
            tab: .sandbox,
            title: "Sandbox",
            keywords: ["container", "isolation", "sandbox resources"]
        ),
        .init(
            id: "sandbox.status",
            tab: .sandbox,
            section: "Overview",
            title: "Overview",
            keywords: [
                "sandbox status", "start sandbox", "stop sandbox", "restart sandbox", "sandbox running",
                "sandbox error", "couldn't start",
            ],
            disambiguation: "Developer Tools → Sandbox → Overview: whether the sandbox is running, with Start, Stop, Restart, or Try Again and Copy Details after a failure. The sandbox starts by itself when an agent needs it."
        ),
        .init(
            id: "sandbox.cpus",
            tab: .sandbox,
            section: "Settings",
            title: "CPUs",
            keywords: ["sandbox cpu", "vm cores", "sandbox cores"],
            disambiguation: "Developer Tools → Sandbox → Settings. Cores the sandbox VM can use; applies when the sandbox restarts. Warns when it equals every core on this Mac."
        ),
        .init(
            id: "sandbox.memory",
            tab: .sandbox,
            section: "Settings",
            title: "Memory",
            keywords: ["sandbox memory", "sandbox ram", "vm memory"],
            disambiguation: "Developer Tools → Sandbox → Settings. Memory the sandbox VM can use, shared by every agent's and workflow's container; applies when the sandbox restarts. Warns above half this Mac's memory. While the sandbox runs, this amount is taken out of the Server → Memory Safety model load budget. Not agent memory."
        ),
        .init(
            id: "sandbox.network",
            tab: .sandbox,
            section: "Settings",
            title: "Network",
            keywords: [
                "sandbox network", "vm network", "network access", "filtered per agent", "sandbox egress",
                "sandbox internet",
            ],
            disambiguation: "Developer Tools → Sandbox → Settings. Read-only: the running sandbox's network (Open, Filtered per agent, Off), composed from each agent's own Sandbox Network and Allowed Domains (Agents → the agent → Sandbox). There is no sandbox-wide network switch."
        ),
        .init(
            id: "sandbox.agentsKeptWarm",
            tab: .sandbox,
            section: "Settings",
            title: "Agents Kept Warm",
            keywords: [
                "agent containers", "warm agents", "sandbox agents", "max agents", "agent environments",
                "per-agent environments", "concurrent sandbox agents", "pod size",
            ],
            disambiguation: "Developer Tools → Sandbox → Settings. How many agents and workflows each keep their own container in the sandbox VM at once; the default scales with this Mac's memory. One beyond this joins by restarting the sandbox, which waits for running commands first and never stops them: queued tasks wait as sandbox busy, others get a Sandbox is busy error. Not Concurrent Sessions or a CPU/memory limit."
        ),
        .init(
            id: "sandbox.environmentsKeptOnDisk",
            tab: .sandbox,
            section: "Settings",
            title: "Environments Kept on Disk",
            keywords: [
                "sandbox environments", "rootfs clones", "keep packages", "apk packages kept", "evicted environment",
                "sandbox disk",
            ],
            disambiguation: "Developer Tools → Sandbox → Settings. How many agent and workflow environments (each with its apk packages) stay on disk between runs; the least recently used beyond this are removed and set up again next time. Never fewer than Agents Kept Warm. Not the agents' home folders, which are always kept."
        ),
        .init(
            id: "sandbox.stopWhenIdle",
            tab: .sandbox,
            section: "Settings",
            title: "Stop When Idle",
            keywords: [
                "sandbox idle", "idle shutdown", "stop sandbox automatically", "free sandbox memory", "sandbox timeout",
            ],
            disambiguation: "Developer Tools → Sandbox → Settings. Minutes the sandbox VM may run with no commands, background jobs or connected sandboxed MCP servers before it stops to free its memory; 0 (the default) keeps it running. It starts again the next time an agent or workflow needs it."
        ),
        .init(
            id: "sandbox.autoStart",
            tab: .sandbox,
            section: "Settings",
            title: "Auto-Start",
            keywords: ["start sandbox at launch", "sandbox on launch", "launch sandbox"],
            disambiguation: "Developer Tools → Sandbox → Settings. Starts the sandbox when Osaurus launches instead of the first time an agent runs a command. Saves immediately."
        ),
        .init(
            id: "sandbox.workspace",
            tab: .sandbox,
            section: "Settings",
            title: "Workspace",
            keywords: ["sandbox files", "sandbox folder", "open workspace", "shared folder", "/workspace", "open sandbox in finder"],
            disambiguation: "Developer Tools → Sandbox → Settings → Open in Finder: every agent's sandbox home folder and the shared folder (~/.osaurus/container/workspace/). Not an agent's Working Folder on the Mac."
        ),
        .init(
            id: "sandbox.environments",
            tab: .sandbox,
            section: "Agents & Environments",
            title: "Agents & Environments",
            keywords: [
                "reset environment", "agent environment", "sandbox user", "linux user", "apk packages",
                "agent container",
            ],
            disambiguation: "Developer Tools → Sandbox → Agents & Environments: each agent's Linux user, network, packages and disk use, with Open in Finder and Reset Environment (removes apk packages and changes outside its home folder; restarts the sandbox if that agent is running)."
        ),
        .init(
            id: "sandbox.troubleshooting",
            tab: .sandbox,
            section: "Troubleshooting",
            title: "Troubleshooting",
            keywords: ["sandbox problems", "sandbox not working", "last failure", "sandbox support"],
            disambiguation: "Developer Tools → Sandbox → Troubleshooting (collapsed): the last startup failure, Provisioning Preflight, Run Diagnostics and Logs."
        ),
        .init(
            id: "sandbox.preflight",
            tab: .sandbox,
            section: "Troubleshooting",
            title: "Provisioning Preflight",
            keywords: ["preflight", "copy json", "host paths", "sandbox permissions"],
            disambiguation: "Developer Tools → Sandbox → Troubleshooting. Checks the host folders and permissions the sandbox needs, with Run and Copy JSON for support."
        ),
        .init(
            id: "sandbox.diagnostics",
            tab: .sandbox,
            section: "Troubleshooting",
            title: "Run Diagnostics",
            keywords: ["diagnostics", "sandbox test", "check sandbox"],
            disambiguation: "Developer Tools → Sandbox → Troubleshooting, while the sandbox runs. Tests exec, networking, agent users, apk and the bridge."
        ),
        .init(
            id: "sandbox.logs",
            tab: .sandbox,
            section: "Troubleshooting",
            title: "Logs",
            keywords: ["sandbox logs", "sandbox output", "container log", "clear logs", "tail logs"],
            disambiguation: "Developer Tools → Sandbox → Troubleshooting. Live sandbox activity and command output, filterable by level, with Tail/Full and Clear Logs."
        ),
        .init(
            id: "sandbox.reset",
            tab: .sandbox,
            section: "Danger Zone",
            title: "Reset Sandbox",
            keywords: ["reset container", "reinstall sandbox", "wipe sandbox"],
            disambiguation: "Developer Tools → Sandbox → Danger Zone. Deletes the Linux system and every agent's environment, then downloads and sets the sandbox up again. Agent home folders and the shared folder are kept. For one agent, use Reset Environment in Agents & Environments."
        ),
        .init(
            id: "sandbox.remove",
            tab: .sandbox,
            section: "Danger Zone",
            title: "Remove Sandbox",
            keywords: ["remove container", "delete sandbox", "uninstall sandbox", "free sandbox disk"],
            disambiguation: "Developer Tools → Sandbox → Danger Zone. Deletes the Linux system, agent environments and runtime downloads to free disk space; agent home folders are kept. Agents can't run commands until it is set up again on this page."
        ),
        .init(
            id: "insights.overview",
            tab: .insights,
            title: "Insights",
            keywords: [
                "analytics", "usage", "charts", "metrics", "activity log", "audit log", "audit trail",
                "activity history", "what was sent to the cloud", "cloud egress", "local vs cloud",
                "web search log", "mcp call log", "export activity", "verify log", "tamper evident",
                "request history", "review activity",
            ],
            disambiguation:
                "The Insights tab is the activity log / audit dashboard: every model request (local or cloud), web search, URL fetch, MCP tool call, channel delivery, Router call and inbound API request, with Local/Cloud badges, filters, Verify and Export. Retention and content policy live under Privacy & Security → Activity Log."
        ),
    ] + appleAppEntries

    /// One row per Apple app group in a custom agent's Abilities → Tools
    /// picker (`agents.appleApps.<app>`), with the exact group title and the
    /// tool verbs the model or a user might type. Generated from `AppleApp`
    /// so a new family cannot ship without a catalog row.
    static let appleAppEntries: [SettingsSearchEntry] = AppleApp.allCases.map { app in
        SettingsSearchEntry(
            id: "agents.appleApps.\(app.rawValue)",
            tab: .agents,
            section: "Abilities → Tools",
            title: app.displayName,
            keywords: appleAppKeywords(app),
            subTab: "capabilities",
            disambiguation:
                "Abilities → Tools group on a custom agent; the master checkbox (or any row switch) turns all \(app.displayName) tools on or off together (off by default). Not the \(app.displayName) plugin, which is built in now; not the macOS Permissions tab. Declarative: capabilities.apple_apps includes \"\(app.rawValue)\".",
            declarativeSection: "agents"
        )
    }

    private static func appleAppKeywords(_ app: AppleApp) -> [String] {
        var words = ["apple", "apple apps", "apple app", app.rawValue, "apple_apps"]
        words += app.toolNames.sorted()
        switch app {
        case .calendar: words += ["events", "schedule", "meeting", "ical", "eventkit", "agenda"]
        case .reminders: words += ["todo", "to-do", "task list", "due date", "reminder"]
        case .contacts: words += ["address book", "phone number", "email address", "people", "my card"]
        case .notes: words += ["apple notes", "note", "folders", "notebook"]
        case .mail: words += ["email", "inbox", "mailbox", "compose", "reply", "apple mail"]
        case .messages: words += ["imessage", "sms", "text message", "chat.db", "conversations"]
        case .maps: words += ["maps & location", "location", "directions", "geocode", "eta", "places", "nearby", "current location"]
        case .music: words += ["apple music", "now playing", "playlist", "play", "pause", "volume", "itunes"]
        case .shortcuts: words += ["shortcut", "run shortcut", "automation", "workflow"]
        }
        return words
    }
}
