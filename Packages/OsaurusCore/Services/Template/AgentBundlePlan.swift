//
//  AgentBundlePlan.swift
//  osaurus
//
//  What creating an agent from a template that references workflows needs:
//  for each referenced workflow, whether this Mac already has it (at the
//  pinned version or newer), has an older install to update, or still has
//  to install it, and which template version to install from. Workflows are
//  installed before the agent, and the agent is created with every
//  installed one enabled.
//

import Foundation

struct AgentBundlePlan: Equatable {
    struct Row: Identifiable, Equatable {
        enum State: Equatable {
            /// Installed here at the pinned version or newer. Reused as is.
            case installed(UUID)
            /// Installed at an older version; `template` is the newer one.
            case updateAvailable(UUID, local: Int)
            /// Not installed; `template` is what to install.
            case notInstalled
            /// Neither installed nor carried by the template file.
            case missingTemplate
        }

        let reference: WorkflowReference
        let name: String
        let state: State
        /// The version to install or update to.
        let template: Template?

        var id: UUID { reference.id }

        var installedID: UUID? {
            switch state {
            case .installed(let id), .updateAvailable(let id, _): return id
            case .notInstalled, .missingTemplate: return nil
            }
        }
    }

    let rows: [Row]

    /// Workflows to enable on the new agent.
    var enabledWorkflowIDs: [UUID] { rows.compactMap(\.installedID) }

    /// Rows that must be installed before the agent is created.
    var pending: [Row] { rows.filter { $0.state == .notInstalled } }

    static func make(
        references: [WorkflowReference],
        bundled: [Template],
        stored: (UUID) -> Template?,
        installed: (UUID) -> InstalledWorkflow?
    ) -> AgentBundlePlan {
        var seen = Set<UUID>()
        var rows: [Row] = []
        for reference in references where seen.insert(reference.id).inserted {
            let candidates = [stored(reference.id), bundled.first { $0.id == reference.id }].compactMap { $0 }
            let newest = candidates.max { $0.version < $1.version }
            let source = newest.flatMap { $0.version >= reference.minVersion ? $0 : nil }
            if let local = installed(reference.id) {
                let state: Row.State =
                    if local.templateVersion < reference.minVersion, let source, source.version > local.templateVersion {
                        .updateAvailable(local.id, local: local.templateVersion)
                    } else {
                        .installed(local.id)
                    }
                rows.append(Row(reference: reference, name: local.name, state: state, template: source))
            } else if let source {
                rows.append(Row(reference: reference, name: source.name, state: .notInstalled, template: source))
            } else {
                rows.append(
                    Row(
                        reference: reference, name: newest?.name ?? L("Unknown workflow"), state: .missingTemplate,
                        template: nil))
            }
        }
        return AgentBundlePlan(rows: rows)
    }

    @MainActor
    static func make(for template: Template) -> AgentBundlePlan {
        make(
            references: template.workflowReferences, bundled: template.bundled,
            stored: { TemplateStore.shared.latest(id: $0) },
            installed: { InstalledWorkflowStore.shared.workflow(templateID: $0) })
    }

    /// Requirements of every workflow still to install or update, each
    /// listed once however many workflows ask for it.
    var sharedRequirements: (secrets: [String], mcpServers: [String], plugins: [String], permissions: [String]) {
        let reqs = rows.filter {
            if case .installed = $0.state { return false }
            return true
        }.compactMap(\.template?.requirements)
        func unique(_ values: [String]) -> [String] {
            var seen = Set<String>()
            return values.filter { seen.insert($0.lowercased()).inserted }
        }
        var secretKeys = Set<String>()
        let secrets = reqs.flatMap(\.secrets).filter { secretKeys.insert($0.key).inserted }.map(\.label)
        return (
            secrets, unique(reqs.flatMap(\.mcpServers)), unique(reqs.flatMap(\.plugins)),
            unique(reqs.flatMap(\.permissions))
        )
    }

    /// One setup subject per workflow to install or update, for the merged
    /// setup pass. `oneModel` prefills every model slot.
    @MainActor
    func setupSubjects(oneModel: String?) -> [WorkflowSetupSubject] {
        rows.compactMap { row -> WorkflowSetupSubject? in
            guard let source = row.template else { return nil }
            switch row.state {
            case .notInstalled, .updateAvailable: break
            case .installed, .missingTemplate: return nil
            }
            let subject = WorkflowSetupSubject.install(source)
            guard let oneModel, !oneModel.isEmpty else { return subject }
            return Self.bindingAllSlots(subject, to: oneModel)
        }
    }

    /// Prefills every model slot of `template` with one model.
    static func bindingAllSlots(_ subject: WorkflowSetupSubject, to model: String) -> WorkflowSetupSubject {
        var copy = subject
        for slot in subject.template.requirements.models where copy.bindings.models[slot.slot] == nil {
            copy.bindings.models[slot.slot] = model
        }
        return copy
    }
}
