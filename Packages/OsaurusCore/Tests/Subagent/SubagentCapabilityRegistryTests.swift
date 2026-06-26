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

    @Test("the registry represents every shipped kind, including sandbox_reduce")
    func allRepresentsEveryKind() {
        let ids = Set(SubagentCapabilityRegistry.all.map(\.id))
        #expect(ids == ["computer_use", "spawn", "image", "sandbox_reduce"])
        // sandbox_reduce is display/guidance-only here — gated by sandbox
        // registration, not a per-agent or delegation toggle.
        #expect(SubagentCapabilityRegistry.sandboxReduce.perAgentFlag == nil)
        if case .sandboxExec = SubagentCapabilityRegistry.sandboxReduce.gate {
        } else {
            Issue.record("sandbox_reduce must use the .sandboxExec gate")
        }
        // …so it never joins the delegation family nor the strippable set.
        let delegationIds = Set(SubagentCapabilityRegistry.delegationFamily.map(\.id))
        #expect(!delegationIds.contains("sandbox_reduce"))
        #expect(!SubagentToolVisibility.delegationToolNames.contains("sandbox_reduce"))
    }

    @Test("the modelSource axis records how each kind resolves its model")
    func modelSourceAxis() {
        // The image coordinator owns a dedicated, separately-configured model.
        #expect(SubagentCapabilityRegistry.image.modelSource == .dedicatedConfigured)
        // spawn runs the chosen persona's own model (local or remote).
        #expect(SubagentCapabilityRegistry.spawn.modelSource == .persona)
        // computer_use + sandbox_reduce reuse the parent agent's model.
        #expect(SubagentCapabilityRegistry.computerUse.modelSource == .inheritsParent)
        #expect(SubagentCapabilityRegistry.sandboxReduce.modelSource == .inheritsParent)
    }

    @Test("every descriptor carries a display label + icon for the feed and chip")
    func displayAndIconArePopulated() {
        for capability in SubagentCapabilityRegistry.all {
            #expect(!capability.displayLabel.isEmpty, "\(capability.id) missing displayLabel")
            #expect(!capability.iconName.isEmpty, "\(capability.id) missing iconName")
        }
    }

    @Test("per-agent toggle flags collapse spawn + image onto one shared flag")
    func perAgentToggleFlagsCollapse() {
        // One toggle per *flag*: computer_use has its own; spawn + image share
        // `spawnDelegationEnabled`, so the editor renders exactly two toggles.
        #expect(SubagentCapabilityRegistry.perAgentToggleFlags == [.computerUse, .spawnDelegation])
    }

    /// Drift guard: the registry SSOT (consumed by both visibility surfaces)
    /// must match `ToolRegistry`'s internal delegation gating sets, so the
    /// schema strip and the registry-driven visibility never disagree. Every
    /// `ToolRegistry` delegation set is now DERIVED from the registry, so these
    /// equalities also prove there is no hand-maintained mirror to drift.
    @MainActor
    @Test("the registry SSOT matches ToolRegistry's derived delegation sets")
    func ssotMatchesToolRegistry() {
        #expect(SubagentToolVisibility.delegationToolNames == ToolRegistry.agentDelegationAllToolNames)
        #expect(ToolRegistry.agentDelegationSpawnToolNames == Set(SubagentCapabilityRegistry.spawn.toolNames))
        #expect(ToolRegistry.agentDelegationImageToolNames == Set(SubagentCapabilityRegistry.image.toolNames))
        // The "all" set is exactly the union of the per-family sets.
        #expect(
            ToolRegistry.agentDelegationAllToolNames
                == ToolRegistry.agentDelegationSpawnToolNames.union(ToolRegistry.agentDelegationImageToolNames)
        )
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

    /// SSOT guard (the add-a-kind invariant): `ToolRegistry`'s delegation
    /// tool-name sets must be DERIVED from the capability registry, never a
    /// hand-maintained literal. A future edit that re-hardcodes the spawn/image
    /// set here fails CI instead of silently re-forking the SSOT.
    @Test("ToolRegistry derives its delegation sets from the registry, not a hardcoded list")
    func toolRegistryDerivesFromRegistry() throws {
        let registry = try Self.source("Tools/ToolRegistry.swift")

        // The delegation accessors read the registry…
        #expect(registry.contains("SubagentCapabilityRegistry.spawn.toolNames"))
        #expect(registry.contains("SubagentCapabilityRegistry.image.toolNames"))
        #expect(registry.contains("SubagentToolVisibility.delegationToolNames"))
        // …and the exclusion gate loops the family rather than mirroring it.
        #expect(registry.contains("SubagentCapabilityRegistry.delegationFamily"))

        // No re-hardcoded combined delegation literal (the mirror we removed),
        // and no legacy tool names.
        for hardcoded in [
            "[\"spawn\", \"image\"]", "[\"image\", \"spawn\"]",
            "\"local_delegate\"", "\"image_generate\"", "\"image_edit\"",
        ] {
            #expect(!registry.contains(hardcoded), "ToolRegistry must not hardcode \(hardcoded)")
        }
    }
}
