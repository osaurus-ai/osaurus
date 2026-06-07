//
//  PluginDispatchToolSelectionTests.swift
//  OsaurusCoreTests
//
//  Pins the `tools: [String]` extension on `host->dispatch` end-to-end:
//  the JSON parse + scope-check transform in `parseRequestedTools`, the
//  fully-built `DispatchRequest` produced by `planDispatch`, and the
//  wiring through `BackgroundTaskManager.dispatchChat` into
//  `SessionToolStateStore` so the resolved chat sees them as additive
//  over the agent's normal tool selection.
//
//  Three layers, in order of escalation:
//    1. `PluginParseRequestedToolsTests` — pure function
//    2. `PluginPlanDispatchToolSelectionTests` — JSON -> DispatchRequest
//    3. `PluginDispatchToolStorePopulationTests` — DispatchRequest ->
//       `SessionToolStateStore` via the real `dispatchChat` call site
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - parseRequestedTools (pure function)

/// `parseRequestedTools` is the validation table: extract the optional
/// `tools` array, drop blanks / non-strings / duplicates, scope-check
/// the remainder against the allowed set, warn-once per rejected name.
/// Pure function — no MainActor, no global state aside from the
/// `PluginOnceLogger` counter we reset in each test for determinism.
@Suite(.serialized)
struct PluginParseRequestedToolsTests {

    private let pluginId = "com.test.dispatch.parse"

    private func reset() {
        // Scope reset to this suite's pluginId so parallel suites don't race.
        PluginOnceLogger._resetForTesting(forKeyPrefix: "\(pluginId)|")
    }

    @Test func acceptsAllowedNamesPreservingOrder() {
        reset()
        let json: [String: Any] = ["tools": ["b", "a", "c"]]
        let names = PluginHostContext.parseRequestedTools(
            json: json,
            pluginId: pluginId,
            allowedToolNames: ["a", "b", "c"]
        )
        #expect(names == ["b", "a", "c"], "Caller-supplied order is preserved")
    }

    @Test func collapsesDuplicates() {
        reset()
        let json: [String: Any] = ["tools": ["a", "a", "b", "a"]]
        let names = PluginHostContext.parseRequestedTools(
            json: json,
            pluginId: pluginId,
            allowedToolNames: ["a", "b"]
        )
        #expect(names == ["a", "b"], "Duplicates collapse; first occurrence wins")
    }

    @Test func dropsBlanksAndWhitespaceOnly() {
        reset()
        let json: [String: Any] = ["tools": ["", "   ", "a", "\t\n", "b"]]
        let names = PluginHostContext.parseRequestedTools(
            json: json,
            pluginId: pluginId,
            allowedToolNames: ["a", "b"]
        )
        #expect(names == ["a", "b"])
    }

    @Test func trimsWhitespaceFromAcceptedNames() {
        reset()
        let json: [String: Any] = ["tools": ["  a  ", "b\t"]]
        let names = PluginHostContext.parseRequestedTools(
            json: json,
            pluginId: pluginId,
            allowedToolNames: ["a", "b"]
        )
        #expect(names == ["a", "b"], "Trimmed forms hit the allowed set")
    }

    @Test func ignoresNonStringEntries() {
        reset()
        let json: [String: Any] = ["tools": ["a", 42, true, NSNull(), "b", ["nested"]]]
        let names = PluginHostContext.parseRequestedTools(
            json: json,
            pluginId: pluginId,
            allowedToolNames: ["a", "b"]
        )
        #expect(names == ["a", "b"], "Non-string entries are silently skipped")
    }

