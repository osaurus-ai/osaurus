//
//  PluginDispatchInstructionsInjectionTests.swift
//  OsaurusCoreTests
//
//  Pins the contract that plugin manifest `instructions` (and per-agent
//  overrides) reach the system prompt on the `host->dispatch` path,
//  not just the `host->complete` path. The fix extracted the lookup
//  into `PluginInstructionsResolver` so both paths share one
//  implementation; these tests exercise the resolver directly and
//  document the no-source-plugin no-op the `ChatView.send` call site
//  relies on.
//
//  Note: registering a real `PluginManager.LoadedPlugin` requires a
//  `dlopen`'d dylib, so the manifest-fallback branch can only be
//  asserted indirectly (resolver returns the agent override even when
//  no plugin is loaded; resolver returns nil when neither source is
//  available). The end-to-end manifest path is covered by the
//  pre-existing `host->complete` integration tests, which now route
//  through the same resolver via `PluginHostAPI.prepareInference`.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct PluginDispatchInstructionsInjectionTests {

    // MARK: - Helpers

    /// Construct a fresh test agent with the given per-plugin overrides
    /// applied, register it with `AgentManager`, run `body`, and clean
    /// up. Mirrors the helper pattern used by `PromptSectionOrderingTests`.
    private func withAgent(
        pluginInstructions: [String: String]? = nil,
        body: @MainActor @Sendable (UUID) async -> Void
    ) async {
        await SandboxTestLock.runWithStoragePaths {
            let agent = Agent(
                name: "PluginInstructionsTest-\(UUID().uuidString.prefix(6))",
                agentAddress: "test-plugin-instructions-\(UUID().uuidString)",
                pluginInstructions: pluginInstructions
            )
            AgentManager.shared.add(agent)
            await body(agent.id)
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    // MARK: - Resolver: agent override branch

    /// The per-agent override is the highest-priority source. When set
    /// and non-empty, it must be returned regardless of whether the
    /// plugin is loaded — the override is the user's explicit
    /// customization and beats whatever the plugin author shipped.
    @Test func returnsAgentOverrideWhenPresent() async {
        let pid = "com.test.plugininstructions.override.\(UUID())"
        await withAgent(pluginInstructions: [pid: "Custom override text"]) { agentId in
            let result = PluginInstructionsResolver.instructions(pluginId: pid, agentId: agentId)
            #expect(result == "Custom override text")
        }
    }

    /// Whitespace-only overrides are treated as "unset" so the resolver
    /// falls through to the manifest default. With no plugin loaded
    /// in tests, that fall-through surfaces as nil — proving the
    /// override gate honours `trimmingCharacters(in: .whitespacesAndNewlines)`
    /// rather than the raw String emptiness.
    @Test func ignoresWhitespaceOnlyOverride() async {
        let pid = "com.test.plugininstructions.whitespace.\(UUID())"
        await withAgent(pluginInstructions: [pid: "   \n  \t "]) { agentId in
            let result = PluginInstructionsResolver.instructions(pluginId: pid, agentId: agentId)
            #expect(result == nil)
        }
    }

    /// An agent with no `pluginInstructions` map at all must still
    /// resolve cleanly — fall-through to the manifest default (nil
    /// here because no plugin is loaded), no force-unwrap.
    @Test func returnsNilWhenAgentHasNoInstructionsMap() async {
        let pid = "com.test.plugininstructions.noMap.\(UUID())"
        await withAgent(pluginInstructions: nil) { agentId in
            let result = PluginInstructionsResolver.instructions(pluginId: pid, agentId: agentId)
            #expect(result == nil)
        }
    }

    /// An agent whose override map exists but doesn't contain the
    /// queried plugin id falls through to the manifest default. Same
    /// contract as the no-map case above; pinning both so a future
    /// "always inject empty string" regression can't slip through.
    @Test func returnsNilWhenAgentMapMissesPluginId() async {
        let pid = "com.test.plugininstructions.missingId.\(UUID())"
        let unrelatedPid = "com.other.plugin.\(UUID())"
        await withAgent(pluginInstructions: [unrelatedPid: "Some other text"]) { agentId in
            let result = PluginInstructionsResolver.instructions(pluginId: pid, agentId: agentId)
            #expect(result == nil)
        }
    }

    // MARK: - Resolver: manifest fallback branch

    /// `agentId == nil` is the ChatView path before the session has
    /// been bound to an agent. The resolver must skip the override
    /// lookup entirely (no agent context to consult) and return only
    /// the manifest default — nil here because no plugin is loaded.
    @Test func skipsOverrideLookupWhenAgentIdIsNil() {
        let pid = "com.test.plugininstructions.nilAgent.\(UUID())"
        let result = PluginInstructionsResolver.instructions(pluginId: pid, agentId: nil)
        #expect(result == nil)
    }

    /// No agent, no loaded plugin → nil. Covers the cold-start case
    /// where a plugin id is referenced but the plugin hasn't been
    /// loaded yet (e.g. dispatch arrived before the load sweep
    /// finished). The resolver must not crash or fabricate.
    @Test func returnsNilWhenNeitherSourceIsAvailable() {
        let pid = "com.test.plugininstructions.noSources.\(UUID())"
        let result = PluginInstructionsResolver.instructions(pluginId: pid, agentId: nil)
        #expect(result == nil)
    }

    // MARK: - Call-site contract

    /// Documents the no-op the `ChatView.send` injection block relies
    /// on: when a session has no `sourcePluginId` (direct desktop
    /// chat), the resolver is never called and the system prompt is
    /// not mutated. This test pins the call-site shape rather than
    /// the resolver itself — if a future refactor moves the
    /// `if let pid = sourcePluginId` guard into the resolver, this
    /// test will need to follow.
    @Test func chatViewSkipsResolverWhenSourcePluginIdIsNil() async {
        await withAgent(pluginInstructions: ["com.test.unused": "Should not appear"]) { agentId in
            let sourcePluginId: String? = nil
            var sys = "Composed agent prompt"
            if let pid = sourcePluginId,
                let pluginInstructions = PluginInstructionsResolver.instructions(
                    pluginId: pid,
                    agentId: agentId
                )
            {
                sys = sys.isEmpty ? pluginInstructions : sys + "\n\n" + pluginInstructions
            }
            #expect(sys == "Composed agent prompt")
        }
    }

    /// Pins the join semantics ChatView uses: when both the composed
    /// agent prompt and the plugin instructions are non-empty, they
    /// are joined by exactly one blank line. Regression guard for the
    /// `"\n\n"` separator — `appendSystemContent` in the
    /// `host->complete` path uses the same separator, so the two
    /// paths must agree byte-for-byte for KV-cache reuse.
    @Test func chatViewJoinSemanticsMatchPrepareInference() async {
        let pid = "com.test.plugininstructions.join.\(UUID())"
        await withAgent(pluginInstructions: [pid: "Plugin contract"]) { agentId in
            var sys = "Composed agent prompt"
            if let pluginInstructions = PluginInstructionsResolver.instructions(
                pluginId: pid,
                agentId: agentId
            ) {
                sys = sys.isEmpty ? pluginInstructions : sys + "\n\n" + pluginInstructions
            }
            #expect(sys == "Composed agent prompt\n\nPlugin contract")
        }
    }

    /// Empty composed prompt + non-empty plugin instructions: the
    /// instructions stand alone (no leading blank lines). Mirrors the
    /// `sys.isEmpty ? pluginInstructions : sys + "\n\n" + ...` ternary
    /// in `ChatView.send`.
    @Test func chatViewJoinSemanticsHandleEmptyComposedPrompt() async {
        let pid = "com.test.plugininstructions.emptyBase.\(UUID())"
        await withAgent(pluginInstructions: [pid: "Plugin contract"]) { agentId in
            var sys = ""
            if let pluginInstructions = PluginInstructionsResolver.instructions(
                pluginId: pid,
                agentId: agentId
            ) {
                sys = sys.isEmpty ? pluginInstructions : sys + "\n\n" + pluginInstructions
            }
            #expect(sys == "Plugin contract")
        }
    }
}
