//
//  SandboxExecuteCodeBridgeTests.swift
//  osaurusTests
//
//  Pins the security-critical surface of the `sandbox_execute_code`
//  bridge dispatcher:
//
//    - The allow-list of tools a Python script can reach via the bridge
//      is hard-coded (not derived from the live registry), and excludes
//      every tool whose post-execute UI hook only fires for top-level
//      tool calls (`share_artifact`, `todo`, etc.) plus the launcher
//      itself (`sandbox_execute_code`) and the init-pending placeholder.
//
//    - The per-script tool-call budget enforces both the cap (50 calls)
//      and the "script must be tracked" precondition, so a stale or
//      forged `X-Osaurus-Script-Id` header can't smuggle tool dispatches
//      through the bridge.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct SandboxExecuteCodeBridgeTests {

    // MARK: - Allow-list shape

    @Test
    func allowList_containsExpectedFileAndExecTools() {
        let required: Set<String> = [
            "sandbox_read_file",
            "sandbox_write_file",
            "sandbox_edit_file",
            "sandbox_search_files",
            "sandbox_exec",
            "sandbox_process",
            "sandbox_install",
            "sandbox_pip_install",
            "sandbox_npm_install",
        ]
        for name in required {
            #expect(
                BuiltinSandboxTools.executeCodeBridgeAllowedTools.contains(name),
                "`\(name)` must be exposed to sandbox_execute_code helpers"
            )
        }
    }

    /// Tools whose post-execute UI hook only fires for top-level tool
    /// calls — calling them from inside a script would silently no-op
    /// the chat surfacing. Pinned out explicitly so a future refactor
    /// can't accidentally re-add them via a wider allow-list.
    @Test
    func allowList_excludesChatLayerInterceptedTools() {
        let mustBeExcluded: [String] = [
            "share_artifact",
            "todo",
            "complete",
            "clarify",
            "speak",
            "sandbox_secret_set",
            "sandbox_plugin_register",
            "render_chart",
        ]
        for name in mustBeExcluded {
            #expect(
                !BuiltinSandboxTools.executeCodeBridgeAllowedTools.contains(name),
                "`\(name)` MUST NOT be reachable from sandbox_execute_code — its UI hook only fires for top-level tool calls."
            )
        }
    }

    /// Recursion guard: a Python script must not be able to relaunch
    /// `sandbox_execute_code` via the bridge. The per-turn limiter would
    /// bound the damage but the right place to reject is before dispatch.
    @Test
    func allowList_excludesExecuteCodeAndInitPlaceholder() {
        let allowed = BuiltinSandboxTools.executeCodeBridgeAllowedTools
        #expect(!allowed.contains("sandbox_execute_code"))
        #expect(!allowed.contains(BuiltinSandboxTools.initPendingToolName))
    }

    // MARK: - Per-script budget

    @Test
    func budget_rejectsCallsForUntrackedScriptId() async {
        // A stale or forged script id cannot drive bridge calls — the
        // budget actor returns `false` on every increment until the
        // script has been `start(...)`-ed.
        let budget = SandboxExecuteCodeBudget()
        let unknownId = UUID().uuidString
        #expect(await budget.tryIncrement(scriptId: unknownId) == false)
        #expect(await budget.callCount(scriptId: unknownId) == 0)
        #expect(await budget.context(scriptId: unknownId) == nil)
    }

    @Test
    func budget_tracksCallsUpToCap() async {
        let (budget, scriptId) = await Self.startedBudget()

        for _ in 0 ..< SandboxExecuteCodeBudget.maxCallsPerScript {
            #expect(await budget.tryIncrement(scriptId: scriptId) == true)
        }
        // 51st call exceeds the cap.
        #expect(await budget.tryIncrement(scriptId: scriptId) == false)
        #expect(
            await budget.callCount(scriptId: scriptId)
                == SandboxExecuteCodeBudget.maxCallsPerScript
        )
    }

    @Test
    func budget_finishMakesFurtherCallsRejected() async {
        let (budget, scriptId) = await Self.startedBudget()
        #expect(await budget.tryIncrement(scriptId: scriptId) == true)

        await budget.finish(scriptId: scriptId)
        // After finish, the budget no longer tracks this id — calls
        // should be rejected just like an unknown id.
        #expect(await budget.tryIncrement(scriptId: scriptId) == false)
        #expect(await budget.callCount(scriptId: scriptId) == 0)
    }

    @Test
    func budget_capturesScriptContext() async {
        // The bridge handler reads back the chat-engine task locals so
        // dispatched tools see the same session as the launching call.
        let budget = SandboxExecuteCodeBudget()
        let scriptId = UUID().uuidString
        let agentId = UUID()
        let assistantTurnId = UUID()
        let batchId = UUID()
        let context = SandboxExecuteCodeBudget.ScriptContext(
            agentId: agentId,
            sessionId: "session-abc",
            assistantTurnId: assistantTurnId,
            batchId: batchId
        )
        await budget.start(scriptId: scriptId, context: context)

        let captured = await budget.context(scriptId: scriptId)
        #expect(captured?.agentId == agentId)
        #expect(captured?.sessionId == "session-abc")
        #expect(captured?.assistantTurnId == assistantTurnId)
        #expect(captured?.batchId == batchId)
    }

    // MARK: - Helpers

    /// Spin up a fresh budget actor with a started, blank-context script
    /// id ready to charge against. Use when the test only cares about
    /// the increment / cap / finish behaviour, not the context payload.
    private static func startedBudget() async -> (SandboxExecuteCodeBudget, String) {
        let budget = SandboxExecuteCodeBudget()
        let scriptId = UUID().uuidString
        await budget.start(scriptId: scriptId, context: .blank)
        return (budget, scriptId)
    }
}

extension SandboxExecuteCodeBudget.ScriptContext {
    /// Test-only: a context with every field nil. Real call sites always
    /// fill these in from the chat engine's task locals.
    fileprivate static let blank = SandboxExecuteCodeBudget.ScriptContext(
        agentId: nil,
        sessionId: nil,
        assistantTurnId: nil,
        batchId: nil
    )
}