    @Test func dropsForeignNamesButKeepsAllowedOnes() {
        reset()
        let json: [String: Any] = ["tools": ["allowed_one", "stranger", "allowed_two"]]
        let names = PluginHostContext.parseRequestedTools(
            json: json,
            pluginId: pluginId,
            allowedToolNames: ["allowed_one", "allowed_two"]
        )
        #expect(
            names == ["allowed_one", "allowed_two"],
            "Foreign name is dropped; valid ones still flow"
        )
        // The one rejected name should have produced exactly one log entry.
        let entries = PluginOnceLogger.entries(forPlugin: pluginId)
        #expect(entries.count == 1, "Exactly one warn-once for the dropped name")
        #expect(entries.first?.message.contains("'stranger'") == true)
    }

    @Test func warnOnceDedupsRepeatedRejectionsOfSameName() {
        reset()
        // Same plugin asks for the same foreign name twice (e.g. across
        // two dispatches). Only one entry should be retained.
        let json: [String: Any] = ["tools": ["nope"]]
        _ = PluginHostContext.parseRequestedTools(
            json: json,
            pluginId: pluginId,
            allowedToolNames: ["a"]
        )
        _ = PluginHostContext.parseRequestedTools(
            json: json,
            pluginId: pluginId,
            allowedToolNames: ["a"]
        )
        let entries = PluginOnceLogger.entries(forPlugin: pluginId)
        #expect(entries.count == 1, "warn-once dedups across calls")
    }

    @Test func warnOncePerNameNotPerPlugin() {
        reset()
        // Two different rejected names should produce two distinct
        // entries — dedup is keyed on (plugin, name), not just plugin.
        let json: [String: Any] = ["tools": ["foo", "bar"]]
        _ = PluginHostContext.parseRequestedTools(
            json: json,
            pluginId: pluginId,
            allowedToolNames: []
        )
        let entries = PluginOnceLogger.entries(forPlugin: pluginId)
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.message.contains("'foo'") || $0.message.contains("'bar'") })
    }

    @Test func emptyArrayReturnsEmpty() {
        reset()
        let json: [String: Any] = ["tools": []]
        let names = PluginHostContext.parseRequestedTools(
            json: json,
            pluginId: pluginId,
            allowedToolNames: ["a", "b"]
        )
        #expect(names.isEmpty)
    }

    @Test func missingFieldReturnsEmpty() {
        reset()
        let json: [String: Any] = [:]
        let names = PluginHostContext.parseRequestedTools(
            json: json,
            pluginId: pluginId,
            allowedToolNames: ["a", "b"]
        )
        #expect(names.isEmpty)
        #expect(PluginOnceLogger.entries(forPlugin: pluginId).isEmpty)
    }

    @Test func wrongTypeFieldReturnsEmpty() {
        reset()
        // `"tools": "not_an_array"` — a malformed payload, but the
        // contract is "best-effort, never fail the dispatch".
        let json: [String: Any] = ["tools": "single_name_not_array"]
        let names = PluginHostContext.parseRequestedTools(
            json: json,
            pluginId: pluginId,
            allowedToolNames: ["single_name_not_array"]
        )
        #expect(names.isEmpty, "tools must be an array — string is silently ignored")
    }

    @Test func emptyAllowedSetDropsEverything() {
        reset()
        let json: [String: Any] = ["tools": ["a", "b"]]
        let names = PluginHostContext.parseRequestedTools(
            json: json,
            pluginId: pluginId,
            allowedToolNames: []
        )
        #expect(names.isEmpty)
        // Both names should have been warn-once'd.
        #expect(PluginOnceLogger.entries(forPlugin: pluginId).count == 2)
    }
}

// MARK: - planDispatch (JSON -> DispatchRequest)

/// `planDispatch` is the full plugin-supplied JSON transform: it parses
/// prompt + ids + session + tools, applies the host-enforced agent
/// scope, and produces the `DispatchRequest`. These tests pin the new
/// `tools` field on top of the existing prompt / agent semantics by
/// passing an explicit `allowedToolNames` set so we don't need to spin
/// up the `PluginManager` / `ToolRegistry` MainActor world.
@Suite(.serialized)
struct PluginPlanDispatchToolSelectionTests {

    private let pluginId = "com.test.dispatch.plan-tools"

    private func reset() {
        // Scope reset to this suite's pluginId so parallel suites don't race.
        PluginOnceLogger._resetForTesting(forKeyPrefix: "\(pluginId)|")
    }

    private func extractRequest(_ plan: PluginHostContext.DispatchPlan) -> DispatchRequest? {
        if case .request(let req) = plan { return req }
        return nil
    }

