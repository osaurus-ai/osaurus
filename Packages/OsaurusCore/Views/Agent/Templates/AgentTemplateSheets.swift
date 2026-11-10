//
//  AgentTemplateSheets.swift
//  osaurus
//
//  Save-as-template from an agent card, and rename. Import lives in
//  `TemplateImportSheet`. All share the `SettingsSheetHeader` /
//  `SettingsSheetFooter` chrome so they sit next to the Create Agent sheet.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Save as template

struct SaveAgentTemplateSheet: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var store = TemplateStore.shared

    let agent: Agent
    /// Done after saving, or closing the Saved state.
    let onSaved: (AgentTemplate) -> Void
    /// Share… after saving.
    let onShare: (AgentTemplate) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var summary: String = ""
    @State private var availableToOrchestrator = true
    /// Sections the user chose to leave out of the shared JSON. Actions
    /// start off: they are per-person shortcuts, opt in to share them.
    @State private var excluded: Set<AgentTemplate.Section> = [.actions]
    @State private var draft: AgentTemplate?
    @State private var errorMessage: String?
    @State private var hasAppeared = false
    @State private var saved: AgentTemplate?

    /// A library template with the same name. Saving over it adds a new
    /// version to that template rather than forking a second one.
    private var collision: AgentTemplate? {
        let slug = AgentTemplate.slug(for: name)
        return store.allTemplates(kind: .agent).first { $0.slug == slug && !store.isBuiltIn($0) }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsSheetHeader(
                icon: saved == nil ? "square.on.square.dashed" : "checkmark.circle",
                title: saved == nil ? "Save as Template" : "Saved",
                subtitleText: agent.name,
                onClose: { if let saved { onSaved(saved) } else { onCancel() } }
            )
            if let saved {
                savedBody(saved)
            } else {
                form
            }
        }
        .fittedSheetFrame(width: 560, height: saved == nil ? 660 : 320)
        .settingsSheetSurface()
        .overlay(RoundedRectangle(cornerRadius: theme.radius.xlarge).stroke(theme.border.subtle, lineWidth: theme.stroke.default))
        .opacity(hasAppeared ? 1 : 0)
        .animation(theme.motion.quick, value: hasAppeared)
        .onAppear {
            hasAppeared = true
            if name.isEmpty {
                // Re-sharing a tweaked agent defaults to its origin template so
                // the library updates in place instead of forking silently.
                name = agent.sourceTemplateName ?? agent.name
                summary = agent.description
                draft = AgentTemplate.make(from: agent)
            }
        }
    }

    /// After Save: the template is in the library. Share opens the same
    /// sheet as the card's Share button, so the next step is one click.
    @ViewBuilder
    private func savedBody(_ template: AgentTemplate) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .glyphSize(18, weight: .medium)
                    .foregroundColor(theme.status.success.foreground)
                VStack(alignment: .leading, spacing: 4) {
                    Text(template.name)
                        .font(SettingsFont.compactLabel)
                        .foregroundColor(theme.text.primary)
                    Text(
                        template.version > 1
                            ? L("Version \(template.version) is in your Templates. Share it as a file, or publish a page you control.")
                            : L("It's in your Templates. Share it as a file, or publish a page you control.")
                    )
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(theme.space.s12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsChrome(.inset)
            .settingsLandingAnchor("agents.templates.shareAfterSave")
        }
        .padding(theme.settingsSheetInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        SettingsSheetFooter(
            primary: SettingsSheetFooter.Action(label: "Share…", handler: { onShare(template) }),
            secondary: SettingsSheetFooter.Action(label: "Done", handler: { onSaved(template) }),
            hint: nil
        )
    }

    @ViewBuilder
    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    SettingsFieldLabel("Template Name")
                    SettingsTextField(placeholder: L("e.g., Cloud Agent"), text: $name, icon: "textformat")
                        .overlay(
                            RoundedRectangle(cornerRadius: theme.radius.medium)
                                .stroke(
                                    (collision == nil ? theme.status.warning.background : theme.status.warning.foreground),
                                    lineWidth: theme.stroke.default
                                )
                        )
                    if let collision {
                        // Inline, under the field it concerns: the footer
                        // button reads Replace Template while this shows.
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .glyphSize(10, weight: .semibold)
                                .padding(.top, theme.space.s2)
                            Text("A template named \"\(collision.name)\" already exists. Saving adds version \(collision.version + 1); earlier versions stay in its history.", bundle: .module)
                                .font(SettingsFont.rowDescription)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundColor(theme.status.warning.foreground)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    SettingsFieldLabel("Summary")
                    SettingsTextField(
                        placeholder: L("One line about what this agent is for"), text: $summary,
                        icon: "text.alignleft")
                }
                includeSection
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Available to the Orchestrator", bundle: .module)
                            .font(SettingsFont.compactLabel)
                            .foregroundColor(theme.text.primary)
                        Text(
                            "Lets the Orchestrator base new agents on this template when you ask for it by name.",
                            bundle: .module
                        )
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Toggle("", isOn: $availableToOrchestrator)
                        .settingsSwitch()
                }
                .padding(theme.space.s8)
                .settingsChrome(.inset)
                if let draft, !draft.requires.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SettingsFieldLabel("Travels With the Template")
                        Text(
                            "Whoever imports this will be asked to set these up on their Mac.",
                            bundle: .module
                        )
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                        ForEach(draft.requires) { requirement in
                            HStack(spacing: 8) {
                                Image(systemName: requirement.kind.icon)
                                    .glyphSize(10, weight: .medium)
                                    .foregroundColor(theme.text.tertiary)
                                    .frame(width: 14)
                                Text(requirement.kind.title)
                                    .font(SettingsFont.smallLabel)
                                    .foregroundColor(theme.text.secondary)
                                Text(requirement.label ?? requirement.value)
                                    .font(SettingsFont.rowDescription)
                                    .foregroundColor(theme.text.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    .padding(theme.space.s12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .settingsChrome(.inset)
                }
                if let errorMessage {
                    Text(errorMessage).font(SettingsFont.caption).foregroundColor(theme.status.error.foreground)
                }
                Text(
                    "Secrets, folder access and knowledge files never travel. Only the configuration does.",
                    bundle: .module
                )
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
            }
            .padding(theme.space.s16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        SettingsSheetFooter(
            primary: SettingsSheetFooter.Action(
                label: collision == nil ? "Save Template" : "Save New Version",
                isEnabled: canSave, handler: save),
            secondary: SettingsSheetFooter.Action(label: "Cancel", handler: onCancel),
            hint: nil
        )
    }

    /// What goes into the JSON. Everything but Actions is on by default; a user who
    /// wants to share a tool setup but keep the prompt private, or drop the
    /// folder hint, flips the section off here.
    private var includeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsFieldLabel("Include in Template")
            VStack(spacing: 0) {
                ForEach(Array(availableSections.enumerated()), id: \.element) { index, section in
                    if index > 0 { Divider().opacity(0.4) }
                    HStack(spacing: 12) {
                        Image(systemName: Self.icon(for: section))
                            .glyphSize(11, weight: .medium)
                            .foregroundColor(theme.text.tertiary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Self.title(for: section))
                                .font(SettingsFont.compactLabel)
                                .foregroundColor(theme.text.primary)
                            if let preview = preview(for: section) {
                                Text(preview)
                                    .font(SettingsFont.footnote)
                                    .foregroundColor(theme.text.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        Spacer(minLength: 12)
                        Toggle("", isOn: Binding(
                            get: { !excluded.contains(section) },
                            set: { on in
                                if on { excluded.remove(section) } else { excluded.insert(section) }
                            }))
                            .settingsSwitch()
                    }
                    .padding(.horizontal, theme.space.s8)
                    .padding(.vertical, theme.space.s8)
                }
            }
            .settingsChrome(.inset)
        }
    }

    /// Only sections the agent actually has something in.
    private var availableSections: [AgentTemplate.Section] {
        guard let draft else { return [] }
        let entry = draft.agent
        return AgentTemplate.Section.allCases.filter { section in
            switch section {
            case .systemPrompt: return !(entry.systemPrompt ?? "").isEmpty
            case .description: return !(entry.description ?? "").isEmpty
            case .model: return entry.model.valueOrNil != nil
            case .tools:
                return entry.tools?.mode == "manual" || entry.mcpServers != nil || entry.plugins != nil
                    || entry.skills.isSpecified
            case .sandbox: return entry.sandbox != nil
            case .subagents: return entry.subagents?.enabled == true
            case .workingFolder: return entry.workingFolder.valueOrNil != nil
            case .knowledge: return entry.capabilities?.knowledgeEnabled == true || !draft.knowledgeCollectionNames.isEmpty
            case .pluginInstructions: return !(entry.pluginInstructions ?? [:]).isEmpty
            case .actions: return !(draft.actions ?? []).isEmpty
            case .workflows: return !draft.workflowReferences.isEmpty
            }
        }
    }

    private func preview(for section: AgentTemplate.Section) -> String? {
        guard let entry = draft?.agent else { return nil }
        switch section {
        case .systemPrompt: return entry.systemPrompt
        case .description: return entry.description
        case .model: return entry.model.valueOrNil
        case .tools:
            let count = (entry.tools?.enabled?.count ?? 0) + (entry.mcpServers?.enabled?.count ?? 0) + (entry.plugins?.enabled?.count ?? 0)
            return count == 1 ? L("1 tool") : L("\(count) tools")
        case .sandbox: return nil
        case .subagents: return L("Can use subagents")
        case .workingFolder: return entry.workingFolder.valueOrNil
        case .knowledge:
            // Only names travel; the receiving Mac creates or picks its own
            // collections. Say so, or people expect their documents to ship.
            let names = draft?.knowledgeCollectionNames ?? []
            return names.isEmpty
                ? L("Collection names only, never the files")
                : L("Collection names only, never the files: \(names.joined(separator: ", "))")
        case .pluginInstructions:
            let count = entry.pluginInstructions?.count ?? 0
            return count == 1 ? L("1 plugin") : L("\(count) plugins")
        case .actions:
            let count = draft?.actions?.count ?? 0
            return count == 1 ? L("1 quick action") : L("\(count) quick actions")
        case .workflows:
            let names = draft?.bundled.map(\.name) ?? []
            let count = draft?.workflowReferences.count ?? 0
            return names.isEmpty
                ? (count == 1 ? L("1 workflow") : L("\(count) workflows"))
                : L("Bundles \(names.joined(separator: ", "))")
        }
    }

    private static func title(for section: AgentTemplate.Section) -> String {
        switch section {
        case .systemPrompt: return L("System Prompt")
        case .description: return L("Description")
        case .model: return L("Model")
        case .tools: return L("Tools")
        case .sandbox: return L("Enable Sandbox")
        case .subagents: return L("Subagents")
        case .workingFolder: return L("Working Folder")
        case .knowledge: return L("Enable Knowledge")
        case .pluginInstructions: return L("Plugin Instructions")
        case .actions: return L("Actions")
        case .workflows: return L("Include Workflows")
        }
    }

    private static func icon(for section: AgentTemplate.Section) -> String {
        switch section {
        case .systemPrompt: return "text.alignleft"
        case .description: return "text.quote"
        case .model: return "cube"
        case .tools: return "wrench.and.screwdriver"
        case .sandbox: return "shippingbox"
        case .subagents: return "person.2"
        case .workingFolder: return "folder"
        case .knowledge: return "books.vertical"
        case .pluginInstructions: return "puzzlepiece.extension"
        case .actions: return "bolt"
        case .workflows: return "flowchart"
        }
    }

    private func save() {
        var template = AgentTemplate.make(
            from: agent,
            name: name,
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : summary,
            availableToOrchestrator: availableToOrchestrator,
            id: collision?.id
        ).excluding(excluded)
        template.availableToOrchestrator = availableToOrchestrator
        do {
            let stored = try store.save(template, changelog: collision == nil ? L("Saved from \(agent.name)") : nil)
            withAnimation(theme.motion.quick) { saved = stored }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Rename

struct RenameAgentTemplateSheet: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var store = TemplateStore.shared

    let template: AgentTemplate
    let onDone: () -> Void

    @State private var name: String = ""
    @State private var errorMessage: String?

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var collides: Bool {
        let slug = AgentTemplate.slug(for: trimmed)
        return store.allTemplates(kind: template.kind).contains { $0.slug == slug && $0.id != template.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsSheetHeader(icon: "pencil", title: "Rename Template", subtitleText: template.name, onClose: onDone)
            VStack(alignment: .leading, spacing: 8) {
                SettingsFieldLabel("New Name")
                SettingsTextField(placeholder: L("Template Name"), text: $name, icon: "textformat")
                if collides {
                    Text("Another template already uses this name.", bundle: .module)
                        .font(SettingsFont.rowDescription).foregroundColor(theme.status.warning.foreground)
                }
                if let errorMessage {
                    Text(errorMessage).font(SettingsFont.rowDescription).foregroundColor(theme.status.error.foreground)
                }
            }
            .padding(theme.space.s16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            SettingsSheetFooter(
                primary: SettingsSheetFooter.Action(
                    label: "Rename", isEnabled: !trimmed.isEmpty && !collides && trimmed != template.name,
                    handler: rename),
                secondary: SettingsSheetFooter.Action(label: "Cancel", handler: onDone),
                hint: nil
            )
        }
        .fittedSheetFrame(width: 440, height: 240)
        .settingsSheetSurface()
        .overlay(RoundedRectangle(cornerRadius: theme.radius.xlarge).stroke(theme.border.subtle, lineWidth: theme.stroke.default))
        .onAppear { if name.isEmpty { name = template.name } }
    }

    private func rename() {
        do {
            try store.rename(id: template.id, to: trimmed)
            onDone()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Requirement presentation

extension TemplateRequirement.Kind {
    var title: String {
        switch self {
        case .workingFolder: return L("Folder")
        case .knowledgeCollection: return L("Knowledge")
        case .plugin: return L("Plugin")
        case .mcpServer: return L("MCP server")
        case .systemPermission: return L("Permission")
        case .model: return L("Model")
        case .secret: return L("Secret")
        case .network: return L("Network")
        case .tool: return L("Tool")
        case .dependency: return L("Dependency")
        case .folder: return L("Folder")
        case .mediaModel: return L("Media Model")
        case .agent: return L("Agent")
        case .skill: return L("Skill")
        case .integrity: return L("Review")
        }
    }

    var icon: String {
        switch self {
        case .workingFolder: return "folder"
        case .knowledgeCollection: return "books.vertical"
        case .plugin: return "puzzlepiece.extension"
        case .mcpServer: return "server.rack"
        case .systemPermission: return "lock.shield"
        case .model: return "cube"
        case .secret: return "key"
        case .network: return "network"
        case .tool: return "wrench.and.screwdriver"
        case .dependency: return "shippingbox"
        case .folder: return "folder"
        case .mediaModel: return "photo.on.rectangle.angled"
        case .agent: return "person.2"
        case .skill: return "lightbulb"
        case .integrity: return "exclamationmark.shield"
        }
    }
}
