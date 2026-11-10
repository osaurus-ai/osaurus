//
//  ResourceArbiter.swift
//  osaurus
//
//  Stage two of admission. The real RAM and load gates (`ModelRuntime`
//  cold-load slots, `refuseBackgroundLoadIfItWouldDisturb`, `MetalGate`,
//  subagent batch admission) still run inside the worker; the arbiter adds
//  the foreground yield: a background task that would swap a local model
//  out from under a live chat turn waits for the turn instead. It also holds
//  a task whose sandbox identity would have to join a busy VM, since joining
//  restarts the VM.
//

import Foundation

public struct ResourceArbiter: Sendable {
    /// Longest a task is held behind foreground reservations before it is
    /// admitted anyway, so a long chat session cannot starve background work.
    public static let maxForegroundHold: TimeInterval = 600

    public enum Decision: Equatable, Sendable {
        /// `note` is journaled (`foreground_hold_expired`).
        case admit(note: String?)
        case wait(reason: String)
    }

    let reservations: ForegroundReservationCenter

    public init(reservations: ForegroundReservationCenter) {
        self.reservations = reservations
    }

    /// Local claims that load a model other than one a live foreground turn
    /// is using wait; same-model, remote and unknown-model claims go through.
    /// A claim whose sandbox identity is not in a VM that has work running
    /// waits (`sandbox_busy`) instead of restarting it; there is no expiry,
    /// because stopping running work is never the fallback.
    public func decide(
        claim: ResourceClaim?, waitingSince: Date, now: Date = Date(), sandbox: SandboxPodSnapshot = .init()
    ) -> Decision {
        if let member = claim?.sandboxMember, !sandbox.admits(member) {
            return .wait(reason: Self.sandboxBusy)
        }
        guard let models = claim?.localModels, !models.isEmpty else { return .admit(note: nil) }
        let conflicting = reservations.localActive.contains { reservation in
            guard let held = reservation.model else { return false }
            return models.contains { $0.caseInsensitiveCompare(held) != .orderedSame }
        }
        guard conflicting else { return .admit(note: nil) }
        if now.timeIntervalSince(waitingSince) >= Self.maxForegroundHold {
            return .admit(note: "foreground_hold_expired")
        }
        return .wait(reason: "foreground_active")
    }

    public static let sandboxBusy = "sandbox_busy"

    /// The claim an agent turn makes: the model its session will start on,
    /// including the fallback pick when the agent names none.
    @MainActor
    public static func claim(forAgent agentId: UUID?) -> ResourceClaim {
        let cache = ModelPickerItemCache.shared
        return claim(forAgent: agentId, pickerItems: cache.isLoaded ? cache.items : nil)
    }

    @MainActor
    static func claim(forAgent agentId: UUID?, pickerItems: [ModelPickerItem]?) -> ResourceClaim {
        guard let agentId else { return .unknown }
        let model =
            pickerItems.map { ChatSession.initialModel(for: agentId, in: $0) }
            ?? AgentManager.shared.effectiveModel(for: agentId)
        let resolved = ForegroundReservationCenter.resolve(model: model)
        return ResourceClaim(
            model: resolved.model, isLocal: resolved.isLocal, sandboxMember: sandboxMember(forAgent: agentId))
    }

    /// An agent's sandbox identity when its turns run commands in the VM.
    @MainActor
    static func sandboxMember(forAgent agentId: UUID) -> String? {
        guard SandboxBackend.current == .virtualMachine,
            AgentManager.shared.effectiveAutonomousExec(for: agentId)?.enabled == true
        else { return nil }
        return SandboxAgentProvisioner.linuxName(for: agentId.uuidString)
    }

    /// The claim a workflow run makes, from the models bound to its slots.
    @MainActor
    public static func claim(forWorkflow workflowID: UUID) -> ResourceClaim {
        guard let installed = InstalledWorkflowStore.shared.workflow(id: workflowID) else { return .unknown }
        let local = Set(
            installed.bindings.models.values
                .map { ForegroundReservationCenter.resolve(model: $0) }
                .filter(\.isLocal)
                .compactMap(\.model)
        ).sorted()
        let member = sandboxMember(forWorkflow: installed.template)
        guard let first = local.first else { return ResourceClaim(model: nil, isLocal: false, sandboxMember: member) }
        return ResourceClaim(
            model: first, isLocal: true, additionalModels: local.count > 1 ? Array(local.dropFirst()) : nil,
            sandboxMember: member)
    }

    /// A workflow's sandbox identity when its steps run in the VM.
    static func sandboxMember(forWorkflow template: Template) -> String? {
        guard SandboxBackend.current == .virtualMachine,
            template.requirements.usesSandbox || template.workflow?.usesSandbox == true
        else { return nil }
        return OsaurusPaths.workflowSandboxAgentName(environmentID: template.id)
    }
}
