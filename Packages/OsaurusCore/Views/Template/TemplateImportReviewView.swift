//
//  TemplateImportReviewView.swift
//  osaurus
//
//  What a template will do on this Mac, shown before anything is saved
//  (import) and again before anything is created (install review): the
//  source of every code node, network allowlists, slots that may send data
//  to a cloud provider, requested secrets, and the author signature
//  status. Bundled workflow templates are listed with the same detail.
//

import SwiftUI

struct TemplateImportReviewView: View {
    @Environment(\.theme) private var theme

    let template: Template

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s14) {
            header(template)
            if let summary = template.summary, !summary.isEmpty {
                Text(summary)
                    .font(SettingsFont.caption)
                    .foregroundColor(theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if template.kind == .agent { agentDetail(template) }
            if let def = template.workflow {
                let reach = Self.reach(def)
                workflowDetail(def, requirements: template.requirements, subworkflows: reach.subworkflows)
                requirementsList(reach.requirements)
            } else {
                requirementsList(template.requirements)
            }
            serverHints(template.serverHints)
            ForEach(template.bundled, id: \.id) { bundled in
                VStack(alignment: .leading, spacing: theme.space.s10) {
                    ThemeHairlineDivider()
                    HStack(spacing: theme.space.s6) {
                        Image(systemName: "shippingbox")
                            .glyphSize(.footnote, weight: .semibold)
                            .foregroundColor(theme.text.tertiary)
                        Text("Bundled workflow", bundle: .module)
                            .font(SettingsFont.smallLabel)
                            .foregroundColor(theme.text.tertiary)
                    }
                    header(bundled)
                    if let def = bundled.workflow {
                        let reach = Self.reach(def)
                        workflowDetail(def, requirements: bundled.requirements, subworkflows: reach.subworkflows)
                        requirementsList(reach.requirements)
                    } else {
                        requirementsList(bundled.requirements)
                    }
                }
            }
        }
    }

    private func header(_ t: Template) -> some View {
        HStack(alignment: .top, spacing: theme.space.s12) {
            ZStack {
                Circle().fill(theme.dataWash(seed: t.name)).frame(width: 36, height: 36)
                Image(systemName: t.kind == .workflow ? "flowchart" : "square.on.square.dashed")
                    .glyphSize(.body, weight: .semibold)
                    .foregroundColor(theme.dataInk(seed: t.name))
            }
            VStack(alignment: .leading, spacing: theme.space.s4) {
                HStack(spacing: theme.space.s6) {
                    Text(t.name)
                        .font(SettingsFont.cardTitle)
                        .foregroundColor(theme.text.primary)
                    chip(t.kind == .workflow ? L("Workflow") : L("Agent"), color: theme.status.info.foreground)
                    chip("v\(t.version)", color: theme.text.tertiary)
                }
                signatureRow(t)
                if !t.changelog.isEmpty {
                    Text(t.changelog)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func signatureRow(_ t: Template) -> some View {
        let status = TemplateSigner.status(of: t)
        let (icon, color): (String, Color) = {
            switch status {
            case .unsigned: return ("seal", theme.text.tertiary)
            case .signed(_, let known):
                return (
                    "checkmark.seal.fill", known == nil ? theme.status.info.foreground : theme.status.success.foreground
                )
            case .invalid: return ("exclamationmark.triangle.fill", theme.status.warning.foreground)
            }
        }()
        return HStack(spacing: theme.space.s4) {
            Image(systemName: icon).glyphSize(.micro, weight: .semibold)
            Text(status.label).font(SettingsFont.smallLabel)
            if case .signed(let address, _) = status {
                Text(address)
                    .font(SettingsFont.monoSmall)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // The name is the author's own claim; only the address is verified.
            if let name = t.author?.name, !name.isEmpty {
                Text(L("· named \(name)")).font(SettingsFont.rowDescription)
            }
        }
        .foregroundColor(color)
    }

    private func agentDetail(_ t: Template) -> some View {
        HStack(spacing: theme.space.s10) {
            detail("cube", t.agent.model.valueOrNil ?? L("Default Model"))
            if let mode = t.agent.tools?.mode {
                detail("wrench.and.screwdriver", mode == "manual" ? L("Custom Tools") : L("Auto tools"))
            }
            if !t.workflowReferences.isEmpty {
                let count = t.workflowReferences.count
                detail("flowchart", count == 1 ? L("1 workflow") : L("\(count) workflows"))
            }
        }
    }

    /// The template's requirements plus what the installed workflows its
    /// steps run reach on this Mac. Not part of the template: it depends on
    /// what is installed here.
    private static func reach(_ def: WorkflowDefinition) -> WorkflowRequirementsDeriver.Reach {
        WorkflowRequirementsDeriver.reach(def) { InstalledWorkflowStore.shared.workflow(named: $0)?.definition }
    }

    @ViewBuilder
    private func workflowDetail(
        _ def: WorkflowDefinition, requirements: TemplateRequirements,
        subworkflows: [WorkflowRequirementsDeriver.Subworkflow]
    ) -> some View {
        let access = WorkflowAccessScope.derive(def)
        box(icon: WorkflowAccessScope.Place.mac.systemImage, title: L("Your files"), tint: theme.text.secondary) {
            WorkflowAccessRows(scope: access)
            Text(verbatim: access.architectSentence)
                .font(SettingsFont.footnote)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        let catalog = SetupChecker.Environment.live().modelCatalog
        let cloudSlots = requirements.models.filter { SetupChecker.mayUseCloud($0, catalog: catalog) }
        if !cloudSlots.isEmpty {
            box(icon: "cloud", title: L("May send data to a cloud provider"), tint: theme.status.warning.foreground) {
                ForEach(cloudSlots) { slot in
                    let nodes = def.nodes.filter { node in
                        if case .inference(let spec) = node.kind { return spec.modelSlot == slot.slot }
                        return false
                    }.map(\.name)
                    line(
                        L("Slot \"\(slot.slot)\""),
                        nodes.isEmpty ? (slot.preferred ?? "") : nodes.joined(separator: ", "))
                }
                Group {
                    if cloudSlots.allSatisfy({ $0.requiredModel != nil }) {
                        Text(
                            "These calls pass through the local privacy filter. The workflow requires these models, so they can't be moved to this Mac.",
                            bundle: .module
                        )
                    } else {
                        Text(
                            "These calls pass through the local privacy filter. Bind the slot to Apple Foundation Models to keep them on this Mac.",
                            bundle: .module
                        )
                    }
                }
                .font(SettingsFont.footnote)
                .foregroundColor(theme.text.tertiary)
            }
        }
        if !def.codeNodes.isEmpty {
            box(icon: "curlybraces", title: L("Code"), tint: theme.action.primary.default.background) {
                ForEach(def.codeNodes, id: \.id) { node in
                    if case .code(let spec) = node.kind {
                        DisclosureGroup {
                            ScrollView(.horizontal) {
                                Text(spec.source)
                                    .font(SettingsFont.monoSmall)
                                    .foregroundColor(theme.text.primary)
                                    .textSelection(.enabled)
                                    .padding(theme.space.s8)
                            }
                            .frame(maxHeight: 220)
                            .settingsChrome(.inset)
                        } label: {
                            VStack(alignment: .leading, spacing: theme.space.s2) {
                                Text(node.name).font(SettingsFont.compactLabel).foregroundColor(theme.text.primary)
                                Text(
                                    spec.network.isEmpty
                                        ? L("No network access")
                                        : L("Network: \(spec.network.joined(separator: ", "))")
                                )
                                .textStyle(.micro)
                                .foregroundColor(
                                    spec.network.isEmpty ? theme.text.tertiary : theme.status.warning.foreground
                                )
                                if !spec.secrets.isEmpty {
                                    Text(L("Reads secrets: \(spec.secrets.joined(separator: ", "))"))
                                        .font(SettingsFont.footnote)
                                        .foregroundColor(theme.text.tertiary)
                                }
                            }
                        }
                    }
                }
            }
        }
        if !def.calledTools.isEmpty {
            box(icon: "wrench.and.screwdriver", title: L("Tools its steps call"), tint: theme.status.warning.foreground)
            {
                ForEach(def.calledTools, id: \.name) { tool in
                    let steps = def.nodes.filter { $0.calledTools.contains { $0.name == tool.name } }.map(\.name)
                    line(tool.name, "\(steps.joined(separator: ", ")) · \(WorkflowToolCatalog.status(of: tool.name))")
                }
                Text(
                    "Installing lets these steps call these tools for whoever runs the workflow. Each tool's permission still applies.",
                    bundle: .module
                )
                .font(SettingsFont.footnote)
                .foregroundColor(theme.text.tertiary)
            }
        }
        if !subworkflows.isEmpty {
            box(icon: "flowchart", title: L("Workflows its steps run"), tint: theme.status.warning.foreground) {
                ForEach(subworkflows) { child in
                    line(child.name, Self.summary(of: child))
                }
                Text(
                    "Each runs with its own setup: its models and keys are bound there, not here. The hosts and tools it reaches are counted below.",
                    bundle: .module
                )
                .font(SettingsFont.footnote)
                .foregroundColor(theme.text.tertiary)
            }
        }
        if !requirements.dependencies.isEmpty {
            box(icon: "shippingbox", title: L("Installs packages in its own sandbox"), tint: theme.text.secondary) {
                ForEach(requirements.dependencies) { dependency in
                    line(dependency.packages.joined(separator: ", "), dependency.manager.displayName)
                }
                Text(
                    "Shell steps run in a sandbox made for this workflow, not on your Mac. Setup installs these packages there before the first run.",
                    bundle: .module
                )
                .font(SettingsFont.footnote)
                .foregroundColor(theme.text.tertiary)
            }
        }
        if !requirements.folders.isEmpty {
            box(icon: "folder", title: L("Folders it uses"), tint: theme.text.secondary) {
                ForEach(requirements.folders) { folder in
                    line(folder.label, folder.access.displayName)
                }
                Text(
                    "Setup asks you to choose each folder on this Mac. The template never carries a path.",
                    bundle: .module
                )
                .font(SettingsFont.footnote)
                .foregroundColor(theme.text.tertiary)
            }
        }
        if !requirements.secrets.isEmpty {
            box(icon: "key", title: L("Secrets requested"), tint: theme.text.secondary) {
                ForEach(requirements.secrets) { secret in
                    line(secret.label, secret.key)
                }
            }
        }
    }

    /// One line on what a sub-workflow brings with it.
    static func summary(of child: WorkflowRequirementsDeriver.Subworkflow) -> String {
        guard let reqs = child.requirements else { return L("Not installed on this Mac. Install it first.") }
        var parts: [String] = []
        if !reqs.network.isEmpty { parts.append(L("reaches \(reqs.network.joined(separator: ", "))")) }
        let tools = reqs.tools + reqs.mcpServers + reqs.plugins
        if !tools.isEmpty { parts.append(L("calls \(tools.joined(separator: ", "))")) }
        if !reqs.secrets.isEmpty { parts.append(L("uses its own key for \(reqs.secrets.map(\.label).joined(separator: ", "))")) }
        if !reqs.models.isEmpty { parts.append(L("runs a model for \(reqs.models.map(\.slot).joined(separator: ", "))")) }
        let what = parts.isEmpty ? L("needs nothing of its own") : parts.joined(separator: "; ")
        return L("Installed · \(what)")
    }

    /// A required model names itself next to its slot.
    static func itemText(_ requirement: TemplateRequirement) -> String {
        let text = requirement.label ?? requirement.value
        guard requirement.kind == .model, requirement.policy == .always else { return text }
        return L("\(text) · requires \(requirement.value)")
    }

    private func requirementsList(_ requirements: TemplateRequirements) -> some View {
        let items = requirements.items
        return Group {
            if !items.isEmpty {
                box(icon: "checklist", title: L("Needs on this Mac"), tint: theme.text.secondary) {
                    ForEach(items) { requirement in
                        HStack(spacing: theme.space.s8) {
                            Image(systemName: requirement.kind.icon)
                                .glyphSize(.micro, weight: .medium)
                                .foregroundColor(theme.text.tertiary)
                                .frame(width: 14)
                            Text(requirement.kind.title)
                                .font(SettingsFont.smallLabel)
                                .foregroundColor(theme.text.secondary)
                            Text(Self.itemText(requirement))
                                .font(SettingsFont.rowDescription)
                                .foregroundColor(theme.text.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func serverHints(_ hints: [MCPServerHint]) -> some View {
        if !hints.isEmpty {
            box(icon: "server.rack", title: L("How to connect its MCP servers"), tint: theme.text.secondary) {
                ForEach(hints) { hint in
                    switch hint.transport {
                    case .http: line(hint.name, hint.url ?? "")
                    case .stdio: line(hint.name, L("Runs \(([hint.command ?? ""] + hint.args).joined(separator: " "))"))
                    }
                }
                Text(
                    "Setup offers these when a server isn't on this Mac. Nothing connects or runs until you save it, and keys are never included.",
                    bundle: .module
                )
                .font(SettingsFont.footnote)
                .foregroundColor(theme.text.tertiary)
            }
        }
    }

    private func box<Content: View>(
        icon: String, title: String, tint: Color, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s6) {
            HStack(spacing: theme.space.s6) {
                Image(systemName: icon).glyphSize(.micro, weight: .semibold)
                Text(title).font(SettingsFont.smallLabel)
            }
            .foregroundColor(tint)
            content()
        }
        .padding(theme.space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(.inset)
    }

    private func line(_ title: String, _ value: String) -> some View {
        HStack(spacing: theme.space.s8) {
            Text(title).font(SettingsFont.smallLabel).foregroundColor(theme.text.secondary)
            Text(value)
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func detail(_ icon: String, _ text: String) -> some View {
        HStack(spacing: theme.space.s4) {
            Image(systemName: icon).glyphSize(.tiny, weight: .medium)
            Text(text).font(SettingsFont.chip).lineLimit(1)
        }
        .foregroundColor(theme.text.tertiary)
    }

    private func chip(_ text: String, color: Color) -> some View {
        StatusChip(text, tint: color)
    }
}
