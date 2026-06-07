//
//  SystemPromptDefaultIdentityTests.swift
//
//  Regression: the unconditional `platformIdentity` and `defaultPersona`
//  blocks in `SystemPromptTemplates` must NOT name any chat-layer-intercepted
//  tools (`todo`, `complete`, `share_artifact`, `clarify`, `capabilities_discover`)
//  or sandbox / folder tools. Naming them in the always-on system prompt
//  caused MiniMax M2.7 Small JANGTQ (and other low-bit MoE models) to fall
//  into a recitation loop on chats where those tools weren't actually in
//  the request's `tools[]` array — the model saw the names in the system
//  prompt, expected the schema to back them, found a mismatch, and
//  degenerated into emitting tool-spec text from its training distribution
//  (live-confirmed 2026-04-25).
//
//  The how-to lives in the gated `agentLoopGuidance` /
//  `capabilityDiscoveryNudge` / sandbox / folder blocks, which fire ONLY
//  when the corresponding tool is actually resolved into the schema.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("SystemPromptTemplates platform + persona tool-name leak guard")
struct SystemPromptDefaultIdentityTests {

    /// The set of tool names that MUST NOT appear in the always-on
    /// platform / persona blocks. Each one has a separately-gated guidance
    /// block that only fires when the tool is actually in the resolved schema.
    private static let leakedToolNames: [String] = [
        "todo",
        "complete",
        "clarify",
        "share_artifact",
        "capabilities_discover",
        "capabilities_load",
        "sandbox_read_file",
        "sandbox_edit_file",
        "sandbox_write_file",
        "sandbox_search_files",
        "sandbox_exec",
        "sandbox_process",
        "sandbox_install",
        "file_tree",
        "file_search",
        "file_read",
        "file_edit",
        "file_write",
        "render_chart",
        "search_memory",
    ]

    @Test("platformIdentity does not name any tool")
    func platformIdentityDoesNotLeakToolNames() {
        let identity = SystemPromptTemplates.platformIdentity
        for name in Self.leakedToolNames {
            #expect(
                !identity.contains(name),
                "platformIdentity must not mention `\(name)` — it's emitted unconditionally on every chat."
            )
        }
    }

    @Test("defaultPersona does not name any chat-layer or sandbox tool")
    func defaultPersonaDoesNotLeakToolNames() {
        let persona = SystemPromptTemplates.defaultPersona
        for name in Self.leakedToolNames {
            #expect(
                !persona.contains(name),
                "defaultPersona must not mention `\(name)` — leaked tool names cause low-bit MoE models (MiniMax M2.7 Small JANGTQ) to recite tool-spec text in a loop when the tool isn't in the request's tools[] array. Move the mention into the gated agentLoopGuidance / capabilityDiscoveryNudge / sandbox / folderContext block."
            )
        }
    }

    /// Empty / whitespace base prompt → falls back to defaultPersona.
    /// Same leak guard applies after the fallback path.
    @Test("effectivePersona('') falls back to defaultPersona and stays clean")
    func emptyBasePromptStaysClean() {
        let resolved = SystemPromptTemplates.effectivePersona("")
        for name in Self.leakedToolNames {
            #expect(
                !resolved.contains(name),
                "effectivePersona('') leaked `\(name)` via the defaultPersona fallback"
            )
        }
    }

    @Test("effectivePersona(whitespace) also stays clean")
    func whitespaceBasePromptStaysClean() {
        let resolved = SystemPromptTemplates.effectivePersona("   \n\t  ")
        for name in Self.leakedToolNames {
            #expect(!resolved.contains(name))
        }
    }

    /// User-customised persona is passed through verbatim — we do NOT
    /// scrub their content. This test confirms the `?:` semantic in
    /// `effectivePersona` so a future refactor doesn't accidentally
    /// auto-strip user content.
    @Test("user-supplied persona is passed through unchanged")
    func userBasePromptIsRespected() {
        let userPrompt = "I am a custom assistant. Use `my_special_tool` always."
        let resolved = SystemPromptTemplates.effectivePersona(userPrompt)
        #expect(resolved == userPrompt)
    }

    /// Sanity: the gated `agentLoopGuidance` block IS allowed to mention
    /// the four chat-layer-intercepted tool names, since it only fires
    /// when those tools are present in the resolved schema. This test
    /// guards against a future "clean everything" refactor that strips
    /// the names from EVERYWHERE — that would break the actual
    /// agent-loop UX.
    @Test("agentLoopGuidance still names todo / complete / clarify / share_artifact")
    func agentLoopGuidanceStillCarriesTheNames() {
        let block = SystemPromptTemplates.agentLoopGuidance
        #expect(block.contains("todo"))
        #expect(block.contains("complete"))
        #expect(block.contains("clarify"))
        #expect(block.contains("share_artifact"))
    }

    /// Same sanity for the capability-discovery nudge — still names
    /// `capabilities_discover` / `capabilities_load` because that block is
    /// gated on `capabilities_discover` actually being in the tools[] array.
    @Test("capabilityDiscoveryNudge still names capabilities_discover / capabilities_load")
    func capabilityNudgeStillCarriesTheNames() {
        let block = SystemPromptTemplates.capabilityDiscoveryNudge
        #expect(block.contains("capabilities_discover"))
        #expect(block.contains("capabilities_load"))
        #expect(block.contains(#"capabilities_discover({"query": "<what you need>"})"#))
        #expect(!block.contains(#"capabilities_discover({"queries": "#))
    }
}

