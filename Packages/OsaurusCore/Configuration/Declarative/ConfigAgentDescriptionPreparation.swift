import Foundation

/// Binds generated metadata to the exact agent state reviewed before apply.
/// A nil identity means creation was prepared while that name was absent.
struct GeneratedAgentDescriptionSnapshot: Equatable, Sendable {
    let id: UUID?
    let description: String?
    let systemPrompt: String?

    init(agent: Agent?) {
        id = agent?.id
        description = agent?.description
        systemPrompt = agent?.systemPrompt
    }

    func matches(_ agent: Agent?) -> Bool {
        self == Self(agent: agent)
    }
}

/// Resolve only missing creation descriptions (or explicit blank repair
/// requests) before planning. The returned document must be used unchanged
/// for both approval and apply, so generated metadata is reviewable.
enum ConfigAgentDescriptionPreparation {
    static func prepare(
        _ document: OsaurusConfigDocument,
        generate: @Sendable (String, String) async throws -> String = {
            try await AgentDescriptionGenerator.resolve(description: $0, systemPrompt: $1)
        }
    ) async throws -> OsaurusConfigDocument {
        var prepared = document
        guard var entries = prepared.agents else { return prepared }
        for index in entries.indices {
            try Task.checkCancellation()
            let entry = entries[index]
            let key = entry.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty, key != "default" else { continue }
            let existing = await MainActor.run {
                AgentManager.shared.agents.first {
                    !$0.isBuiltIn
                        && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key
                }
            }
            // An omitted field on an existing agent remains a patch, not
            // an instruction to generate or rewrite its metadata.
            if existing != nil && entry.description == nil { continue }
            if !AgentDescriptionPolicy.normalized(entry.description ?? "").isEmpty { continue }
            if let existing, !AgentDescriptionPolicy.normalized(existing.description).isEmpty {
                entries[index].description = try AgentDescriptionPolicy.validated(existing.description)
                continue
            }
            var prompt = entry.systemPrompt ?? ""
            if AgentDescriptionPolicy.normalized(prompt).isEmpty,
                let raw = entry.template?.trimmingCharacters(in: .whitespacesAndNewlines),
                let template = AgentStarterTemplate(rawValue: raw.lowercased()), template != .blank
            {
                prompt = template.systemPrompt
            } else if entry.systemPrompt == nil {
                prompt = existing?.systemPrompt ?? ""
            }
            // Missing prompts still receive the planner's ordinary required
            // description error, without calling any model.
            guard !AgentDescriptionPolicy.normalized(prompt).isEmpty else { continue }
            let resolved = try AgentDescriptionPolicy.validated(try await generate("", prompt))
            let current = await MainActor.run {
                AgentManager.shared.agents.first {
                    !$0.isBuiltIn
                        && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key
                }
            }
            guard current?.id == existing?.id,
                current?.description == existing?.description,
                current?.systemPrompt == existing?.systemPrompt
            else {
                throw ConfigPlanIssues(issues: [
                    "agents[\(entry.name)]: the agent changed while its description was generated. Retry with the current configuration."
                ])
            }
            entries[index].description = resolved
            // Persist precisely the behavior used to generate the description,
            // including template fallback for a whitespace-only input.
            entries[index].systemPrompt = prompt
            entries[index].generatedDescriptionSnapshot = GeneratedAgentDescriptionSnapshot(agent: existing)
        }
        prepared.agents = entries
        return prepared
    }
}
