//
//  SubagentCapabilityRegistryTests.swift
//  OsaurusCoreTests — Subagent framework
//
//  The standing guard against the BUG E surface split: the native
//  `SystemPromptComposer.resolveTools` strip and the HTTP
//  `enrichWithAgentContext` inject now both read `SubagentToolVisibility`, so
//  they can never drift on which sub-agent tools an agent sees. These tests
//  pin the shared resolver + the per-agent gate semantics, and assert the
//  registry SSOT and `ToolRegistry`'s internal gating set stay in lockstep.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Subagent capability registry + visibility")
struct SubagentCapabilityRegistryTests {

    @Test("the delegation tool-name set is the union of the delegation family")
    func delegationToolNames() {
        let names = SubagentToolVisibility.delegationToolNames
        #expect(names.contains("spawn"))
        // The two image tools merged into one `image` tool.
        #expect(names.contains("image"))
        #expect(!names.contains("image_generate"))
        #expect(!names.contains("image_edit"))
        // `local_delegate` is gone — spawn is the sole text sub-agent tool.
        #expect(!names.contains("local_delegate"))
    }

    @Test("the default agent is gated by the GLOBAL switch; a custom agent by its own flag")
    func delegationEnabledSemantics() {
        let custom = UUID()
        // Default agent: global wins, per-agent flag ignored.
        #expect(
            SubagentToolVisibility.delegationEnabled(
                agentId: Agent.defaultId,
                perAgentEnabled: false,
                globalEnabled: true
            )
        )
        #expect(
            !SubagentToolVisibility.delegationEnabled(
                agentId: Agent.defaultId,
                perAgentEnabled: true,
                globalEnabled: false
            )
        )
        // Custom agent: per-agent flag wins, global ignored.
        #expect(
            SubagentToolVisibility.delegationEnabled(
                agentId: custom,
                perAgentEnabled: true,
                globalEnabled: false
            )
        )
        #expect(
            !SubagentToolVisibility.delegationEnabled(
                agentId: custom,
                perAgentEnabled: false,
                globalEnabled: true
            )
        )
    }

    @Test("capability descriptors expose the right primary tool + guidance shape")
    func capabilityShape() {
        #expect(SubagentCapabilityRegistry.computerUse.primaryToolName == "computer_use")
        #expect(SubagentCapabilityRegistry.computerUse.guidance != nil)
        // Image generation + editing now share the single `image` tool.
        #expect(SubagentCapabilityRegistry.image.primaryToolName == "image")
        #expect(SubagentCapabilityRegistry.image.guidance != nil)
        // Spawn has no guidance section.
        #expect(SubagentCapabilityRegistry.spawn.guidance == nil)
    }

    /// Drift guard: the registry SSOT (consumed by both visibility surfaces)
    /// must match `ToolRegistry`'s internal delegation gating set, so the
    /// schema strip and the registry-driven visibility never disagree.
    @MainActor
    @Test("the registry SSOT matches ToolRegistry's internal delegation set")
    func ssotMatchesToolRegistry() {
        #expect(SubagentToolVisibility.delegationToolNames == ToolRegistry.agentDelegationAllToolNames)
    }

    // MARK: - BUG E parity guard

    private static func packageRoot() -> URL {
        // .../Tests/Subagent/<thisFile> → OsaurusCore/
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Subagent/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // OsaurusCore/
    }

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The original BUG E was a *surface split*: the native composer strip and
    /// the HTTP enrich path each decided sub-agent tool visibility from their
    /// own hardcoded `["image_generate","image_edit","local_delegate","spawn"]`
    /// list, so they could disagree on what an agent sees. Both must now resolve
    /// from the single `SubagentToolVisibility` SSOT and never re-introduce a
    /// hardcoded delegation list. This is a source-level standing guard (mirrors
    /// `RuntimePolicySourceTests`) so a future edit to either surface that
    /// re-hardcodes the set fails CI instead of silently re-splitting them.
    @Test("native + HTTP tool-visibility surfaces both read the shared SSOT, never a hardcoded list")
    func surfacesShareTheResolver() throws {
        let composer = try Self.source("Services/Chat/SystemPromptComposer.swift")
        let http = try Self.source("Networking/HTTPHandler.swift")

        // Both entry points read the shared resolver…
        #expect(composer.contains("SubagentToolVisibility.delegationToolNames"))
        #expect(http.contains("SubagentToolVisibility.delegationToolNames"))
        #expect(http.contains("SubagentToolVisibility.delegationEnabled"))

        // …and neither re-introduces the BUG E hardcoded delegation list.
        for legacy in ["\"local_delegate\"", "\"image_generate\"", "\"image_edit\""] {
            #expect(!composer.contains(legacy))
            #expect(!http.contains(legacy))
        }
    }
}
