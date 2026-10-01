import Testing

@testable import OsaurusCore

/// A settings entry a user cannot find by typing the words it displays is
/// invisible in practice. That is how the Sampling Defaults / Live Activity
/// pair went unreachable for "sampler" — see
/// `searchFindsSamplerByTheWordShownOnScreen`.
///
/// This sweeps the whole index rather than naming entries, so an entry added
/// later inherits the guarantee instead of needing its own test.
@Suite("settings search self-findability")
struct SettingsSearchSelfFindProbe {

    @Test("delegation RAM safety is shared config, not a UI-only control")
    func ramSafetyCatalogNamesWritableSection() throws {
        let entry = try #require(SettingsSearchIndex.entries.first {
            $0.id == "settings.orchestrator.delegation.ramSafety"
        })
        #expect(entry.declarativeSection == "delegation")
        #expect(!entry.isSettingsUIOnly)
    }

    @Test("every entry is findable by its own title")
    func everyEntryFindsItselfByTitle() {
        let unfindable = SettingsSearchIndex.entries
            .filter { entry in
                !SettingsSearchIndex.search(entry.title).contains { $0.id == entry.id }
            }
            .map(\.id)

        #expect(unfindable.isEmpty, "entries not found by their own title: \(unfindable)")
    }

    /// Section is optional — several entries are the whole tab and carry an
    /// empty one. Only entries that actually display a section header are
    /// required to be reachable by it.
    @Test("every entry with a section header is findable by that header")
    func everyEntryFindsItselfBySection() {
        let unfindable = SettingsSearchIndex.entries
            .filter { !$0.section.trimmingCharacters(in: .whitespaces).isEmpty }
            .filter { entry in
                !SettingsSearchIndex.search(entry.section).contains { $0.id == entry.id }
            }
            .map(\.id)

        #expect(unfindable.isEmpty, "entries not found by their own section: \(unfindable)")
    }

    /// Titles and section headers are not what the user reads. The Cache
    /// section passed both sweeps above on its title "Prompt Cache" while
    /// `0 settings match "disk cache"` — every control inside it is labelled
    /// "Disk Cache", "SSD Cache (L2)", "Disk Cache Size (% of disk)" or
    /// "Clear SSD Cache", and none of those resolved. An entry can be
    /// self-findable and still unreachable by every word on screen.
    ///
    /// So this pins the CONTROL labels, which the sweeps structurally cannot
    /// see. Add a row whenever a control is added or renamed.
    @Test("controls are findable by the label they display")
    func controlsFindableByOnScreenLabel() {
        let labels: [(query: String, entryID: String)] = [
            ("Border Color", "themes.borders.color"),
            ("Border Width", "themes.borders.width"),
            ("Border Opacity", "themes.borders.opacity"),
            ("model picker border", "themes.borders.color"),
            ("Credits border", "themes.borders.color"),
            ("menu border width", "themes.borders.width"),
            ("dropdown border opacity", "themes.borders.opacity"),
            ("Small body", "themes.typography.smallBody"),
            ("compact controls", "themes.typography.smallBody"),
            ("model picker", "themes.typography.smallBody"),
            ("Concurrent Sessions", "settings.server.concurrentSessions"),
            ("Prompt Prefill Chunk Size", "settings.server.prefillChunkSize"),
            ("Automatically Check Model Updates", "models.automaticUpdates"),
            ("Brief description (optional)", "agents.description"),
            ("agent description", "agents.description"),
            ("Swap local models for subagents", "settings.orchestrator.delegation.swapModels"),
            ("native mtp", "server.speculative"),
            ("speculative depth", "server.speculative"),
            ("keep model loaded", "server.residency"),
            ("unload after", "server.residency"),
            ("eviction policy", "server.residency"),
            ("disk cache", "server.cache"),
            ("ssd cache", "server.cache"),
            ("disk cache size", "server.cache"),
            ("Prefix Cache", "settings.server.prefixCache"),
            ("Enable GPU Cache", "settings.server.gpuCache"),
            ("Block Size (tokens)", "settings.server.gpuCacheBlockSize"),
            ("Max Blocks", "settings.server.gpuCacheMaxBlocks"),
            ("Disk Cache", "settings.server.diskCache"),
            ("Clear SSD Cache", "settings.server.clearDiskCache"),
            ("Disk Cache Directory", "settings.server.diskCacheDirectory"),
            ("Re-derive SSM State After Generation", "settings.server.ssmReDerive"),
            ("Disk Cache Size (% of disk)", "settings.server.diskCacheSize"),
            ("Increase Cache Size", "settings.server.diskCacheSize"),
            ("Use Automatic Cache Size", "settings.server.diskCacheAutomatic"),
            ("clear ssd cache", "server.cache"),
            ("gpu cache", "server.cache"),
            ("context window cap", "settings.chat.contextLength"),
            ("max context", "settings.chat.contextLength"),
            ("kv retention", "settings.server.kvRetention"),
            ("metadata fallback", "settings.server.contextMetadataFallback"),
            // Reasoning was unfindable by every one of its own words while
            // three real controls existed: Reasoning Parser Override, Expand
            // Thinking While Streaming, Group Thinking & Tool Activity.
            ("reasoning", "server.tools"),
            ("reasoning parser", "server.tools"),
            ("effort", "server.tools"),
            ("preserve thinking", "server.tools"),
            ("thinking", "settings.chat.thinkingDisplay"),
            // The control that makes every tool always allowed. It had no
            // entry at all, and "tool calls" matched Max Tool Attempts —
            // a wrong-destination hit, which is worse than no hit.
            ("auto allow", "tools.autoAllowAll"),
            ("allow all tools", "tools.autoAllowAll"),
            ("always allow", "tools.autoAllowAll"),
            ("approve tools", "tools.autoAllowAll"),
            ("Auto-Allow All Tool Calls", "tools.autoAllowAll"),
            ("smooth streaming", "settings.chat.smoothStreaming"),
            ("clipboard monitoring", "settings.chat.clipboard"),
            ("keep mac awake", "settings.chat.keepAwakeForAgentRuns"),
            ("pairing code", "settings.connect.pairing"),
            ("iphone", "settings.connect.pairing"),
            ("unpair", "settings.connect.pairedDevice"),
            ("keep mac awake for paired iphone", "settings.connect.keepAwake"),
            ("reach from anywhere", "settings.connect.reachAnywhere"),
            ("group thinking", "settings.chat.activityRollup"),
            ("hide dock icon", "settings.general.dock"),
            ("Show Notifications", "settings.notifications.toasts"),
            ("Max Concurrent Background Tasks", "settings.notifications.maxConcurrent"),
            ("max concurrent tasks", "settings.notifications.maxConcurrent"),
            // General: the one external-models switch + Advanced subsections.
            ("Use models already on this Mac", "storage.externalModels"),
            ("lm studio", "storage.externalModels"),
            ("Models Directory", "storage.location"),
            ("Encrypt Local Data at Rest", "storage.encryption"),
            ("Factory Reset", "settings.general.reset"),
            // Command Line Tool moved to Server → Overview.
            ("Command Line Tool", "server.cli"),
            ("install cli", "server.cli"),
            // Conversation (formerly Chat).
            ("Automatically Name Chats", "settings.chat.autoGenerateTitles"),
            ("Suggest Follow-Up Questions", "settings.chat.generateFollowUps"),
            ("Check Spelling While Typing", "settings.chat.spellCheck"),
            ("Expand Thinking While Streaming", "settings.chat.thinkingDisplay"),
            ("Compaction Model", "settings.chat.compactionModel"),
            ("Top P Override", "settings.chat.topP"),
            ("Max Tool Attempts", "settings.chat.toolAttempts"),
            // Voice: Setup / Chat Voice / Transcription / Text To Speech / Wake Word.
            ("Speech Model", "voice.stt.model"),
            ("Voice Sensitivity", "voice.setup.sensitivity"),
            ("Enable Voice Input", "voice.chat.enable"),
            ("Enable Transcription Mode", "voice.transcription.enable"),
            ("Activation Hotkey", "voice.stt.hotkey"),
            ("Clean Up Transcription", "voice.stt.cleanup"),
            ("Stop Mode", "voice.stt.stopMode"),
            ("Pause Detection", "voice.stt.pause"),
            ("Confirmation Delay", "voice.stt.confirmation"),
            ("Silence Timeout", "voice.stt.silence"),
            ("Wake Word", "voice.stt.vad"),
            ("Engine", "voice.tts.engine"),
            // Tools & MCP: Services (default) / All Tools / Plugins.
            ("Services", "tools.services"),
            ("Add Service", "tools.addService"),
            ("Add Connection", "tools.addService"),
            ("Directory", "tools.directory"),
            ("All Tools", "tools.allTools"),
            ("folder permissions", "tools.allTools"),
            // Privacy: Filter / Rules / Models.
            ("Scrub PII before sending to cloud providers", "privacy.filter.enabled"),
            ("AI detection (on-device model)", "privacy.filter.aiDetection"),
            ("Skip Code Blocks", "privacy.filter.skipCode"),
            ("Always Approve by Default", "privacy.filter.alwaysApprove"),
            ("Per-Provider", "privacy.filter.providers"),
            ("Forget Redactions in Every Conversation", "privacy.filter.forget"),
            ("Require Review for Background Requests", "privacy.filter.nonInteractive"),
            ("Detection Models", "privacy.models"),
            // Images: Defaults / Image Models.
            ("Default Models", "imageGeneration.models"),
            ("Image jobs", "imageGeneration.permission"),
            ("Video jobs (cloud)", "imageGeneration.videoPermission"),
            ("Video (cloud)", "imageGeneration.video"),
            ("Load policy", "imageGeneration.loadPolicy"),
            ("Image model load policy", "imageGeneration.loadPolicy"),
            ("enable memory", "memory.settings.enabled"),
            ("consolidation interval", "memory.settings.consolidation"),
            ("share my models", "server.peerInference"),
            ("use with codex", "server.codexCLI"),
            ("codex cli", "server.codexCLI"),
            ("schedules", "schedules.overview"),
            ("sandbox", "sandbox.overview"),
            ("macos permissions", "permissions.tools"),
            ("pair with n8n", "agentChannels.n8n.pairingCode"),
            ("pairing code", "agentChannels.n8n.pairingCode"),
            // n8n sheet rail: Name it → Where is your n8n? → Who answers? → Pair → Prove it.
            ("name it", "agentChannels.n8n"),
            ("where is your n8n", "agentChannels.n8n.callerLocation"),
            ("docker desktop on this mac", "agentChannels.n8n.callerLocation"),
            ("another machine on my network", "agentChannels.n8n.callerLocation"),
            ("remote", "agentChannels.n8n.callerLocation"),
            ("who answers", "agentChannels.n8n"),
            ("prove it", "agentChannels.n8n"),
            ("allow plaintext http from other machines", "agentChannels.n8n.plaintextAllowed"),
            ("relay for", "agentChannels.n8n.relay"),
            ("enable relay", "agentChannels.n8n.relay"),
            ("outbound webhook url", "agentChannels.n8n.outboundWebhookURL"),
            ("push replies to n8n", "agentChannels.n8n.outboundWebhookURL"),
            ("channel secret", "agentChannels.n8n.channelSecret"),
            ("who may speak", "agentChannels.n8n.pendingApprovals"),
            ("waiting for approval", "agentChannels.n8n.pendingApprovals"),
            ("allowed conversations", "agentChannels.n8n.pendingApprovals"),
            ("allowed senders", "agentChannels.n8n.pendingApprovals"),
            ("edit allowlists by hand", "agentChannels.n8n.pendingApprovals"),
            ("channel enabled", "agentChannels.n8n.enabled"),
            // Settings → Channels → Incoming.
            ("focus chat on incoming messages", "agentChannels.focusOnInbound"),
            ("bring to front", "agentChannels.focusOnInbound"),
            ("steal focus", "agentChannels.focusOnInbound"),
            // Settings → Orchestrator controls.
            ("model readiness", "settings.orchestrator.modelReadiness"),
            ("working folder", "settings.orchestrator.workingFolder"),
            ("allowed subagents", "settings.orchestrator.delegation.mainChat"),
            ("allowed agents", "settings.orchestrator.delegation.mainChat"),
            ("shared workspace agents", "settings.orchestrator.delegation.mainChat"),
            ("create starter agents", "settings.orchestrator.delegation.starterAgents"),
            ("Add all agents", "settings.orchestrator.delegation.addAllAgents"),
            ("spawn pool empty", "settings.orchestrator.delegation.addAllAgents"),
            ("permission for shared", "settings.orchestrator.delegation.permission"),
            ("max output tokens per subagent", "settings.orchestrator.delegation.limits"),
            ("max turns per subagent", "settings.orchestrator.delegation.limits"),
            ("max local subagents at once", "settings.orchestrator.delegation.limits"),
            ("max remote subagents at once", "settings.orchestrator.delegation.limits"),
            ("time limit per subagent", "settings.orchestrator.delegation.limits"),
            ("agent-target model override", "settings.orchestrator.delegation.advanced"),
            ("swap local models", "settings.orchestrator.delegation.handoff"),
            ("check memory before delegating", "settings.orchestrator.delegation.handoff"),
            ("check memory before delegating", "settings.orchestrator.delegation.ramSafety"),
            ("stable_memory_refusal", "settings.orchestrator.delegation.ramSafety"),
            ("delegations", "settings.orchestrator.delegations"),
            // Workspaces → Shared agents: the per-workspace auto-join switch.
            ("let the orchestrator delegate to shared agents", "workspaces.agents.orchestratorAutoJoin"),
            ("auto-join", "workspaces.agents.orchestratorAutoJoin"),
            // Workspaces → Shared agents: the per-agent pool-billing switch.
            ("bill the workspace pool", "workspaces.agents.billPool"),
            ("pool billing", "workspaces.agents.billPool"),
            // Agents → Abilities → Tools: the Apple Apps group row and one picker group per app,
            // by the exact title each picker group shows.
            ("apple apps", "agents.appleApps"),
            ("Calendar", "agents.appleApps.calendar"),
            ("Reminders", "agents.appleApps.reminders"),
            ("Contacts", "agents.appleApps.contacts"),
            ("Notes", "agents.appleApps.notes"),
            ("Mail", "agents.appleApps.mail"),
            ("Messages", "agents.appleApps.messages"),
            ("Maps & Location", "agents.appleApps.maps"),
            ("Music", "agents.appleApps.music"),
            ("Shortcuts", "agents.appleApps.shortcuts"),
            ("imessage", "agents.appleApps.messages"),
            ("apple_apps", "agents.appleApps"),
            ("Keep File History", "storage.fileHistory.retention"),
            ("file history retention", "storage.fileHistory.retention"),
            ("File History Size Limit", "storage.fileHistory.sizeLimit"),
        ]

        let missed = labels.filter { label in
            !SettingsSearchIndex.search(label.query).contains { $0.id == label.entryID }
        }
        .map { "\"\($0.query)\" -> \($0.entryID)" }

        #expect(missed.isEmpty, "control labels that find nothing: \(missed)")
    }

    @Test("small body search targets theme typography")
    func smallBodySearchTargetsTypographyControl() throws {
        let entry = try #require(SettingsSearchIndex.search("Small body").first)
        #expect(entry.id == "themes.typography.smallBody")
        #expect(entry.tab == .themes)
        #expect(entry.section == "Text & Fonts")
        #expect(entry.title == "Small body")
        #expect(entry.isSettingsUIOnly)
        #expect(!SettingsSearchIndex.tabLevelEntryIDs.contains(entry.id))
    }

    @Test("menu border searches land on the default border controls")
    func menuBorderSearchesTargetDefaultControls() throws {
        let controls = [
            (query: "model picker border", id: "themes.borders.color", title: "Border Color"),
            (query: "Credits border", id: "themes.borders.color", title: "Border Color"),
            (query: "model picker border width", id: "themes.borders.width", title: "Border Width"),
            (query: "Credits border opacity", id: "themes.borders.opacity", title: "Border Opacity"),
        ]
        for control in controls {
            let entry = try #require(SettingsSearchIndex.search(control.query).first)
            #expect(entry.id == control.id)
            #expect(entry.title == control.title)
            #expect(entry.tab == .themes)
            #expect(entry.section == "Borders & Effects")
            #expect(!SettingsSearchIndex.tabLevelEntryIDs.contains(entry.id))
        }
    }

    /// Guards the probe itself: an index that shrank to nothing, or a matcher
    /// that started returning everything, would pass both sweeps vacuously.
    @Test("the sweep runs against a real index and a discriminating matcher")
    func sweepIsNotVacuous() {
        #expect(SettingsSearchIndex.entries.count > 50)
        #expect(SettingsSearchIndex.search("zzzznotasetting").isEmpty)
        // The label sweep above is only meaningful if a plausible-but-absent
        // label still fails — otherwise it would pass on any index.
        #expect(SettingsSearchIndex.search("disk cache turbo mode").isEmpty)
    }
}
