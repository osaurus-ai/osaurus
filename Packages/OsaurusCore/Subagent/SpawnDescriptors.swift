//
//  SpawnDescriptors.swift
//  OsaurusCore — Subagent framework
//
//  Rich, render-ready descriptions of an agent's spawnable targets, used to
//  build the dynamic `spawn` system-prompt block. The composer resolves the
//  launching agent's spawnable AGENT names + MODEL ids (from
//  `SubagentToolVisibility`) into these descriptors so the prompt can enumerate
//  what `spawn_agent` / `spawn_model` can actually reach — with locality
//  (local/remote), provider, size/quant, vision, the agent's description, and
//  the user's per-model note — instead of bare names. Pure value types; the
//  `@MainActor` resolver is the only piece that touches live caches.
//

import Foundation

/// One spawnable agent (`spawn_agent` target), resolved for the prompt.
public struct SpawnAgentDescriptor: Sendable, Equatable {
    public let name: String
    /// The agent's own description (trimmed; nil when blank).
    public let description: String?
    /// The agent's effective model id (nil when none resolved).
    public let modelId: String?
    /// Locality of `modelId`: `true` local, `false` remote, nil when unknown
    /// (cold picker cache / model not currently present).
    public let isLocal: Bool?
    /// Remote provider name when the model is remote (nil otherwise).
    public let providerName: String?

    public init(
        name: String,
        description: String?,
        modelId: String?,
        isLocal: Bool?,
        providerName: String?
    ) {
        self.name = name
        self.description = description
        self.modelId = modelId
        self.isLocal = isLocal
        self.providerName = providerName
    }
}

/// One spawnable model (`spawn_model` target), resolved for the prompt.
public struct SpawnModelDescriptor: Sendable, Equatable {
    public let id: String
    public let displayName: String
    /// `true` local, `false` remote, nil when unknown.
    public let isLocal: Bool?
    public let providerName: String?
    public let parameterCount: String?
    public let quantization: String?
    public let isVLM: Bool
    /// The user's "when/how to use" note for this model (trimmed; nil when none).
    public let note: String?

    public init(
        id: String,
        displayName: String,
        isLocal: Bool?,
        providerName: String?,
        parameterCount: String?,
        quantization: String?,
        isVLM: Bool,
        note: String?
    ) {
        self.id = id
        self.displayName = displayName
        self.isLocal = isLocal
        self.providerName = providerName
        self.parameterCount = parameterCount
        self.quantization = quantization
        self.isVLM = isVLM
        self.note = note
    }
}

/// Resolves spawnable names → prompt-ready descriptors against the live agent
/// roster + model picker cache. MainActor-bound because it reads
/// `AgentManager` / `ModelPickerItemCache` / `ModelManager`.
public enum SpawnDescriptors {
    /// Resolve the launching agent's spawnable pools into descriptors, preserving
    /// pool order. Agent names that no longer match a known agent are still listed
    /// by name (so the prompt reflects the user's configured pool) but carry no
    /// description/model. Model ids absent from the picker cache fall back to a
    /// minimal descriptor (id + best-effort locality + note).
    @MainActor
    public static func resolve(
        agentNames: [String],
        modelNames: [String],
        modelNotes: [String: String]
    ) -> (agents: [SpawnAgentDescriptor], models: [SpawnModelDescriptor]) {
        let agents = agentNames.map { resolveAgent($0) }
        let models = modelNames.map { resolveModel($0, note: noteFor($0, in: modelNotes)) }
        return (agents, models)
    }

    @MainActor
    private static func resolveAgent(_ name: String) -> SpawnAgentDescriptor {
        let agent = AgentManager.shared.agents.first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }
        guard let agent else {
            return SpawnAgentDescriptor(
                name: name,
                description: nil,
                modelId: nil,
                isLocal: nil,
                providerName: nil
            )
        }
        let modelId = AgentManager.shared.effectiveModel(for: agent.id)
        let locality = classify(modelId: modelId)
        let description = agent.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return SpawnAgentDescriptor(
            name: agent.name,
            description: description.isEmpty ? nil : description,
            modelId: locality.normalizedId,
            isLocal: locality.isLocal,
            providerName: locality.providerName
        )
    }

    @MainActor
    private static func resolveModel(_ id: String, note: String?) -> SpawnModelDescriptor {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if let item = ModelPickerItemCache.shared.items.first(where: { $0.id == trimmed }) {
            let locality = classify(item: item)
            return SpawnModelDescriptor(
                id: trimmed,
                displayName: item.displayName,
                isLocal: locality.isLocal,
                providerName: locality.providerName,
                parameterCount: item.parameterCount,
                quantization: item.quantization,
                isVLM: item.isVLM,
                note: note
            )
        }
        // Not in the picker cache (cold cache or removed): minimal descriptor.
        let locality = classify(modelId: trimmed)
        return SpawnModelDescriptor(
            id: trimmed,
            displayName: shortName(fromModelId: trimmed),
            isLocal: locality.isLocal,
            providerName: locality.providerName,
            parameterCount: nil,
            quantization: nil,
            isVLM: false,
            note: note
        )
    }

    // MARK: - Locality

    /// Classify a model id by source: the picker cache is authoritative for
    /// remote/local + provider; a local install confirms local; otherwise
    /// locality is unknown (nil) so the prompt omits the badge rather than guess.
    @MainActor
    private static func classify(
        modelId: String?
    ) -> (isLocal: Bool?, providerName: String?, normalizedId: String?) {
        guard let trimmed = modelId?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return (nil, nil, nil) }
        if let item = ModelPickerItemCache.shared.items.first(where: { $0.id == trimmed }) {
            let locality = classify(item: item)
            return (locality.isLocal, locality.providerName, trimmed)
        }
        if ModelManager.findInstalledModel(named: trimmed) != nil {
            return (true, nil, trimmed)
        }
        return (nil, nil, trimmed)
    }

    private static func classify(item: ModelPickerItem) -> (isLocal: Bool?, providerName: String?) {
        switch item.source {
        case .remote(let providerName, _):
            return (false, providerName)
        case .local, .foundation, .imageGeneration:
            return (true, nil)
        }
    }

    private static func shortName(fromModelId id: String) -> String {
        guard let slashIndex = id.lastIndex(of: "/") else { return id }
        return String(id[id.index(after: slashIndex)...])
    }

    private static func noteFor(_ id: String, in notes: [String: String]) -> String? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let note = notes[trimmed]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !note.isEmpty
        else { return nil }
        return note
    }
}
