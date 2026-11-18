//
//  PreparedAskCatalog.swift
//  osaurus
//
//  The hidden workflows behind the first run's authored asks: a code step
//  for dates, one read under the teammate's permission, and one writing
//  step; and one prepared write, Save to Notes. Like agent wrappers they are built in memory, never installed, and
//  never listed in `status`; `run_workflow` reaches them only by id, which
//  only an ask button supplies.
//

import Foundation

@MainActor
enum PreparedAskCatalog {
    static let resourceNames = [
        "prepared-ask-planner-today", "prepared-ask-planner-week", "prepared-ask-planner-overdue",
        "prepared-ask-courier-reply", "prepared-ask-courier-yesterday", "prepared-ask-courier-unread",
        "prepared-ask-keeper-week", "prepared-ask-keeper-newest", "prepared-ask-keeper-note",
        "prepared-ask-builder-week", "prepared-ask-builder-uncommitted", "prepared-ask-builder-explain",
    ]
    /// Prepared writes: Save to Notes, under Keeper.
    static let writeResourceNames = ["prepared-keeper-save-note"]

    private static var cache: [Template]?

    static func templates() -> [Template] {
        if let cache { return cache }
        let loaded = (resourceNames + writeResourceNames).compactMap(TeamSeeder.loadBundled)
        cache = loaded
        WorkflowCallNames.setPrepared(loaded)
        return loaded
    }

    static func template(id: UUID) -> Template? {
        templates().first { $0.id == id }
    }

    /// The ask as a run-ready workflow. Its writer stays on this Mac unless
    /// the model it would run on is not local, as with the default workflows.
    static func installed(id: UUID, environment env: SetupChecker.Environment = .live()) -> InstalledWorkflow? {
        guard var template = template(id: id) else { return nil }
        if let slot = template.requirements.models.first(where: { $0.locality == .localOnly }),
            let model = env.defaultModel, !SetupChecker.canBind(model, to: slot, environment: env)
        {
            template = TeamSeeder.allowingCloudWriter(template)
        }
        return InstalledWorkflow(id: id, template: template, bindings: InstallBindings(), orchestratorVisible: false)
    }
}
