//
//  HostedWorkflowLinks.swift
//  osaurus
//
//  The consumer's side of hosted workflows. A teammate's shared agent may
//  offer to run some of their workflows for the workspace on their own Mac
//  (`HostedWorkflowHost`). `HostedWorkflowDirectory` reads those offers;
//  Add to My Workflows keeps one as a `HostedWorkflowLink`, which this
//  Mac's agents call like an install (`workflow_<slug>`, `run_workflow`)
//  under the same rules: the Orchestrator when "Osaurus can run this for
//  you" is on, a custom agent when it's on under Abilities → Workflows.
//  A link holds no template; every run goes to the owner's Mac, which asks
//  its owner first. `HostedWorkflowClient` makes the call.
//

import Combine
import Foundation

/// One workflow a teammate's shared agent runs for you, as the catalog
/// lists it.
struct HostedWorkflowOffer: Equatable, Sendable, Identifiable {
    var wire: HostedWorkflowWire
    var workspaceID: String
    var agentAddress: String
    var agentName: String
    var ownerName: String?

    var id: String { remoteKey }
    var name: String { wire.name }
    var summary: String? { wire.summary }
    var templateID: UUID { wire.templateID }
    var remoteKey: String { HostedWorkflowLink.remoteKey(agentAddress: agentAddress, workflowID: wire.id) }
    /// "Alice's Mac", or the agent when the owner has no name here.
    var hostLabel: String { HostedWorkflowLink.hostLabel(ownerName: ownerName, agentName: agentName) }
}

public struct HostedWorkflowLink: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var workspaceID: String
    public var agentAddress: String
    public var agentName: String
    public var ownerName: String?
    public var remoteWorkflowID: UUID
    public var templateID: UUID
    public var name: String
    public var summary: String?
    public var inputs: JSONValue
    public var orchestratorVisible: Bool
    public var addedAt: Date

    init(offer: HostedWorkflowOffer, name: String, id: UUID = UUID(), addedAt: Date = Date()) {
        self.id = id
        workspaceID = offer.workspaceID
        agentAddress = offer.agentAddress.lowercased()
        agentName = offer.agentName
        ownerName = offer.ownerName
        remoteWorkflowID = offer.wire.id
        templateID = offer.wire.templateID
        self.name = name
        summary = offer.wire.summary
        inputs = offer.wire.inputs
        orchestratorVisible = true
        self.addedAt = addedAt
    }

    var remoteKey: String { Self.remoteKey(agentAddress: agentAddress, workflowID: remoteWorkflowID) }
    var toolName: String { InstalledWorkflow.toolName(for: name) }
    var ref: WorkspaceAgentRef { WorkspaceAgentRef(workspaceId: workspaceID, agentAddress: agentAddress) }
    var hostLabel: String { Self.hostLabel(ownerName: ownerName, agentName: agentName) }

    static func remoteKey(agentAddress: String, workflowID: UUID) -> String {
        "\(agentAddress.lowercased())|\(workflowID.uuidString.lowercased())"
    }

    static func hostLabel(ownerName: String?, agentName: String) -> String {
        if let ownerName, !ownerName.isEmpty { return String(format: L("%@'s Mac"), ownerName) }
        return String(format: L("%@'s Mac"), agentName)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, summary, inputs
        case workspaceID = "workspace_id"
        case agentAddress = "agent_address"
        case agentName = "agent_name"
        case ownerName = "owner_name"
        case remoteWorkflowID = "remote_workflow_id"
        case templateID = "template_id"
        case orchestratorVisible = "orchestrator_visible"
        case addedAt = "added_at"
    }
}

@MainActor
final class HostedWorkflowLinkStore: ObservableObject {
    static let shared = HostedWorkflowLinkStore(fileURL: OsaurusPaths.workflows().appendingPathComponent("hosted-links.json"))

    @Published private(set) var links: [HostedWorkflowLink] = []
    private let fileURL: URL?

    init(fileURL: URL?) {
        self.fileURL = fileURL
        reload()
    }

