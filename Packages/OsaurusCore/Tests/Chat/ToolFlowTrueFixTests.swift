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
}
