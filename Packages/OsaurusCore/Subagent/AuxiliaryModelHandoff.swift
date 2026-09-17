import Foundation

/// Explicit invocation provenance survives deferred/detached jobs. A missing
/// parent is intentional; never substitute the frontmost or resident model.
struct ModelJobInvocation: Sendable, Equatable {
    let parentModelName: String?
    let source: SessionSource?

    static func current() -> Self {
        Self(
            parentModelName: ChatExecutionContext.currentModelName,
            source: ChatExecutionContext.currentSessionSource
        )
    }

    func withContext<Value: Sendable>(_ body: () async throws -> Value) async rethrows -> Value {
        try await ChatExecutionContext.$currentModelName.withValue(parentModelName) {
            try await ChatExecutionContext.$currentSessionSource.withValue(source) {
                try await body()
            }
        }
    }
}

/// Non-tool local work must use the same parent policy and lifetime as a
/// subagent. The caller puts this entire operation INSIDE any non-rejoining
/// deadline: admission/cleanup must outlive the UI's timeout if the producer
/// is still draining.
enum AuxiliaryModelHandoff {
    static func run<Value: Sendable>(
        targetModelName: String,
        invocation: ModelJobInvocation,
        sessionID: UUID?,
        agentID: UUID,
        operationName: String,
        body: () async throws -> Value
    ) async throws -> Value {
        try await invocation.withContext {
            let installed = ModelManager.findInstalledModel(named: targetModelName)
            let resolved = ResolvedModel(
                name: installed?.name ?? targetModelName,
                id: installed?.id ?? targetModelName,
                isLocal: installed != nil
            )
            // Resolve the actual plan AFTER waiting. Local auxiliary work is
            // exclusive because the setting may change to a swap while queued.
            let admission: SubagentAdmissionClass = resolved.isLocal ? .localExclusive : .remote
            try Task.checkCancellation()
            switch await SubagentAdmission.shared.admit(admission) {
            case .cancelled:
                throw CancellationError()
            case .timedOut(let active):
                throw SubagentError.unavailable("\(operationName) waited for local work to finish: \(active)")
            case .admitted:
                break
            }
            do {
                try Task.checkCancellation()
                let config = SubagentConfigurationStore.snapshot()
                let plan = try await SubagentResidency.refreshedPlan(
                    for: resolved,
                    invokingParentModelName: invocation.parentModelName,
                    idleWaitSeconds: config.budgets.maxElapsedSeconds,
                    deniedMessage: "\(operationName) cannot hand off the invoking model."
                )
                let scope = SubagentScope(
                    sessionId: sessionID?.uuidString ?? UUID().uuidString,
                    toolCallId: UUID().uuidString,
                    agentId: agentID,
                    parentModelName: invocation.parentModelName
                )
                let feed = SubagentFeed(toolCallId: scope.toolCallId, kindId: operationName, title: operationName)
                let value: Value
                if plan.shouldUnload {
                    let handoff = ResidencyHandoff.production { _ in plan }
                    value = try await handoff.withResidency(
                        scope: scope,
                        resolved: resolved,
                        feed: feed,
                        run: body
                    )
                } else if plan.coexists {
                    value = try await CoexistenceHandoff.production(plan: plan).withRetainedParent(
                        scope: scope,
                        resolved: resolved,
                        feed: feed,
                        run: body
                    )
                } else {
                    value = try await body()
                }
                await SubagentAdmission.shared.release(admission)
                return value
            } catch {
                await SubagentAdmission.shared.release(admission)
                throw error
            }
        }
    }
}
