import Foundation

/// Capability for one approved child, not a process-wide eviction override.
/// The runtime registers and validates it against the parent's exact residency
/// generation. A TaskLocal copy alone is never sufficient authority.
struct ParentResidencyRetention: Sendable, Equatable {
    let id: UUID
    let targetModelName: String
    let parentModelName: String?
    let parentIdentity: ModelResidencyIdentity?
    let childOwnershipToken: ModelResidencyOwnershipToken
}

enum ParentResidencyRetentionContext {
    @TaskLocal static var current: ParentResidencyRetention?
}

/// Deferred dispatch cannot rely on the task that later pumps its queue.
/// Capture only true delegation authority, then bind it at actual execution.
struct DelegationResidencyContext: Sendable {
    let parent: ParentResidencyRetention?
    let child: ModelResidencyOwnershipToken?
    let admission: SubagentAdmissionLease?

    static func capture(source: SessionSource) -> Self {
        Self(
            parent: source == .delegation ? ParentResidencyRetentionContext.current : nil,
            child: source == .delegation ? ModelResidencyOwnershipContext.childOwnershipToken : nil,
            admission: source == .delegation ? SubagentSession.inheritedAdmissionLease : nil
        )
    }

    @MainActor
    func run(_ body: @MainActor () async -> Void) async {
        await ParentResidencyRetentionContext.$current.withValue(parent) {
            await ModelResidencyOwnershipContext.$childOwnershipToken.withValue(child) {
                await SubagentSession.$inheritedAdmissionLease.withValue(admission) {
                    await body()
                }
            }
        }
    }
}

enum ParentResidencyRetentionError: Error, LocalizedError, Sendable {
    case expiredOrChanged
    case parentBusy(String)
    case unloadDidNotComplete(String)

    var errorDescription: String? {
        switch self {
        case .expiredOrChanged:
            return "The subagent's keep-parent lease expired or its invoking model changed. Retry the task."
        case .parentBusy(let name):
            return
                "Model '\(name)' is retained by a running subagent with model swapping off. Finish or stop that job before switching models."
        case .unloadDidNotComplete(let name):
            return "Model '\(name)' could not finish unloading. Its residency changed or work has not drained; retry after that work finishes."
        }
    }
}

/// Mutated only inside ModelRuntime. Kept as a value type so expiry, overlapping
/// holds and same-name unload/reload (ABA) use the exact production policy in tests.
struct ParentResidencyRetentions: Sendable {
    private var active: [UUID: ParentResidencyRetention] = [:]

    mutating func begin(
        targetModelName: String,
        parentModelName: String?,
        parentIdentity: ModelResidencyIdentity?
    ) -> ParentResidencyRetention {
        let lease = ParentResidencyRetention(
            id: UUID(),
            targetModelName: targetModelName,
            parentModelName: parentModelName,
            parentIdentity: parentIdentity,
            childOwnershipToken: ModelResidencyOwnershipToken()
        )
        active[lease.id] = lease
        return lease
    }

    func validate(
        _ lease: ParentResidencyRetention,
        targetModelName: String,
        currentParentIdentity: ModelResidencyIdentity?
    ) throws {
        guard active[lease.id] == lease,
            lease.targetModelName.caseInsensitiveCompare(targetModelName) == .orderedSame,
            lease.parentIdentity == currentParentIdentity
        else { throw ParentResidencyRetentionError.expiredOrChanged }
    }

    func holds(_ identity: ModelResidencyIdentity?) -> Bool {
        guard let identity else { return false }
        return active.values.contains { $0.parentIdentity == identity }
    }

    @discardableResult
    mutating func end(_ lease: ParentResidencyRetention) -> Bool {
        guard active[lease.id] == lease else { return false }
        active.removeValue(forKey: lease.id)
        return true
    }
}