/// SOUL.md is the agent-authored complement to the user-authored persona
/// slot — sandbox-only by design, gated on a non-empty file at
/// `~/SOUL.md` (host-side: `containerAgentDir(linuxName)/SOUL.md`).
/// These tests pin: section gate, framing, render order vs persona +
/// sandbox, and the 8 KB cap with line-boundary truncation.
@Suite("SOUL.md section integration", .serialized)
@MainActor
struct SoulSectionTests {

    // MARK: - Pure renderer

    @Test("soulSection renders with framing when content is non-empty")
    func soulSection_rendersFraming() {
        let rendered = SystemPromptTemplates.soulSection("- prefer Postgres")
        #expect(rendered.contains("## SOUL"))
        #expect(rendered.contains("the user's instructions in earlier sections take precedence"))
        #expect(rendered.contains("- prefer Postgres"))
    }

    @Test("soulSection returns empty string for blank content")
    func soulSection_dropsBlank() {
        #expect(SystemPromptTemplates.soulSection("").isEmpty)
        #expect(SystemPromptTemplates.soulSection("   \n\t  ").isEmpty)
    }

    // MARK: - 8 KB cap

    @Test("capSoulContent leaves under-budget content unchanged")
    func cap_underBudgetIsNoop() {
        let small = "line one\nline two\nline three\n"
        #expect(SystemPromptComposer.capSoulContent(small) == small)
    }

