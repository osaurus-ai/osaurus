//
//  SubagentModelResolutionTests.swift
//  OsaurusCoreTests — Subagent framework
//
//  Coverage for the shared model-resolution layer every chat-driven kind
//  (spawn / computer_use) routes through. The pure
//  `pickModel` precedence (eval seam → available override → default, with
//  blanks treated as absent) and the `availableOverride` trimming are
//  GPU-free; two `resolve` cases pin the eval-bypasses-residency invariant and
//  the no-override → default fallback that the kind suites previously couldn't
//  reach without a live agent.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Subagent model resolution")
struct SubagentModelResolutionTests {

    // MARK: - pickModel precedence

    @Test("the eval seam wins over an available override and the default")
    func evalSeamWins() {
        #expect(
            SubagentModelResolution.pickModel(
                evalModel: "eval",
                availableOverride: "override",
                defaultModel: "default"
            ) == "eval"
        )
    }

    @Test("an available override wins over the default when there is no eval seam")
    func availableOverrideWins() {
        #expect(
            SubagentModelResolution.pickModel(
                evalModel: nil,
                availableOverride: "override",
                defaultModel: "default"
            ) == "override"
        )
    }

    @Test("an absent override slot falls back to the default model")
    func absentOverrideFallsBackToDefault() {
        // `pickModel` receives nil only when no override is configured. Live
        // resolution separately fails closed when a configured override is
        // unavailable.
        #expect(
            SubagentModelResolution.pickModel(
                evalModel: nil,
                availableOverride: nil,
                defaultModel: "default"
            ) == "default"
        )
    }

    @Test("everything nil resolves to nil (caller throws unavailable)")
    func allNilIsNil() {
        #expect(
            SubagentModelResolution.pickModel(
                evalModel: nil,
                availableOverride: nil,
                defaultModel: nil
            ) == nil
        )
    }

    @Test("blank / whitespace entries are treated as absent at every slot")
    func blanksAreAbsent() {
        // A blank eval seam falls through to the override…
        #expect(
            SubagentModelResolution.pickModel(
                evalModel: "   ",
                availableOverride: "override",
                defaultModel: "default"
            ) == "override"
        )
        // …a blank override falls through to the default…
        #expect(
            SubagentModelResolution.pickModel(
                evalModel: nil,
                availableOverride: "\n\t ",
                defaultModel: "default"
            ) == "default"
        )
        // …and an all-blank set resolves to nil. The winning value is returned
        // trimmed.
        #expect(
            SubagentModelResolution.pickModel(
                evalModel: "  ",
                availableOverride: "  ",
                defaultModel: "  padded-model  "
            ) == "padded-model"
        )
    }

    // MARK: - availableOverride trimming

    @MainActor
    @Test("availableOverride treats nil / empty / whitespace ids as no override")
    func availableOverrideRejectsBlanks() {
        #expect(SubagentModelResolution.availableOverride(nil) == nil)
        #expect(SubagentModelResolution.availableOverride("") == nil)
        #expect(SubagentModelResolution.availableOverride("   \n ") == nil)
    }

    // MARK: - resolve invariants

    @Test("the eval seam forces the model and bypasses residency entirely")
    func resolveEvalBypassesResidency() async throws {
        let resolved = try await SubagentModelResolution.resolve(
            capabilityId: SubagentCapabilityRegistry.spawn.id,
            agentId: nil,
            evalModel: "eval/forced-model",
            invokingParentModelName: nil,
            idleWaitSeconds: 30,
            deniedMessage: "denied",
            unavailableMessage: "unavailable",
            defaultModel: { "must-not-be-used" }
        )
        #expect(resolved.model == "eval/forced-model")
        // Uniform invariant: eval never depends on live GPU residency.
        #expect(resolved.decision.isLocal == false)
        #expect(resolved.decision.plan.shouldUnload == false)
    }

    @Test("with no override an unknown agent uses the default model; a remote default needs no swap")
    func resolveFallsBackToDefault() async throws {
        // `agentId: nil` → no settings, so no per-agent override regardless of
        // global config; the default closure supplies the model. A remote-looking
        // default is not an installed local bundle, so residency stays in place.
        let resolved = try await SubagentModelResolution.resolve(
            capabilityId: SubagentCapabilityRegistry.computerUse.id,
            agentId: nil,
            evalModel: nil,
            invokingParentModelName: nil,
            idleWaitSeconds: 30,
            deniedMessage: "denied",
            unavailableMessage: "unavailable",
            defaultModel: { "remote/frontier-model" }
        )
        #expect(resolved.model == "remote/frontier-model")
        #expect(resolved.decision.isLocal == false)
        #expect(resolved.decision.plan.shouldUnload == false)
    }

    @Test("no resolvable model throws the kind's unavailable message")
    func resolveThrowsWhenNoModel() async {
        do {
            _ = try await SubagentModelResolution.resolve(
                capabilityId: SubagentCapabilityRegistry.computerUse.id,
                agentId: nil,
                evalModel: nil,
                invokingParentModelName: nil,
                idleWaitSeconds: 30,
                deniedMessage: "denied",
                unavailableMessage: "no model here",
                defaultModel: { nil }
            )
            Issue.record("expected an unavailable error")
        } catch let error as SubagentError {
            guard case .unavailable(let message) = error else {
                Issue.record("expected .unavailable, got \(error)")
                return
            }
            #expect(message == "no model here")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("a removed configured override fails closed instead of running the default model")
    func removedConfiguredOverrideDoesNotFallback() async {
        let lease = await acquireSubagentStoreSandbox(
            "subagent-model-resolution-removed-override"
        )
        defer { lease.release() }
        let removedProviderId = UUID(
            uuidString: "AF47B570-E129-4B86-A918-D486DAD6F829"
        )!
        let removedOverride = SpawnRemoteModelIdentity.make(
            providerId: removedProviderId,
            modelId: "vendor/removed-model"
        )!
        SubagentConfigurationStore.save(
            SubagentConfiguration(
                subagentModelOverrides: [
                    SubagentCapabilityRegistry.spawn.id: removedOverride
                ]
            )
        )

        do {
            _ = try await SubagentModelResolution.resolve(
                capabilityId: SubagentCapabilityRegistry.spawn.id,
                agentId: Agent.defaultId,
                evalModel: nil,
                invokingParentModelName: nil,
                idleWaitSeconds: 30,
                deniedMessage: "denied",
                unavailableMessage: "configured override unavailable",
                defaultModel: { "local/should-not-run" }
            )
            Issue.record("expected the removed configured override to fail closed")
        } catch let error as SubagentError {
            guard case .unavailable(let message) = error else {
                Issue.record("expected .unavailable, got \(error)")
                return
            }
            #expect(message == "configured override unavailable")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
