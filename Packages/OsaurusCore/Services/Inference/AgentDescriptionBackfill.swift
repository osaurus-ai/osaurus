import Foundation
import os

private let logger = Logger(subsystem: "ai.osaurus", category: "agent_description_backfill")

/// Fills `Agent.generatedDescription` in the background for agents whose
/// user-authored `description` is blank, so the orchestrator still gets a
/// purpose line beside the name. The user's text always wins; a generated
/// summary is regenerated only when the system prompt changes.
///
/// Every call is best-effort housekeeping: it never blocks a save, never
/// loads or evicts a model (`CoreModelIntent.background`), and stays silent
/// when the core model is unavailable. Triggers are agent save/create, a clean
/// chat run completing (a model is resident then), and spawn roster composition.
@MainActor
public final class AgentDescriptionBackfill {
    public static let shared = AgentDescriptionBackfill()

    typealias Generator = @MainActor (_ systemPrompt: String, _ fallbackModel: String?) async throws -> String

    /// Off under tests so `AgentManager` fixtures never reach a model; tests
    /// that exercise the backfill enable it explicitly with an injected generator.
    var isEnabled: Bool
    var generator: Generator
    /// How long to wait before retrying an agent after a real failure.
    var retryInterval: TimeInterval = 10 * 60
    /// Cooldown after a quiet decline (no resident model, breaker open).
    /// Short so a roster-time decline does not block the post-chat trigger.
    var declineRetryInterval: TimeInterval = 15

    private var inFlight: Set<UUID> = []
    private var retryAfter: [UUID: Date] = [:]
    private var queue: [(id: UUID, fallbackModel: String?)] = []
    private var drainTask: Task<Void, Never>?

    init(
        isEnabled: Bool = !RuntimeEnvironment.isUnderTests,
        generator: @escaping Generator = { prompt, fallback in
            try await AgentDescriptionGenerator.generate(systemPrompt: prompt, fallbackModel: fallback)
        }
    ) {
        self.isEnabled = isEnabled
        self.generator = generator
    }

    /// Pure eligibility check shared by every trigger.
    static func needsGeneration(_ agent: Agent) -> Bool {
        guard !agent.isBuiltIn else { return false }
        guard AgentDescriptionPolicy.normalized(agent.description).isEmpty else { return false }
        let prompt = AgentDescriptionPolicy.normalized(agent.systemPrompt)
        guard !prompt.isEmpty else { return false }
        let hash = AgentDescriptionPolicy.promptHash(prompt)
        if agent.generatedDescriptionPromptHash == hash,
            !AgentDescriptionPolicy.normalized(agent.generatedDescription ?? "").isEmpty
        {
            return false
        }
        return true
    }

    /// Queue one agent when it is eligible. Safe to call from any save path.
    public func scheduleIfNeeded(_ id: UUID, fallbackModel: String? = nil) {
        guard isEnabled, let agent = AgentManager.shared.agent(for: id) else { return }
        guard Self.needsGeneration(agent) else { return }
        guard !inFlight.contains(id), !queue.contains(where: { $0.id == id }) else { return }
        if let until = retryAfter[id], until > Date() { return }
        queue.append((id, fallbackModel))
        drainIfNeeded()
    }

    /// Queue every eligible agent. Called when a model is known to be
    /// resident (after a clean chat run) so legacy agents fill in over time.
    public func scheduleAll(fallbackModel: String? = nil) {
        guard isEnabled else { return }
        for agent in AgentManager.shared.agents where Self.needsGeneration(agent) {
            scheduleIfNeeded(agent.id, fallbackModel: fallbackModel)
        }
    }

    /// Await the current queue. Test hook.
    func drain() async {
        while let task = drainTask {
            await task.value
        }
    }

    private func drainIfNeeded() {
        guard drainTask == nil else { return }
        drainTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // One utility call at a time so a long roster never competes
            // with itself for the resident model.
            while !self.queue.isEmpty {
                let next = self.queue.removeFirst()
                await self.run(next.id, fallbackModel: next.fallbackModel)
            }
            self.drainTask = nil
        }
    }

    /// Explicit fallback when the caller has one, else the first resident
    /// local model. Never triggers a load.
    static func resolveFallback(_ explicit: String?) async -> String? {
        if let explicit, !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return explicit
        }
        return await ModelRuntime.shared.residentModelNames().first
    }

    private func run(_ id: UUID, fallbackModel: String?) async {
        guard let agent = AgentManager.shared.agent(for: id), Self.needsGeneration(agent) else { return }
        inFlight.insert(id)
        defer { inFlight.remove(id) }
        let prompt = AgentDescriptionPolicy.normalized(agent.systemPrompt)
        let hash = AgentDescriptionPolicy.promptHash(prompt)
        do {
            // Save/roster triggers do not know the chat model. Borrow whatever
            // is already resident so an unset or unavailable core model still
            // produces a summary without loading anything.
            let fallback = await Self.resolveFallback(fallbackModel)
            let summary = try await generator(prompt, fallback)
            // Re-read: the user may have typed a description or changed the
            // prompt while the model was working. Their draft wins.
            guard var current = AgentManager.shared.agent(for: id), !current.isBuiltIn else { return }
            guard AgentDescriptionPolicy.normalized(current.description).isEmpty,
                AgentDescriptionPolicy.promptHash(current.systemPrompt) == hash
            else { return }
            let normalized = AgentDescriptionPolicy.normalized(summary)
            guard !normalized.isEmpty else {
                retryAfter[id] = Date().addingTimeInterval(retryInterval)
                return
            }
            current.generatedDescription = normalized
            current.generatedDescriptionPromptHash = hash
            AgentManager.shared.update(current)
            retryAfter[id] = nil
        } catch is CancellationError {
            // Nothing persisted; the next trigger reschedules.
        } catch let error as CoreModelError {
            // Declines (no resident model, breaker open, unset core model)
            // are expected and silent. Try again soon; the next clean chat
            // turn has a resident model.
            switch error {
            case .backgroundWouldEvictUserModel, .modelUnavailable, .circuitBreakerOpen:
                retryAfter[id] = Date().addingTimeInterval(declineRetryInterval)
            case .timedOut, .unresponsive:
                retryAfter[id] = Date().addingTimeInterval(retryInterval)
            }
            logger.debug("description backfill skipped for \(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        } catch {
            retryAfter[id] = Date().addingTimeInterval(retryInterval)
            logger.debug("description backfill failed for \(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
