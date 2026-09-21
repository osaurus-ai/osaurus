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
            ("auto allow", "settings.chat.autoAllowAllTools"),
            ("allow all tools", "settings.chat.autoAllowAllTools"),
            ("always allow", "settings.chat.autoAllowAllTools"),
            ("approve tools", "settings.chat.autoAllowAllTools"),
            ("smooth streaming", "settings.chat.smoothStreaming"),
            ("clipboard monitoring", "settings.chat.clipboard"),
            ("keep mac awake", "settings.chat.keepAwakeForAgentRuns"),
            ("group thinking", "settings.chat.activityRollup"),
            ("hide dock icon", "settings.general.dock"),
            ("max visible toasts", "settings.notifications.maxVisible"),
            ("max concurrent tasks", "settings.notifications.maxConcurrent"),
            ("enable memory", "memory.settings.enabled"),
            ("consolidation interval", "memory.settings.consolidation"),
            ("share my models", "server.peerInference"),
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
            // Settings → Orchestrator controls.
            ("model readiness", "settings.orchestrator.modelReadiness"),
            ("working folder", "settings.orchestrator.workingFolder"),
            ("allowed subagents", "settings.orchestrator.delegation.mainChat"),
            ("allowed agents", "settings.orchestrator.delegation.mainChat"),
            ("shared workspace agents", "settings.orchestrator.delegation.mainChat"),
            ("create starter agents", "settings.orchestrator.delegation.starterAgents"),
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
        ]

        let missed = labels.filter { label in
            !SettingsSearchIndex.search(label.query).contains { $0.id == label.entryID }
        }
        .map { "\"\($0.query)\" -> \($0.entryID)" }

        #expect(missed.isEmpty, "control labels that find nothing: \(missed)")
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
