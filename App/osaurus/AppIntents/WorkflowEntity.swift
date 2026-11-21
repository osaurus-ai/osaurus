//
//  WorkflowEntity.swift
//  osaurus
//
//  App Intents entity + query for the owner's installed workflows, read
//  from `InstalledWorkflowStore` (loaded from `~/.osaurus/workflows/` on
//  first use), so the picker fills without a live server.
//

import AppIntents
import OsaurusCore

/// A selectable installed workflow, used by `RunWorkflowIntent`.
struct WorkflowEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Workflow"
    static let defaultQuery = WorkflowQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct WorkflowQuery: EntityQuery, EntityStringQuery {
    func entities(for ids: [WorkflowEntity.ID]) async throws -> [WorkflowEntity] {
        let wanted = Set(ids.map { $0.lowercased() })
        return await loadWorkflows().filter { wanted.contains($0.id.lowercased()) }
    }

    func suggestedEntities() async throws -> [WorkflowEntity] {
        await loadWorkflows()
    }

    func entities(matching string: String) async throws -> [WorkflowEntity] {
        let needle = string.lowercased()
        return await loadWorkflows().filter { $0.name.lowercased().contains(needle) }
    }

    private func loadWorkflows() async -> [WorkflowEntity] {
        await MainActor.run {
            InstalledWorkflowStore.shared.workflows
                .map { WorkflowEntity(id: $0.id.uuidString, name: $0.name) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }
}
