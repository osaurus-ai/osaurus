//
//  WorkflowRequirementsPanel.swift
//  osaurus
//
//  What the draft uses beyond its models, derived from the graph: secrets,
//  tools, MCP servers, plugins, packages, folders, and network hosts. A
//  read-only summary: what is missing is listed under "Before it can be
//  tested", and Set Up… is where it is provided. Models are picked on each
//  step.
//

import SwiftUI

/// Chat models offered for workflow slots and the Architect.
@MainActor
enum WorkflowModelChoices {
    static func items(toolCapableOnly: Bool = false) -> [ModelPickerItem] {
        ModelPickerItemCache.shared.items.filter { item in
            item.isLikelyChatCapable && (!toolCapableOnly || item.supportsToolCalling != false)
        }
    }

    /// The name the model picker shows for a model id.
    @MainActor
    static func displayName(_ id: String) -> String {
        if let item = ModelPickerItemCache.shared.items.first(where: { $0.id == id }) { return item.displayName }
        return id == "foundation" ? L("Apple Foundation Models") : id
    }

    /// "Apple Foundation Models (this Mac)", "grok-4.3 (cloud)".
    @MainActor
    static func runsOn(_ id: String) -> String {
        let local = SetupChecker.isLocalModel(id, catalog: ConfigModelReference.liveCatalog())
        return local ? L("\(displayName(id)) (this Mac)") : L("\(displayName(id)) (cloud)")
    }
}

struct WorkflowRequirementsPanel: View {
    let draft: WorkflowDraft

    @Environment(\.theme) private var theme

    /// True when the draft uses anything this panel lists.
    static func hasContent(_ draft: WorkflowDraft) -> Bool {
        let template = DraftRevisionCache.template(draft)
        let reqs = template.requirements
        return !(reqs.secrets.isEmpty && reqs.mcpServers.isEmpty && reqs.plugins.isEmpty && reqs.network.isEmpty
            && reqs.dependencies.isEmpty && reqs.folders.isEmpty && (template.workflow?.calledTools.isEmpty ?? true))
    }

    /// "2 secrets · 3 tools · 1 host", for the section while it is closed.
    static func summary(_ draft: WorkflowDraft) -> String {
        let template = DraftRevisionCache.template(draft)
        let reqs = template.requirements
        func count(_ n: Int, _ one: String, _ many: String) -> String? { n == 0 ? nil : n == 1 ? one : many }
        let tools = template.workflow?.calledTools.count ?? 0
        return [
            count(reqs.secrets.count, L("1 secret"), L("\(reqs.secrets.count) secrets")),
            count(tools, L("1 tool"), L("\(tools) tools")),
            count(reqs.mcpServers.count, L("1 MCP server"), L("\(reqs.mcpServers.count) MCP servers")),
            count(reqs.plugins.count, L("1 plugin"), L("\(reqs.plugins.count) plugins")),
            count(reqs.network.count, L("1 host"), L("\(reqs.network.count) hosts")),
            count(reqs.dependencies.count, L("1 package"), L("\(reqs.dependencies.count) packages")),
            count(reqs.folders.count, L("1 folder"), L("\(reqs.folders.count) folders")),
        ].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        let template = DraftRevisionCache.template(draft)
        let reqs = template.requirements
        VStack(alignment: .leading, spacing: theme.space.s12) {
            ForEach(reqs.secrets) { secret in
                line(secret.label, icon: "key", detail: secret.help, help: secret.key)
            }
            ForEach(reqs.mcpServers, id: \.self) { name in
                line(L("MCP server \(name)"), icon: "server.rack")
            }
            ForEach(reqs.plugins, id: \.self) { id in
                line(L("Plugin \(id)"), icon: "puzzlepiece.extension")
            }
            ForEach(template.workflow?.calledTools ?? [], id: \.name) { tool in
                line(L("\(tool.name): \(WorkflowToolCatalog.status(of: tool.name))"), icon: "wrench.and.screwdriver")
            }
            ForEach(reqs.dependencies) { dependency in
                line(L("\(dependency.summary) in the workflow's sandbox"), icon: "shippingbox")
            }
            ForEach(reqs.folders) { folder in
                line(folder.label, icon: "folder", detail: draft.bindings.folders[folder.key] ?? folder.help)
            }
            if !reqs.network.isEmpty {
                line(L("Reaches \(WorkflowSummary.list(reqs.network))"), icon: "network")
            }
        }
    }

    private func line(_ text: String, icon: String, detail: String? = nil, help: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.space.s8) {
            Image(systemName: icon)
                .glyphSize(.footnote)
                .foregroundColor(theme.text.tertiary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text(verbatim: text)
                    .textStyle(.bodySmall)
                    .foregroundColor(theme.text.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(help ?? "")
                if let detail, !detail.isEmpty {
                    Text(verbatim: detail)
                        .textStyle(.footnote)
                        .foregroundColor(theme.text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
