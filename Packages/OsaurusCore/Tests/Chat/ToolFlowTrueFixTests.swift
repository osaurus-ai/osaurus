//
//  ToolFlowTrueFixTests.swift
//  osaurusTests
//
//  Four defects from the 2026-09-04 tool-flow audit, each pinned by the
//  failure a user saw:
//   1. "still indexing — retry" was a SUCCESS envelope, so the read-like
//      replay (#2632) served it verbatim on the retry and the finished index
//      was never seen.
//   2. Context compression collapsed a capped search page to "N file
//      match(es)", dropping total/next_offset/truncated — turns later the
//      model restated the page size as the whole folder.
//   3. Every newly registered tool was appended to every agent's manual
//      list, including agents in MANUAL mode.
//   4. Duplicate Agent dropped the capability configuration, so a manual
//      agent's copy ran AUTO with the whole registry.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct ToolFlowTrueFixTests {

    // MARK: 1. still-indexing is transient, never replayed

    @Test func stillIndexingIsARetryableFailureThatIsNotReplayed() {
        let envelope = KnowledgeToolScope.stillIndexingEnvelope(
            tool: "search_knowledge",
            message: "No matches for 'budget' yet — this collection is still indexing. Retry in a moment.")
        let object = try? JSONSerialization.jsonObject(with: Data(envelope.utf8)) as? [String: Any]
        #expect(object?["ok"] as? Bool == false)
        #expect(object?["kind"] as? String == "unavailable")
        #expect(object?["retryable"] as? Bool == true)
        #expect((object?["message"] as? String)?.contains("Retry in a moment") == true)

        let state = AgentTaskState()
        state.beginMessage()
        let args = #"{"query":"budget"}"#
        state.record(name: "search_knowledge", argsJSON: args, result: envelope)
        #expect(state.heldResult(name: "search_knowledge", argsJSON: args) == nil,
            "the retry must execute the tool again, not replay 'still indexing'")

        // Control: a real success IS still deduped (the #2632 behaviour we keep).
        let real = ToolEnvelope.success(tool: "search_knowledge", text: "Found 2 knowledge excerpt(s)")
        state.record(name: "search_knowledge", argsJSON: #"{"query":"roadmap"}"#, result: real)
        #expect(state.heldResult(name: "search_knowledge", argsJSON: #"{"query":"roadmap"}"#) == real)

        // And the same for list_knowledge, the other site that emits it.
        let listing = KnowledgeToolScope.stillIndexingEnvelope(
            tool: "list_knowledge", message: "No knowledge documents listed yet — still indexing. Retry in a moment.")
        state.record(name: "list_knowledge", argsJSON: "{}", result: listing)
        #expect(state.heldResult(name: "list_knowledge", argsJSON: "{}") == nil)
    }

    // MARK: 2. compression keeps the paging signal

    /// Builds a `kind:"search"` envelope with the paging keys #2646 adds
    /// (`total` / `offset` / `next_offset`); on main `ToolEnvelope.search`
    /// does not take them yet, so the payload is assembled directly.
    private func searchEnvelope(
        query: String, entries: [[String: Any]], truncated: Bool,
        total: Int? = nil, nextOffset: Int? = nil
    ) -> String {
        var result: [String: Any] = [
            "kind": "search", "query": query, "entries": entries,
            "match_count": entries.count, "truncated": truncated,
        ]
        if let total { result["total"] = total; result["offset"] = 0 }
        if let nextOffset { result["next_offset"] = nextOffset }
        return ToolEnvelope.success(tool: "file_search", result: result)
    }

    @Test func compressedSearchPageKeepsTotalAndNextOffset() {
        let entries = (0..<50).map { ["name": "n\($0).md", "path": "n\($0).md", "type": "file"] }
        let paged = searchEnvelope(query: "*", entries: entries, truncated: false, total: 350, nextOffset: 50)
        let summary = ContextBudgetManager.summarizeToolResult(paged, toolCallId: nil)
        #expect(summary.contains("50 file match(es)"))
        #expect(summary.contains("page of 350 total"))
        #expect(summary.contains("next_offset 50"))
        #expect(!summary.contains("n7.md"), "entries must not survive compression")

        let complete = searchEnvelope(query: "config", entries: Array(entries.prefix(3)), truncated: false, total: 3)
        let completeSummary = ContextBudgetManager.summarizeToolResult(complete, toolCallId: nil)
        #expect(completeSummary.contains("3 file match(es)"))
        #expect(!completeSummary.contains("total"), "a complete set carries no paging note")

        let budgetCut = searchEnvelope(query: "*", entries: entries, truncated: true)
        #expect(ContextBudgetManager.summarizeToolResult(budgetCut, toolCallId: nil).contains("truncated"))

        // Content-mode text result: the truncation trailer survives.
        let text = "Found 50 match(es):\n\n" + String(repeating: "a.txt:1: match line\n", count: 50)
            + "\n(Results truncated at 50.)"
        let textSummary = ContextBudgetManager.summarizeToolResult(text, toolCallId: nil)
        #expect(textSummary.contains("Found 50 match(es)"))
        #expect(textSummary.contains("truncated at 50"))
    }

    // MARK: 3. manual lists never auto-grow

    @MainActor
    @Test func manualAgentsDoNotGrowWhenToolsRegister() {
        let live: Set<String> = ["gmail.send", "gmail.list", "shell_run"]
        #expect(AgentManager.grownManualToolNames(current: ["shell_run"], mode: .manual, live: live) == nil)
        #expect(AgentManager.grownManualToolNames(current: [], mode: .manual, live: live) == nil)
        // Auto (seeded picker) keeps growing, deterministically ordered.
        #expect(AgentManager.grownManualToolNames(current: ["shell_run"], mode: .auto, live: live)
            == ["shell_run", "gmail.list", "gmail.send"])
        #expect(AgentManager.grownManualToolNames(current: ["shell_run"], mode: nil, live: live)
            == ["shell_run", "gmail.list", "gmail.send"])
        // Nothing new → nil (no save, no notification).
        #expect(AgentManager.grownManualToolNames(current: ["gmail.send", "gmail.list", "shell_run"], mode: .auto, live: live) == nil)
        // Never seeded → nothing to grow.
        #expect(AgentManager.grownManualToolNames(current: nil, mode: .auto, live: live) == nil)
    }

    // MARK: 4. duplicate keeps the capability configuration

    @MainActor
    @Test func duplicateCopiesToolModeGrantsAndToggles() {
        var settings = AgentSettings.defaultDisabled
        settings.webSearchEnabled = true
        let original = Agent(
            name: "Curated",
            systemPrompt: "You only use what I ticked.",
            toolSelectionMode: .manual,
            manualToolNames: ["gmail.send"],
            toolsEnabled: true,
            memoryEnabled: false,
            settings: settings
        )
        let copy = AgentManager.duplicateRecord(from: original, name: "Curated Copy")
        #expect(copy.id != original.id)
        #expect(copy.name == "Curated Copy")
        #expect(copy.toolSelectionMode == .manual)
        #expect(copy.manualToolNames == ["gmail.send"])
        #expect(copy.toolsEnabled == true)
        #expect(copy.memoryEnabled == false)
        #expect(copy.settings == original.settings)
        #expect(copy.systemPrompt == original.systemPrompt)
    }

    // MARK: 5. grant toggles hold in MANUAL mode; ticked picks survive

    @MainActor
    @Test func manualModeHonoursWebSearchOffAndKeepsTickedPicks() {
        let off = AgentConfigSnapshot(
            agentId: UUID(), toolsDisabled: false, memoryDisabled: true, autonomousConfig: nil,
            toolMode: .manual, model: nil, manualToolNames: [], systemPrompt: "",
            dbEnabled: false, renderChartEnabled: false, webSearchEnabled: false)
        let names = Set(SystemPromptComposer.resolveTools(snapshot: off, executionMode: .none).map(\.function.name))
        #expect(!names.contains("web_search"), "Web Search OFF must strip web_search in manual mode too")
        #expect(!names.contains("search_and_extract"))
        #expect(!names.contains("render_chart"))

        // A ticked built-in is an explicit pick and survives the grant strip.
        let ticked = AgentConfigSnapshot(
            agentId: UUID(), toolsDisabled: false, memoryDisabled: true, autonomousConfig: nil,
            toolMode: .manual, model: nil, manualToolNames: ["render_chart"], systemPrompt: "",
            dbEnabled: false, renderChartEnabled: false, webSearchEnabled: false)
        let tickedNames = Set(SystemPromptComposer.resolveTools(snapshot: ticked, executionMode: .none).map(\.function.name))
        #expect(tickedNames.contains("render_chart"))
        #expect(!tickedNames.contains("web_search"))

        // Web Search ON in manual keeps the web tools (no over-stripping).
        let on = AgentConfigSnapshot(
            agentId: UUID(), toolsDisabled: false, memoryDisabled: true, autonomousConfig: nil,
            toolMode: .manual, model: nil, manualToolNames: [], systemPrompt: "",
            dbEnabled: false, renderChartEnabled: false, webSearchEnabled: true)
        #expect(Set(SystemPromptComposer.resolveTools(snapshot: on, executionMode: .none).map(\.function.name)).contains("web_search"))
    }

    // MARK: 6. the Orchestrator's ticked tools are sent

    @MainActor
    @Test func orchestratorManualPicksReachItsSchema() {
        // A registered dynamic tool the orchestrator allowlist does not carry.
        let dynamicName = ToolRegistry.shared.listDynamicTools()
            .map(\.name)
            .first(where: { !ToolRegistry.orchestratorAllowedToolNames.contains($0) && !ToolRegistry.orchestratorExcludedToolNames.contains($0) })
        guard let dynamicName else { return }  // no dynamic tools registered in this test process
        let auto = AgentConfigSnapshot(
            agentId: Agent.defaultId, toolsDisabled: false, memoryDisabled: true, autonomousConfig: nil,
            toolMode: .auto, model: nil, manualToolNames: nil, systemPrompt: "", dbEnabled: false)
        #expect(!Set(SystemPromptComposer.resolveTools(snapshot: auto, executionMode: .none).map(\.function.name)).contains(dynamicName))
        let manual = AgentConfigSnapshot(
            agentId: Agent.defaultId, toolsDisabled: false, memoryDisabled: true, autonomousConfig: nil,
            toolMode: .manual, model: nil, manualToolNames: [dynamicName], systemPrompt: "", dbEnabled: false)
        #expect(Set(SystemPromptComposer.resolveTools(snapshot: manual, executionMode: .none).map(\.function.name)).contains(dynamicName),
            "a tool ticked for the Orchestrator in manual mode must be in its schema")
    }

    // MARK: 7. capabilities search says it is a top-k

    @Test func capabilitiesSearchHeaderIsNotACensus() {
        let one = CapabilitiesDiscoverTool.searchResultHeader(count: 5, queryCount: 1)
        #expect(one.hasPrefix("Found 5 capability(ies)"))
        #expect(one.contains("top 5 tools"))
        #expect(one.contains("not a full inventory"))
        #expect(CapabilitiesDiscoverTool.searchResultHeader(count: 9, queryCount: 3).contains("3 queries merged"))
    }

    // MARK: 8. search_and_extract names the URLs it did not fetch

    @Test func directURLsPastFiveAreReportedNotDropped() {
        let urls = (1...7).map { "https://example.com/p\($0)" } + ["https://example.com/p1"]
        let bounded = SearchAndExtractTool.boundedDirectURLs(urls)
        #expect(bounded.kept.count == 5)
        #expect(bounded.dropped == ["https://example.com/p6", "https://example.com/p7"])
        #expect(SearchAndExtractTool.droppedURLsWarning(bounded.dropped).contains("2 not fetched"))
        #expect(SearchAndExtractTool.boundedDirectURLs(["https://a", "https://a"]).dropped.isEmpty)
    }

    // MARK: 9. the sampler readout describes the user's turn, not the follow-ups

    @Test func samplerReadoutIgnoresAuxiliaryGenerations() {
        let followUps = GenerationParameters(
            temperature: 0.4, maxTokens: 256, maxTokensExplicit: true, auxiliaryCacheIntent: true)
        let userTurn = GenerationParameters(temperature: nil, maxTokens: 256, maxTokensExplicit: false)
        #expect(!MLXBatchAdapter.shouldRecordAsLastEffectiveGeneration(followUps))
        #expect(MLXBatchAdapter.shouldRecordAsLastEffectiveGeneration(userTurn))
    }

    // MARK: 10. list_knowledge paging survives compression; invented fetch names with a provider suffix are steered

    @Test func compressedKnowledgeListingKeepsNextOffset() {
        let body = (0..<100).map { "- note-\($0).md — title \($0)" }.joined(separator: "\n")
        let text = "Found 350 knowledge document(s) in total; showing 1–100 (offset 0):\n\n" + body
            + "\n\n[total=350, returned=100, next_offset=100 — 250 more document(s). Call list_knowledge again with `offset: 100` (and the same `limit`/filters) to continue, or narrow with `type`, `tag`, or `collection`.]"
        let envelope = ToolEnvelope.success(tool: "list_knowledge", text: text)
        let summary = ContextBudgetManager.summarizeToolResult(envelope, toolCallId: nil)
        #expect(summary.contains("in total"))
        #expect(summary.contains("next_offset=100"))
        #expect(!summary.contains("note-57.md"))
        // A complete listing carries no trailer.
        let complete = ToolEnvelope.success(tool: "list_knowledge", text: "Found 3 knowledge document(s):\n\n" + String(repeating: "- a.md — t\n", count: 40))
        #expect(!ContextBudgetManager.summarizeToolResult(complete, toolCallId: nil).contains("next_offset"))
    }

    @MainActor
    @Test func providerSuffixedFetchNamesAreRecognised() {
        for name in ["web_fetch_exa", "WebFetch_Tavily", "fetch_url_firecrawl", "exa_fetch", "web_fetch"] {
            #expect(ToolRegistry.isHallucinatedFetchToolName(name), Comment(rawValue: name))
        }
        for name in ["search_and_extract", "file_read", "browse", "open_url", "curl", "prefetch_cache"] {
            #expect(!ToolRegistry.isHallucinatedFetchToolName(name), Comment(rawValue: name))
        }
    }

    // MARK: 11. a held inspect rejection is dropped once configuration is written

    @Test func heldInspectRejectionIsInvalidatedByAConfigWrite() {
        let state = AgentTaskState()
        state.beginMessage()
        let args = #"{"action":"describe","scope":"agents","id":"Todoist"}"#
        let missing = ToolEnvelope.failure(
            kind: .invalidArgs,
            message: "No `agents` matched `Todoist` (by id or exact name).", field: "id", tool: "osaurus_inspect")
        state.record(name: "osaurus_inspect", argsJSON: args, result: missing)
        // Deterministic rejection: held and replayed while nothing changed.
        #expect(state.heldResult(name: "osaurus_inspect", argsJSON: args) == missing)
        // osaurus_config apply creates the agent → the identical read must re-execute.
        state.record(
            name: "osaurus_config", argsJSON: #"{"action":"apply","yaml":"agents:\n  Todoist: {}"}"#,
            result: ToolEnvelope.success(tool: "osaurus_config", text: "Applied 1 change."))
        #expect(state.heldResult(name: "osaurus_inspect", argsJSON: args) == nil,
            "a configuration write must invalidate the held inspect rejection")
        // A FAILED write changes nothing and keeps the hold.
        state.record(name: "osaurus_inspect", argsJSON: args, result: missing)
        state.record(
            name: "osaurus_config", argsJSON: #"{"action":"apply","yaml":"bad"}"#,
            result: ToolEnvelope.failure(kind: .invalidArgs, message: "bad yaml", tool: "osaurus_config"))
        #expect(state.heldResult(name: "osaurus_inspect", argsJSON: args) == missing)
    }
    /// Ornith (build-10 OBSIDIAN run): a stdio MCP document carrying `auth: none`
    /// is rejected by the planner before anything is written, and the identical
    /// document was re-executed nine times. A pre-execution validation
    /// rejection of `osaurus_config` is a pure function of the call, so it is
    /// held and replayed like an inspect rejection; a successful write drops
    /// it (later validation may depend on the new state); an execution error
    /// is never held.
    @Test func heldConfigValidationRejectionIsReplayedUntilAWriteSucceeds() {
        let state = AgentTaskState()
        state.beginMessage()
        let args = #"{"action":"apply","yaml":"mcp:\n  obsidian:\n    transport: stdio\n    auth: none"}"#
        let rejected = ToolEnvelope.failure(
            kind: .invalidArgs,
            message: "`url`, `auth` and `token_ref` apply to the http transport only.", field: "auth",
            tool: "osaurus_config")
        state.record(name: "osaurus_config", argsJSON: args, result: rejected)
        #expect(state.heldResult(name: "osaurus_config", argsJSON: args) == rejected)
        // A different, successful write changes the state → the hold is dropped.
        state.record(
            name: "osaurus_config", argsJSON: #"{"action":"apply","yaml":"mcp:\n  obsidian:\n    transport: stdio"}"#,
            result: ToolEnvelope.success(tool: "osaurus_config", text: "Applied 1 change."))
        #expect(state.heldResult(name: "osaurus_config", argsJSON: args) == nil)
        // An execution error (approval timed out, write failed) is not deterministic and is not held.
        let failed = ToolEnvelope.failure(kind: .executionError, message: "approval timed out", tool: "osaurus_config")
        state.record(name: "osaurus_config", argsJSON: args, result: failed)
        #expect(state.heldResult(name: "osaurus_config", argsJSON: args) == nil)
    }

    /// Ornith (build-10 RESEARCH run) ended two turns with `stop`, no call, on a
    /// status line whose CLOSING SENTENCE announced the next fetch. The line
    /// rule only looked at the line's first words. The closing-sentence rule
    /// catches the first-person action phrase; a sign-off ("Let me know …")
    /// and an ordinary answer stay final.
    @Test func closingSentenceAnnouncementIsNotAFinalAnswer() {
        func classify(_ text: String) -> AgentLoopModelStep {
            AgentLoopModelStep.classifyTerminal(
                contentIsBlank: false, thinkingIsBlank: true, stopReason: "stop",
                requiresVisibleFinalResponse: true, toolsWereOffered: true, content: text)
        }
        let ornith1 = "The Wellkr site blocks retrieval. Let me try the Verywell Health iron-supplements article and the Quantum Cacao source for mechanism details."
        guard case .announcedToolCall = classify(ornith1) else {
            Issue.record("a closing 'Let me try …' sentence announces a call that was never emitted"); return
        }
        guard case .finalResponse = classify("Iron absorption is reduced by cocoa polyphenols. Let me know if you want the sources.") else {
            Issue.record("'Let me know' is a sign-off, not an announced call"); return
        }
        guard case .finalResponse = classify("Here is the summary you asked for. It covers absorption and dosage.") else {
            Issue.record("an ordinary two-sentence answer is final"); return
        }
        // Documented gap: "Now the Quantum Cacao source …" has no first-person
        // action opener and remains a final answer.
        guard case .finalResponse = classify("Now the Quantum Cacao source for the mechanism details on cocoa polyphenols.") else {
            Issue.record("unchanged: no first-person opener"); return
        }
    }
}
