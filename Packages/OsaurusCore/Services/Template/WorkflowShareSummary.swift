//
//  WorkflowShareSummary.swift
//  osaurus
//
//  The two lists above who can see a shared workflow: what gets shared
//  (its steps and what it needs access to), and what stays on this Mac.
//  Each "stays" line holds for what `TemplateExportSanitizer` sends:
//  a template has no run records or install bindings, and secret values
//  are stripped from its examples, form defaults and server hints. Run
//  history stays only while no Example Runs are attached. Folder paths
//  under the home folder travel as `~/…` in declared folders and example
//  inputs, so there is no line about files or folders.
//

import Foundation

struct WorkflowShareSummary: Equatable {
    var shared: [String]
    var staysOnMac: [String]

    /// How many names "What it needs access to" lists before "and N more".
    static let accessNameLimit = 4

    static func make(_ template: Template, includesExampleRuns: Bool) -> WorkflowShareSummary {
        var shared: [String] = []
        if let definition = template.workflow {
            let steps = definition.nodes.count
            shared.append(steps == 1 ? L("The 1 step it follows") : L("The \(steps) steps it follows"))
        }
        let access = accessNames(template)
        if !access.isEmpty {
            let shown = access.prefix(accessNameLimit).joined(separator: ", ")
            let more = access.count - accessNameLimit
            shared.append(
                more > 0 ? L("What it needs access to: \(shown), and \(more) more") : L("What it needs access to: \(shown)"))
        }
        var stays: [String] = []
        if !includesExampleRuns { stays.append(L("Your results and run history")) }
        stays.append(L("Your accounts and sign-ins"))
        return WorkflowShareSummary(shared: shared, staysOnMac: stays)
    }

    /// The services, folders, servers and apps its steps reach, by the
    /// names setup shows, without repeats.
    static func accessNames(_ template: Template) -> [String] {
        let requirements = template.workflow.map(WorkflowRequirementsDeriver.derive) ?? template.requirements
        var names: [String] = []
        func add(_ name: String?) {
            guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
            if !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { names.append(name) }
        }
        for secret in requirements.secrets { add(secret.label) }
        for folder in requirements.folders { add(folder.label) }
        for app in requirements.apps { add(app.name) }
        if let definition = template.workflow {
            let apple = Set(definition.calledTools.compactMap { AppleApp.app(forTool: $0.name) })
            for app in AppleApp.sorted(apple) { add(app.displayName) }
        }
        for server in requirements.mcpServers { add(server) }
        for host in requirements.network { add(host) }
        if let definition = template.workflow {
            for reach in WorkflowAccessScope.derive(definition).hostReach { add(reach) }
        }
        return names
    }
}