    @Test func requestedToolNamesPopulatedFromAllowedSet() throws {
        reset()
        let plan = PluginHostContext.planDispatch(
            requestJSON: #"{"prompt":"hi","tools":["reply","reply_typing"]}"#,
            pluginId: pluginId,
            activeAgent: UUID(),
            allowedToolNames: ["reply", "reply_typing", "reply_photo"]
        )
        let req = try #require(extractRequest(plan))
        #expect(req.requestedToolNames == ["reply", "reply_typing"])
    }

    @Test func requestedToolNamesEmptyByDefault() throws {
        // Existing call sites (no `tools` field) must continue to produce
        // an empty array — the downstream resolver is unchanged for them.
        reset()
        let plan = PluginHostContext.planDispatch(
            requestJSON: #"{"prompt":"hi"}"#,
            pluginId: pluginId,
            activeAgent: UUID()
        )
        let req = try #require(extractRequest(plan))
        #expect(req.requestedToolNames.isEmpty)
    }

    @Test func toolsAndAgentScopeAreOrthogonal() throws {
        // Tool field flows through even when the plugin also tries to
        // override `agent_address` — the two security checks live on
        // different axes and must not interact.
        reset()
        let agentX = UUID()
        let plan = PluginHostContext.planDispatch(
            requestJSON: #"""
                {"prompt":"hi","agent_address":"0xattacker","tools":["reply"]}
                """#,
            pluginId: pluginId,
            activeAgent: agentX,
            allowedToolNames: ["reply"]
        )
        let req = try #require(extractRequest(plan))
        #expect(req.agentId == agentX)
        #expect(req.requestedToolNames == ["reply"])
    }

    @Test func partialRejectionStillFlowsValidNames() throws {
        // Mix of allowed + foreign names: dispatch must still be a
        // success envelope with the valid subset attached.
        reset()
        let plan = PluginHostContext.planDispatch(
            requestJSON: #"{"prompt":"hi","tools":["reply","stranger","reply_typing"]}"#,
            pluginId: pluginId,
            activeAgent: UUID(),
            allowedToolNames: ["reply", "reply_typing"]
        )
        let req = try #require(extractRequest(plan))
        #expect(req.requestedToolNames == ["reply", "reply_typing"])
    }

    @Test func malformedToolsFieldDoesNotErrorTheDispatch() throws {
        // "tools": "not_an_array" must NOT short-circuit into an
        // `invalid_request` envelope — the dispatch proceeds with
        // an empty tool list. Pin this so a future tightening doesn't
        // accidentally start failing dispatches over a typo.
        reset()
        let plan = PluginHostContext.planDispatch(
            requestJSON: #"{"prompt":"hi","tools":"oops"}"#,
            pluginId: pluginId,
            activeAgent: UUID(),
            allowedToolNames: ["reply"]
        )
        let req = try #require(extractRequest(plan))
        #expect(req.requestedToolNames.isEmpty)
    }
}

// MARK: - dispatchChat -> SessionToolStateStore (integration)

/// End-to-end pin: a `DispatchRequest` carrying `requestedToolNames`
/// goes through `BackgroundTaskManager.dispatchChat`, and the validated
/// names land in `SessionToolStateStore` keyed by the resolved task id
/// — exactly what `composeChatContext` reads as `additionalToolNames`
/// when the dispatched chat actually runs. The third test covers
/// `appendLoadedTools`'s accumulation contract directly, which is the
/// invariant `dispatchChat` relies on for the reattach path.
@Suite(.serialized)
@MainActor
struct PluginDispatchToolStorePopulationTests {

    /// Recognizably-fake plugin id. The built-in Default agent is now
    /// locked to in-app surfaces (see `Agent.rejectBuiltInForExternalSurface`),
    /// so plugin dispatch tests have to wire up their own throwaway agent
    /// — using `Agent.defaultId` here would land in a 403 envelope rather
    /// than the `DispatchRequest` path we're trying to pin.
    private let pluginId = "com.test.dispatch.tool-store"

    private func reset() async {
        await SessionToolStateStore.shared.reset()
        PluginOnceLogger._resetForTesting(forKeyPrefix: "\(pluginId)|")
    }

    /// Run `body` against a throwaway storage root so any agent created via
    /// `makeScopedAgent` lands in a temp dir (never the live
    /// `~/.osaurus/agents` store) and is removed with it. Serialized through
    /// `SandboxTestLock.runWithStoragePaths` because it mutates
    /// `OsaurusPaths.overrideRoot` and `AgentManager.shared` — globals other
    /// suites also touch.
    private func withIsolatedRoot(_ body: @MainActor @Sendable () async throws -> Void) async throws {
        try await SandboxTestLock.runWithStoragePaths {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osaurus-plugin-dispatch-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let previousRoot = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = root
            AgentManager.shared.refresh()
            defer {
                OsaurusPaths.overrideRoot = previousRoot
                AgentManager.shared.refresh()
                try? FileManager.default.removeItem(at: root)
            }
            try await body()
        }
    }

    /// Spin up a throwaway custom agent for a single dispatch. Tests run
    /// inside `withIsolatedRoot`, so the agent persists into a temp storage
    /// root and is torn down with the directory — no explicit delete needed.
    private func makeScopedAgent() -> UUID {
        let agent = Agent(
            name: "PluginDispatchToolStoreAgent-\(UUID().uuidString.prefix(6))",
            systemPrompt: "Test identity",
            agentAddress: "test-plugin-dispatch-\(UUID().uuidString)"
        )
        AgentManager.shared.add(agent)
        return agent.id
    }

    /// Dispatch a request and return the resolved task id. Caller is
    /// responsible for cleanup via `mgr.finalizeTask(...)` plus the
    /// `cleanup` closure returned alongside the task id.
    private func dispatch(
        agentId: UUID,
        prompt: String,
        requestedToolNames: [String]
    ) async -> UUID? {
        let request = DispatchRequest(
            prompt: prompt,
            agentId: agentId,
            sourcePluginId: pluginId,
            source: .plugin,
            requestedToolNames: requestedToolNames
        )
        let handle = await BackgroundTaskManager.shared.dispatchChat(request)
        return handle?.id
    }

    @Test
    func nonEmptyRequestedToolsLandInSessionStore() async throws {
        try await withIsolatedRoot {
            await self.reset()
            let mgr = BackgroundTaskManager.shared
            let agentId = self.makeScopedAgent()

            let taskId = try #require(
                await self.dispatch(
                    agentId: agentId,
                    prompt: "hello",
                    requestedToolNames: ["share_artifact"]
                )
            )

            let names = await SessionToolStateStore.shared.get(taskId.uuidString)?.loadedToolNames ?? []
            #expect(
                names.contains("share_artifact"),
                "appendLoadedTools must use the dispatch task id as the store key"
            )

            mgr.finalizeTask(taskId)
        }
    }

    @Test
    func emptyRequestedToolsLeavesStoreUntouched() async throws {
        // Whatever `composeChatContext` may have created via `setInitial`,
        // an empty `requestedToolNames` must not seed `loadedToolNames`.
        try await withIsolatedRoot {
            await self.reset()
            let mgr = BackgroundTaskManager.shared
            let agentId = self.makeScopedAgent()

            let taskId = try #require(
                await self.dispatch(
                    agentId: agentId,
                    prompt: "hello",
                    requestedToolNames: []
                )
            )

            let names = await SessionToolStateStore.shared.get(taskId.uuidString)?.loadedToolNames ?? []
            #expect(names.isEmpty, "Empty requestedToolNames must not seed loadedToolNames")

            mgr.finalizeTask(taskId)
        }
    }

    @Test
    func appendLoadedToolsAccumulatesAcrossCalls() async {
        // Reattach in `dispatchChat` reuses `existing.id` as `context.id`,
        // so two successive appends against the same id are exactly what
        // the reattach path emits. We pin the underlying accumulation
        // property here rather than the reattach plumbing because the
        // latter requires a persisted, non-active session — i.e. a
        // model-driven first turn, which the test env can't run.
        await reset()
        let id = UUID()
        await SessionToolStateStore.shared.appendLoadedTools(
            id.uuidString,
            names: ["share_artifact"],
            fallbackAlwaysLoadedNames: nil
        )
        await SessionToolStateStore.shared.appendLoadedTools(
            id.uuidString,
            names: ["search_memory"],
            fallbackAlwaysLoadedNames: nil
        )
        let names = await SessionToolStateStore.shared.get(id.uuidString)?.loadedToolNames ?? []
        #expect(names.contains("share_artifact"))
        #expect(names.contains("search_memory"))
    }
}
