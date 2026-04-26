//
//  SystemPromptDefaultIdentityTests.swift
//
//  Regression: the unconditional `defaultIdentity` block in
//  `SystemPromptTemplates` must NOT name any chat-layer-intercepted tools
//  (`todo`, `complete`, `share_artifact`, `clarify`, `capabilities_search`)
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

@Suite("SystemPromptTemplates default identity tool-name leak guard")
struct SystemPromptDefaultIdentityTests {

    /// The set of tool names that MUST NOT appear in `defaultIdentity`.
    /// Each one has a separately-gated guidance block that only fires
    /// when the tool is actually in the resolved schema.
    private static let leakedToolNames: [String] = [
        // Chat-layer intercepted (gated by `agentLoopGuidance`)
        "todo",
        "complete",
        "clarify",
        "share_artifact",
        // Capability discovery (gated by `capabilityDiscoveryNudge`)
        "capabilities_search",
        "capabilities_load",
        // Sandbox tools (gated by sandbox-section composer)
        "sandbox_read_file",
        "sandbox_edit_file",
        "sandbox_write_file",
        "sandbox_find_files",
        "sandbox_search_files",
        "sandbox_list_directory",
        "sandbox_run_script",
        "sandbox_exec",
        "sandbox_exec_background",
        "sandbox_pip_install",
        "sandbox_npm_install",
        "sandbox_install",
        // Folder tools (gated by `folderContext` composer)
        "file_tree",
        "file_search",
        "file_read",
        "file_edit",
        "file_write",
        "file_move",
        "file_copy",
        "file_delete",
        "dir_create",
        // Misc tools the model might know from training but that osaurus
        // does not register by default
        "render_chart",
        "search_memory",
    ]

    @Test("defaultIdentity does not name any chat-layer or sandbox tool")
    func defaultIdentityDoesNotLeakToolNames() {
        let identity = SystemPromptTemplates.defaultIdentity
        for name in Self.leakedToolNames {
            #expect(
                !identity.contains(name),
                "defaultIdentity must not mention `\(name)` — it leaked tool names cause low-bit MoE models (MiniMax M2.7 Small JANGTQ) to recite tool-spec text in a loop when the tool isn't in the request's tools[] array. Move the mention into the gated agentLoopGuidance / capabilityDiscoveryNudge / sandbox / folderContext block."
            )
        }
    }

    /// Empty / whitespace base prompt → falls back to defaultIdentity.
    /// Same leak guard applies after the fallback path.
    @Test("effectiveBasePrompt('') falls back to defaultIdentity and stays clean")
    func emptyBasePromptStaysClean() {
        let resolved = SystemPromptTemplates.effectiveBasePrompt("")
        for name in Self.leakedToolNames {
            #expect(
                !resolved.contains(name),
                "effectiveBasePrompt('') leaked `\(name)` via the defaultIdentity fallback"
            )
        }
    }

    @Test("effectiveBasePrompt(whitespace) also stays clean")
    func whitespaceBasePromptStaysClean() {
        let resolved = SystemPromptTemplates.effectiveBasePrompt("   \n\t  ")
        for name in Self.leakedToolNames {
            #expect(!resolved.contains(name))
        }
    }

    /// User-customised base prompt is passed through verbatim — we do NOT
    /// scrub their content. This test confirms the `?:` semantic in
    /// `effectiveBasePrompt` so a future refactor doesn't accidentally
    /// auto-strip user content.
    @Test("user-supplied base prompt is passed through unchanged")
    func userBasePromptIsRespected() {
        let userPrompt = "I am a custom assistant. Use `my_special_tool` always."
        let resolved = SystemPromptTemplates.effectiveBasePrompt(userPrompt)
        #expect(resolved == userPrompt)
    }

    /// Sanity: the gated `agentLoopGuidance` block IS allowed to mention
    /// the four chat-layer-intercepted tool names, since it only fires
    /// when those tools are present in the resolved schema (per
    /// `SystemPromptComposer.swift:265-277`). This test guards against a
    /// future "clean everything" refactor that strips the names from
    /// EVERYWHERE — that would break the actual agent-loop UX.
    @Test("agentLoopGuidance still names todo / complete / clarify / share_artifact")
    func agentLoopGuidanceStillCarriesTheNames() {
        let block = SystemPromptTemplates.agentLoopGuidance
        #expect(block.contains("todo"))
        #expect(block.contains("complete"))
        #expect(block.contains("clarify"))
        #expect(block.contains("share_artifact"))
    }

    /// Same sanity for the capability-discovery nudge — still names
    /// `capabilities_search` / `capabilities_load` because that block is
    /// gated on `capabilities_search` actually being in the tools[] array.
    @Test("capabilityDiscoveryNudge still names capabilities_search / capabilities_load")
    func capabilityNudgeStillCarriesTheNames() {
        let block = SystemPromptTemplates.capabilityDiscoveryNudge
        #expect(block.contains("capabilities_search"))
        #expect(block.contains("capabilities_load"))
    }
}
