import Foundation
import Testing
@testable import OsaurusCore

/// Background description generation never blocks a save and never touches
/// a user-authored description. Uses an injected generator; no model runs.
@Suite("Agent description backfill", .serialized)
@MainActor
struct AgentDescriptionBackfillTests {
    private final class Recorder {
        var prompts: [String] = []
        var result: Result<String, Error> = .success("Generated purpose.")
    }

    private func makeBackfill(_ recorder: Recorder) -> AgentDescriptionBackfill {
        AgentDescriptionBackfill(isEnabled: true) { prompt, _ in
            recorder.prompts.append(prompt)
            return try recorder.result.get()
        }
    }

    @Test func eligibilityNeedsBlankDescriptionAndPrompt() {
        #expect(!AgentDescriptionBackfill.needsGeneration(Agent.default))
        #expect(!AgentDescriptionBackfill.needsGeneration(Agent(name: "A", description: "", systemPrompt: "  ")))
        #expect(!AgentDescriptionBackfill.needsGeneration(Agent(name: "A", description: "Mine", systemPrompt: "Do X")))
        let blank = Agent(name: "A", description: "", systemPrompt: "Do X")
        #expect(AgentDescriptionBackfill.needsGeneration(blank))
        var done = blank
        done.generatedDescription = "Does X."
        done.generatedDescriptionPromptHash = AgentDescriptionPolicy.promptHash("Do X")
        #expect(!AgentDescriptionBackfill.needsGeneration(done))
        done.systemPrompt = "Do Y instead"
        #expect(AgentDescriptionBackfill.needsGeneration(done))
    }

    @Test func blankDescriptionIsFilledAndReusedUntilPromptChanges() async throws {
        try await SandboxTestLock.runWithStoragePaths {
            await SubagentStoreTestLock.shared.acquire()
            defer { SubagentStoreTestLock.shared.release() }
            let recorder = Recorder()
            let backfill = makeBackfill(recorder)
            let agent = AgentManager.shared.create(name: "Backfill \(UUID())", systemPrompt: "Review Swift code.")

            backfill.scheduleIfNeeded(agent.id)
            backfill.scheduleIfNeeded(agent.id)  // de-duplicated while queued
            await backfill.drain()
            #expect(recorder.prompts == ["Review Swift code."])
            var saved = try #require(AgentManager.shared.agent(for: agent.id))
            #expect(saved.description.isEmpty)
            #expect(saved.generatedDescription == "Generated purpose.")
            #expect(saved.generatedDescriptionPromptHash == AgentDescriptionPolicy.promptHash("Review Swift code."))
            #expect(saved.routingDescription == "Generated purpose.")

            // Same prompt: nothing to do.
            backfill.scheduleIfNeeded(agent.id)
            await backfill.drain()
            #expect(recorder.prompts.count == 1)

            // Prompt edit drops the stale summary on save (routing falls back
            // to the bare name) and regenerates.
            saved.systemPrompt = "Review release notes."
            AgentManager.shared.update(saved)
            let afterEdit = try #require(AgentManager.shared.agent(for: agent.id))
            #expect(afterEdit.generatedDescription == nil)
            #expect(afterEdit.generatedDescriptionPromptHash == nil)
            #expect(afterEdit.routingDescription.isEmpty)
            recorder.result = .success("Reviews release notes.")
            backfill.scheduleIfNeeded(agent.id)
            await backfill.drain()
            #expect(recorder.prompts.count == 2)
            #expect(AgentManager.shared.agent(for: agent.id)?.generatedDescription == "Reviews release notes.")

            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    @Test func userDescriptionWinsAndIsNeverGenerated() async throws {
        await SandboxTestLock.runWithStoragePaths {
            await SubagentStoreTestLock.shared.acquire()
            defer { SubagentStoreTestLock.shared.release() }
            let recorder = Recorder()
            let backfill = makeBackfill(recorder)
            let agent = AgentManager.shared.create(
                name: "Manual \(UUID())", description: "Mine.", systemPrompt: "Review Swift code.")
            backfill.scheduleIfNeeded(agent.id)
            backfill.scheduleAll()
            await backfill.drain()
            #expect(recorder.prompts.isEmpty)
            #expect(AgentManager.shared.agent(for: agent.id)?.routingDescription == "Mine.")
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    @Test func lateResultIsDiscardedWhenUserTypedMeanwhile() async throws {
        try await SandboxTestLock.runWithStoragePaths {
            await SubagentStoreTestLock.shared.acquire()
            defer { SubagentStoreTestLock.shared.release() }
            let agent = AgentManager.shared.create(name: "Race \(UUID())", systemPrompt: "Review Swift code.")
            let backfill = AgentDescriptionBackfill(isEnabled: true) { _, _ in
                // The user saves a description while the model is working.
                var current = AgentManager.shared.agent(for: agent.id)!
                current.description = "Typed by user"
                AgentManager.shared.update(current)
                return "Late generated text"
            }
            backfill.scheduleIfNeeded(agent.id)
            await backfill.drain()
            let saved = try #require(AgentManager.shared.agent(for: agent.id))
            #expect(saved.description == "Typed by user")
            #expect(saved.generatedDescription == nil)
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    @Test func failuresWriteNothingAndCoolDown() async throws {
        await SandboxTestLock.runWithStoragePaths {
            await SubagentStoreTestLock.shared.acquire()
            defer { SubagentStoreTestLock.shared.release() }
            let recorder = Recorder()
            recorder.result = .failure(CoreModelError.backgroundWouldEvictUserModel("x"))
            let backfill = makeBackfill(recorder)
            let agent = AgentManager.shared.create(name: "Declined \(UUID())", systemPrompt: "Review Swift code.")
            backfill.scheduleIfNeeded(agent.id)
            await backfill.drain()
            #expect(recorder.prompts.count == 1)
            #expect(AgentManager.shared.agent(for: agent.id)?.generatedDescription == nil)

            // Inside the cooldown the agent is not retried.
            backfill.scheduleIfNeeded(agent.id)
            await backfill.drain()
            #expect(recorder.prompts.count == 1)

            // A decline uses the short cooldown, so a shrunk interval retries
            // right away and a success lands.
            recorder.result = .success("Recovered.")
            let fresh = makeBackfill(recorder)
            fresh.declineRetryInterval = 0
            recorder.result = .failure(CoreModelError.modelUnavailable("x"))
            fresh.scheduleIfNeeded(agent.id)
            await fresh.drain()
            #expect(recorder.prompts.count == 2)
            recorder.result = .success("Recovered.")
            fresh.scheduleIfNeeded(agent.id)
            await fresh.drain()
            #expect(recorder.prompts.count == 3)
            #expect(AgentManager.shared.agent(for: agent.id)?.generatedDescription == "Recovered.")
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }

    @Test func disabledBackfillIsInert() async throws {
        await SandboxTestLock.runWithStoragePaths {
            await SubagentStoreTestLock.shared.acquire()
            defer { SubagentStoreTestLock.shared.release() }
            let recorder = Recorder()
            let backfill = makeBackfill(recorder)
            backfill.isEnabled = false
            let agent = AgentManager.shared.create(name: "Off \(UUID())", systemPrompt: "Review Swift code.")
            backfill.scheduleIfNeeded(agent.id)
            backfill.scheduleAll()
            await backfill.drain()
            #expect(recorder.prompts.isEmpty)
            // The shared instance is disabled under tests too, so the save
            // path above never reached a model.
            #expect(AgentManager.shared.agent(for: agent.id)?.generatedDescription == nil)
            _ = await AgentManager.shared.delete(id: agent.id)
        }
    }
}