    func reload() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        links = (try? decoder.decode([HostedWorkflowLink].self, from: data)) ?? []
        ToolRegistry.shared.syncHostedWorkflowTools(links)
    }

    var remoteKeys: Set<String> { Set(links.map(\.remoteKey)) }
    var orchestratorVisible: [HostedWorkflowLink] { links.filter(\.orchestratorVisible) }

    func link(id: UUID) -> HostedWorkflowLink? { links.first { $0.id == id } }
    func link(for offer: HostedWorkflowOffer) -> HostedWorkflowLink? { links.first { $0.remoteKey == offer.remoteKey } }

    /// By name or tool name, the way `run_workflow` names a workflow.
    func link(named key: String) -> HostedWorkflowLink? {
        let wanted = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return links.first {
            $0.name.localizedCaseInsensitiveCompare(wanted) == .orderedSame || $0.toolName == wanted
        }
    }

    /// Keeps the offer. A name an install (or another link) already uses
    /// gets the host's name after it, so tool names never collide.
    @discardableResult
    func add(_ offer: HostedWorkflowOffer, installedNames: [String] = InstalledWorkflowStore.shared.workflows.map(\.name))
        -> HostedWorkflowLink
    {
        if let existing = link(for: offer) { return existing }
        let taken = Set((installedNames + links.map(\.name)).map(Template.slug(for:)))
        var name = offer.name
        if taken.contains(Template.slug(for: name)) {
            name = "\(offer.name) (\(offer.ownerName ?? offer.agentName))"
        }
        var suffix = 2
        let base = name
        while taken.contains(Template.slug(for: name)) {
            name = "\(base) \(suffix)"
            suffix += 1
        }
        let link = HostedWorkflowLink(offer: offer, name: name)
        links.append(link)
        persist()
        return link
    }

    func remove(id: UUID) {
        links.removeAll { $0.id == id }
        persist()
        for agent in AgentManager.shared.agents where agent.settings.enabledWorkflowIDs.contains(id) {
            AgentManager.shared.updateEnabledWorkflowIDs(
                agent.settings.enabledWorkflowIDs.filter { $0 != id }, for: agent.id)
        }
    }

    func setOrchestratorVisible(_ visible: Bool, id: UUID) {
        guard let index = links.firstIndex(where: { $0.id == id }) else { return }
        links[index].orchestratorVisible = visible
        persist()
    }

    /// Fresh offers update what a link shows and the input it takes.
    func refresh(from offers: [HostedWorkflowOffer]) {
        var changed = false
        for offer in offers {
            guard let index = links.firstIndex(where: { $0.remoteKey == offer.remoteKey }) else { continue }
            var link = links[index]
            link.summary = offer.wire.summary
            link.inputs = offer.wire.inputs
            link.agentName = offer.agentName
            link.ownerName = offer.ownerName ?? link.ownerName
            if link != links[index] {
                links[index] = link
                changed = true
            }
        }
        if changed { persist() }
    }

    private func persist() {
        ToolRegistry.shared.syncHostedWorkflowTools(links)
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(links) else { return }
        try? OsaurusPaths.ensureExists(fileURL.deletingLastPathComponent())
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Reads the hosted workflows a workspace's teammates offer: one
/// `GET /agents/{id}` per paired, online teammate agent.
enum HostedWorkflowDirectory {
    @MainActor
    static func offers(inWorkspace workspaceID: String) async -> [HostedWorkflowOffer] {
        guard let roster = WorkspaceRosterStore.shared.rosters.first(where: { $0.id == workspaceID }) else { return [] }
        let targets: [(provider: RemoteProvider, address: String, name: String, owner: String?)] =
            roster.agents.compactMap { member in
                let address = member.agentAddress.lowercased()
                guard member.online != false, !WorkspaceRosterStore.shared.isHostedHere(address: address),
                    let paired = RemoteAgentManager.shared.remoteAgent(forAddress: address, workspaceId: workspaceID),
                    let provider = RemoteProviderManager.shared.configuration.provider(id: paired.providerId)
                else { return nil }
                let identity = SharedAgentIdentity.resolve(address: address, workspaceId: workspaceID)
                return (provider, address, identity.name, identity.ownerName)
            }
        let offers = await withTaskGroup(of: [HostedWorkflowOffer].self) { group in
            for target in targets {
                group.addTask {
                    guard let metadata = await RemoteProviderService.fetchOsaurusAgentMetadata(from: target.provider),
                        metadata.features.contains(HostedWorkflowHost.feature)
                    else { return [] }
                    return metadata.hostedWorkflows.map {
                        HostedWorkflowOffer(
                            wire: $0, workspaceID: workspaceID, agentAddress: target.address,
                            agentName: metadata.name ?? target.name, ownerName: target.owner)
                    }
                }
            }
            var all: [HostedWorkflowOffer] = []
            for await batch in group { all += batch }
            return all
        }
        HostedWorkflowLinkStore.shared.refresh(from: offers)
        return offers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Runs a hosted workflow on its owner's Mac and follows it to the end.
enum HostedWorkflowClient {
    struct Target: Sendable, Equatable {
        var ref: WorkspaceAgentRef
        var remoteWorkflowID: UUID
        var name: String
        var agentName: String
        var hostLabel: String
    }

    enum Failure: Error, Equatable {
        /// The owner's agent can't be reached, or isn't shared any more.
        case unreachable(String)
        /// The owner's Mac runs an Osaurus without hosted workflows.
        case tooOld(String)
        /// Refused before or after asking the owner.
        case refused(String)
        case cancelled

        var message: String {
            switch self {
            case .unreachable(let message), .tooOld(let message), .refused(let message): return message
            case .cancelled: return L("The run was cancelled.")
            }
        }
    }

    /// Test seams.
    struct Runtime: Sendable {
        var prepare: @Sendable (WorkspaceAgentRef) async throws -> UUID
        var supportsHostedWorkflows: @Sendable (UUID) -> Bool
        var send: @Sendable (_ providerId: UUID, _ method: String, _ path: String, _ body: Data?) async -> (data: Data, statusCode: Int)?
        var pollInterval: Duration

        static let live = Runtime(
            prepare: { ref in try await WorkspaceAgentRunClient.shared.prepare(ref).providerId },
            supportsHostedWorkflows: { RemotePeerFeatures.supports(HostedWorkflowHost.feature, providerId: $0) },
            send: { providerId, method, path, body in
                guard let provider = await MainActor.run(body: {
                    RemoteProviderManager.shared.configuration.provider(id: providerId)
                })
                else { return nil }
                return await RemoteProviderService.osaurusJSONRequest(
                    provider: provider, method: method, path: path, body: body)
            },
            pollInterval: .seconds(2))
    }

    /// Starts the run, reports each phase, and returns its final status.
    /// Cancelling the task cancels the run on the owner's Mac.
    static func run(
        _ target: Target, input: JSONValue, runtime: Runtime = .live,
        onPhase: @escaping @Sendable (HostedWorkflowStatus) async -> Void = { _ in }
    ) async -> Result<HostedWorkflowStatus, Failure> {
        let providerId: UUID
        do {
            providerId = try await runtime.prepare(target.ref)
        } catch {
            let message = await MainActor.run {
                WorkspaceAgentRunClient.message(for: error, agentName: target.agentName)
            }
            return .failure(.unreachable(message))
        }
        guard runtime.supportsHostedWorkflows(providerId) else {
            return .failure(
                .tooOld(String(format: L("%@ needs a newer Osaurus to run workflows for you."), target.hostLabel)))
        }
        let base = "/agents/\(target.ref.agentAddress)/workflows"
        let body = JSONValue.object(["input": input]).compactJSONString
        guard
            let started = await runtime.send(
                providerId, "POST", "\(base)/\(target.remoteWorkflowID.uuidString.lowercased())/run", Data(body.utf8))
        else {
            return .failure(.unreachable(String(format: L("%@ couldn't be reached."), target.hostLabel)))
        }
        guard (200..<300).contains(started.statusCode),
            var status = try? JSONDecoder().decode(HostedWorkflowStatus.self, from: started.data)
        else {
            return .failure(.refused(Self.errorMessage(started.data, fallback: target.name)))
        }
        await onPhase(status)
        let ticket = status.ticket.uuidString.lowercased()
        var misses = 0
        while !status.isFinal {
            do {
                try await Task.sleep(for: runtime.pollInterval)
            } catch {
                _ = await runtime.send(providerId, "POST", "\(base)/runs/\(ticket)/cancel", nil)
                return .failure(.cancelled)
            }
            guard let polled = await runtime.send(providerId, "GET", "\(base)/runs/\(ticket)", nil) else {
                misses += 1
                if misses >= 15 {
                    return .failure(
                        .unreachable(String(format: L("Lost touch with %@ while it ran %@."), target.hostLabel, target.name)))
                }
                continue
            }
            misses = 0
            guard polled.statusCode == 200,
                let next = try? JSONDecoder().decode(HostedWorkflowStatus.self, from: polled.data)
            else {
                return .failure(.refused(Self.errorMessage(polled.data, fallback: target.name)))
            }
            if next != status { await onPhase(next) }
            status = next
        }
        if status.phase == .refused { return .failure(.refused(status.message ?? L("The owner declined."))) }
        return .success(status)
    }

    static func errorMessage(_ data: Data, fallback: String) -> String {
        struct Envelope: Decodable { let message: String? }
        if let message = (try? JSONDecoder().decode(Envelope.self, from: data))?.message, !message.isEmpty {
            return message
        }
        return String(format: L("%@ couldn't start."), fallback)
    }
}

/// Hosted runs this Mac started, for the Workflows window to show while
/// they run on their owner's Mac. In memory: the result lives in the
/// chat or task that asked.
@MainActor
final class HostedWorkflowRunCenter: ObservableObject {
    static let shared = HostedWorkflowRunCenter()

    struct Active: Identifiable, Equatable {
        let id: UUID
        let linkID: UUID
        let name: String
        let hostLabel: String
        var phase: HostedWorkflowStatus.Phase?
        let startedAt: Date
    }

    /// How a run started from the Workflows window ended.
    struct Outcome: Equatable {
        var succeeded: Bool
        var message: String
        var finishedAt: Date
    }

    @Published private(set) var active: [Active] = []
    @Published private(set) var lastOutcome: [UUID: Outcome] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func begin(_ link: HostedWorkflowLink, id: UUID = UUID()) -> UUID {
        active.append(Active(id: id, linkID: link.id, name: link.name, hostLabel: link.hostLabel, phase: nil, startedAt: Date()))
        return id
    }

    /// A run from the Workflows window; Cancel stops it on the owner's Mac.
    func start(_ link: HostedWorkflowLink, input: JSONValue) {
        let id = UUID()
        let task = Task { @MainActor in
            let result = await WorkflowToolCall.runHosted(link: link, input: input, tool: link.toolName, trackID: id)
            let succeeded = ToolEnvelope.isSuccess(result)
            self.lastOutcome[link.id] = Outcome(
                succeeded: succeeded,
                message: succeeded ? L("Finished on \(link.hostLabel)") : ToolEnvelope.failureMessage(result),
                finishedAt: Date())
        }
        attach(task, to: id)
    }

    func canCancel(_ id: UUID) -> Bool { tasks[id] != nil }

    func update(_ id: UUID, phase: HostedWorkflowStatus.Phase) {
        guard let index = active.firstIndex(where: { $0.id == id }) else { return }
        active[index].phase = phase
    }

    func attach(_ task: Task<Void, Never>, to id: UUID) { tasks[id] = task }

    func end(_ id: UUID) {
        active.removeAll { $0.id == id }
        tasks[id] = nil
    }

    func cancel(_ id: UUID) { tasks[id]?.cancel() }

    func runs(for linkID: UUID) -> [Active] { active.filter { $0.linkID == linkID } }

    static func phaseLabel(_ phase: HostedWorkflowStatus.Phase?, hostLabel: String) -> String {
        switch phase {
        case nil: return String(format: L("Reaching %@…"), hostLabel)
        case .awaitingOwner: return L("Waiting for the owner to approve")
        case .awaitingUser: return L("Waiting for the owner to fill in a form")
        default: return String(format: L("Running on %@"), hostLabel)
        }
    }
}