    /// 9 KB seed: cap at the 8 KB byte budget on the previous newline,
    /// then append the truncation marker. Output must (a) be shorter
    /// than the input, (b) end at a line boundary + marker, (c) stay
    /// within the byte budget plus the marker length.
    @Test("capSoulContent truncates 9 KB seed at line boundary + marker")
    func cap_overBudgetTruncates() {
        // 9 KB of distinguishable lines (each "line N\n" averages ~7 B)
        // so a line boundary always exists below the 8 KB cutoff.
        var raw = ""
        var n = 0
        while raw.utf8.count < 9 * 1024 {
            raw += "line \(n)\n"
            n += 1
        }
        let capped = SystemPromptComposer.capSoulContent(raw)
        #expect(
            capped.utf8.count <= SystemPromptComposer.soulMaxBytes
                + SystemPromptComposer.soulTruncationMarker.utf8.count
        )
        #expect(capped.hasSuffix(SystemPromptComposer.soulTruncationMarker))
        // Cut precedes the marker — i.e. the cut sits on a `\n`, not
        // mid-line. Strip the marker, the remaining text must end with `\n`.
        let withoutMarker = String(
            capped.dropLast(
                SystemPromptComposer.soulTruncationMarker.count
            )
        )
        #expect(withoutMarker.hasSuffix("\n"))
    }

    // MARK: - End-to-end: gated read + emit

    /// Helper: spin up an agent, optionally write SOUL.md to its host
    /// home, run a preview compose, return the section IDs and the
    /// rendered prompt for assertions. Holds the sandbox + storage
    /// locks like `PromptSectionOrderingTests` does because we touch
    /// `AgentManager.shared` and `containerAgentDir`.
    private func withSoulAgent(
        soulContent: String? = nil,
        executionMode: ExecutionMode = .sandbox(hostRead: nil),
        body: @MainActor @Sendable ([String], ComposedContext) -> Void
    ) async {
        await SandboxTestLock.runWithStoragePaths {
            let agent = Agent(
                name: "SoulTestAgent-\(UUID().uuidString.prefix(6))",
                systemPrompt: "Test identity",
                agentAddress: "test-soul-\(UUID().uuidString)",
                autonomousExec: AutonomousExecConfig(enabled: true)
            )
            AgentManager.shared.add(agent)
            let linuxName = SandboxAgentProvisioner.linuxName(for: agent.id.uuidString)
            let agentDir = OsaurusPaths.containerAgentDir(linuxName)
            try? FileManager.default.createDirectory(
                at: agentDir,
                withIntermediateDirectories: true
            )
            let soulPath = agentDir.appendingPathComponent("SOUL.md", isDirectory: false)
            if let soulContent {
                try? soulContent.write(to: soulPath, atomically: true, encoding: .utf8)
            }
            defer {
                try? FileManager.default.removeItem(at: soulPath)
            }

            let ctx = SystemPromptComposer.composePreviewContext(
                agentId: agent.id,
                executionMode: executionMode
            )
            body(ctx.manifest.sections.map(\.id), ctx)
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    @Test("soul section absent in non-sandbox mode even when SOUL.md exists")
    func soul_skipsOutsideSandbox() async {
        await withSoulAgent(
            soulContent: "- always use conventional commits",
            executionMode: .none
        ) { ids, _ in
            #expect(!ids.contains("soul"))
        }
    }

    @Test("soul section absent when SOUL.md missing")
    func soul_skipsWhenMissing() async {
        await withSoulAgent(soulContent: nil) { ids, _ in
            #expect(!ids.contains("soul"))
        }
    }

    @Test("soul section absent when SOUL.md trims to empty")
    func soul_skipsWhenEmpty() async {
        await withSoulAgent(soulContent: "   \n\n   \t\n") { ids, _ in
            #expect(!ids.contains("soul"))
        }
    }

    @Test("soul section present + framed when SOUL.md has content")
    func soul_emitsWithContent() async {
        let body = "- user prefers Postgres\n- skip bash explanations"
        await withSoulAgent(soulContent: body) { ids, ctx in
            #expect(ids.contains("soul"))
            #expect(ctx.prompt.contains("## SOUL"))
            #expect(ctx.prompt.contains("user prefers Postgres"))
            #expect(ctx.prompt.contains("skip bash explanations"))
            #expect(
                ctx.prompt.contains(
                    "the user's instructions in earlier sections take precedence"
                )
            )
        }
    }

    @Test("ordering: persona < soul < sandbox")
    func soul_landsBetweenPersonaAndSandbox() async {
        await withSoulAgent(soulContent: "- prefer Postgres") { ids, _ in
            guard
                let personaIdx = ids.firstIndex(of: "persona"),
                let soulIdx = ids.firstIndex(of: "soul"),
                let sandboxIdx = ids.firstIndex(of: "sandbox")
            else {
                Issue.record("Expected persona, soul, and sandbox sections; got \(ids)")
                return
            }
            #expect(personaIdx < soulIdx, "persona must precede soul; ids=\(ids)")
            #expect(soulIdx < sandboxIdx, "soul must precede sandbox; ids=\(ids)")
        }
    }

    @Test("soul section cacheability is static (joins KV-cache prefix)")
    func soul_isStatic() async {
        await withSoulAgent(soulContent: "- prefer Postgres") { _, ctx in
            guard let soul = ctx.manifest.sections.first(where: { $0.id == "soul" }) else {
                Issue.record("Expected soul section in manifest")
                return
            }
            #expect(soul.cacheability == .static)
        }
    }
}
