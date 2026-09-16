//
//  AgentTemplateSheets.swift
//  osaurus
//
//  Sheets for the template library: import (paste or file, with live
//  preview and collision handling), save-as-template from an agent card,
//  and rename. All share the `AgentSheetHeader` / `AgentSheetFooter`
//  chrome so they sit next to the Create Agent sheet naturally.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Import

struct AgentTemplateImportSheet: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var store = AgentTemplateStore.shared

    /// Prefilled text (drop, deep link). Empty opens on the paste field.
    var initialText: String = ""
    let onImported: (AgentTemplate) -> Void
    let onCancel: () -> Void

    @State private var text: String = ""
    @State private var parsed: AgentTemplate?
    @State private var parseError: String?
    @State private var overwrite = false
    @State private var hasAppeared = false

    private var collision: AgentTemplate? {
        guard let parsed else { return nil }
        return store.templates.first { $0.id == parsed.id }
    }

    private var canImport: Bool {
        parsed != nil && (collision == nil || overwrite)
    }

    var body: some View {
        VStack(spacing: 0) {
            AgentSheetHeader(
                icon: "square.and.arrow.down",
                title: "Import Template",
                subtitle: "Paste template JSON or choose a file",
                onClose: onCancel
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    pasteField
                    if let parsed {
                        preview(parsed)
                    } else if let parseError {
                        errorBox(parseError)
                    }
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            AgentSheetFooter(
                primary: AgentSheetFooter.Action(
                    label: collision == nil ? "Import" : "Replace",
                    isEnabled: canImport,
                    handler: performImport
                ),
                secondary: AgentSheetFooter.Action(label: "Cancel", handler: onCancel),
                hint: nil
            )
        }
        .fittedSheetFrame(width: 620, height: 560)
        .background(theme.primaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.primaryBorder.opacity(0.5), lineWidth: 1))
        .opacity(hasAppeared ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: hasAppeared)
        .onAppear {
            hasAppeared = true
            if text.isEmpty, !initialText.isEmpty {
                text = initialText
                reparse()
            }
        }
        .onChange(of: text) { _, _ in reparse() }
    }

    private var pasteField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                AgentSheetSectionLabel("Template")
                Spacer()
                Button {
                    if let clip = NSPasteboard.general.string(forType: .string) {
                        text = clip
                    }
                } label: {
                    Label { Text("Paste", bundle: .module) } icon: { Image(systemName: "doc.on.clipboard") }
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(SecondaryButtonStyle())
                Button {
                    chooseFile()
                } label: {
                    Label { Text("Choose File…", bundle: .module) } icon: { Image(systemName: "folder") }
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("{ \"format\": \"osaurus.agent-template\", … }", bundle: .module)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(theme.placeholderText)
                        .padding(.top, 12)
                        .padding(.leading, 16)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 140, maxHeight: 200)
                    .padding(12)
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.inputBackground)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.inputBorder, lineWidth: 1))
            )
        }
    }

    private func preview(_ template: AgentTemplate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            AgentSheetSectionLabel("Preview")
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(agentColorFor(template.name).opacity(0.15)).frame(width: 36, height: 36)
                    Image(systemName: "square.on.square.dashed")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(agentColorFor(template.name))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(template.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    if let summary = template.summary, !summary.isEmpty {
                        Text(summary).font(.system(size: 11)).foregroundColor(theme.secondaryText).lineLimit(2)
                    }
                    HStack(spacing: 10) {
                        detail("cube", template.agent.model.valueOrNil ?? L("Default Model"))
                        if let mode = template.agent.tools?.mode {
                            detail("wrench.and.screwdriver", mode == "manual" ? L("Custom Tools") : L("Auto tools"))
                        }
                        if template.availableToOrchestrator { detail("sparkles", L("Orchestrator")) }
                    }
                }
                Spacer()
            }
            if !template.requires.isEmpty {
                requirementsList(template.requires)
            }
            if let collision {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(theme.warningColor)
                        Text("A template named \"\(collision.name)\" already exists.", bundle: .module)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.primaryText)
                    }
                    HStack(spacing: 12) {
                        Text("Replace the existing template", bundle: .module)
                            .font(.system(size: 12))
                            .foregroundColor(theme.secondaryText)
                        Spacer(minLength: 12)
                        Toggle("", isOn: $overwrite)
                            .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                            .labelsHidden()
                    }
                    Text("Or change the `name` in the JSON above to keep both.", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.warningColor.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10).strokeBorder(theme.warningColor.opacity(0.25), lineWidth: 1))
                )
            }
        }
    }

    private func requirementsList(_ requires: [TemplateRequirement]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Needs on this Mac", bundle: .module)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.secondaryText)
            ForEach(requires) { requirement in
                HStack(spacing: 8) {
                    Image(systemName: requirement.kind.icon)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.tertiaryText)
                        .frame(width: 14)
                    Text(requirement.kind.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                    Text(requirement.label ?? requirement.value)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.tertiaryBackground.opacity(0.6)))
    }

    private func detail(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .medium))
            Text(text).font(.system(size: 10, weight: .medium)).lineLimit(1)
        }
        .foregroundColor(theme.tertiaryText)
    }

    private func errorBox(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "xmark.octagon.fill").foregroundColor(theme.errorColor)
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.errorColor.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.errorColor.opacity(0.25), lineWidth: 1))
        )
    }

    private func reparse() {
        overwrite = false
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            parsed = nil
            parseError = nil
            return
        }
        do {
            parsed = try AgentTemplate.parse(trimmed)
            parseError = nil
        } catch {
            parsed = nil
            parseError = error.localizedDescription
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json, .yaml, .plainText]
        panel.title = L("Import Template")
        Task { @MainActor in
            guard await panel.beginModal() == .OK, let url = panel.url else { return }
            if let contents = try? String(contentsOf: url, encoding: .utf8) {
                text = contents
            } else {
                parseError = L("Could not read \(url.lastPathComponent)")
            }
        }
    }

    private func performImport() {
        guard let parsed else { return }
        do {
            try store.save(parsed)
            onImported(parsed)
        } catch {
            parseError = error.localizedDescription
        }
    }
}

// MARK: - Save as template

struct SaveAgentTemplateSheet: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var store = AgentTemplateStore.shared

    let agent: Agent
    let onSaved: (AgentTemplate) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var summary: String = ""
    @State private var availableToOrchestrator = true
    /// Sections the user chose to leave out of the shared JSON.
    @State private var excluded: Set<AgentTemplate.Section> = []
    @State private var draft: AgentTemplate?
    @State private var errorMessage: String?
    @State private var hasAppeared = false

    private var collision: AgentTemplate? {
        let slug = AgentTemplate.slug(for: name)
        return store.templates.first { $0.id == slug }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            AgentSheetHeader(
                icon: "square.on.square.dashed",
                title: "Save as Template",
                subtitleText: agent.name,
                onClose: onCancel
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        AgentSheetSectionLabel("Template Name")
                        StyledTextField(placeholder: L("e.g., Cloud Agent"), text: $name, icon: "textformat")
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(theme.warningColor.opacity(collision == nil ? 0 : 0.7), lineWidth: 1)
                            )
                        if let collision {
                            // Inline, under the field it concerns: the footer
                            // button reads Replace Template while this shows.
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 10, weight: .semibold))
                                    .padding(.top, 1)
                                Text("A template named \"\(collision.name)\" already exists. Saving replaces it.", bundle: .module)
                                    .font(.system(size: 11))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .foregroundColor(theme.warningColor)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        AgentSheetSectionLabel("Summary")
                        StyledTextField(
                            placeholder: L("One line about what this agent is for"), text: $summary,
                            icon: "text.alignleft")
                    }
                    includeSection
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Available to the Orchestrator", bundle: .module)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(theme.primaryText)
                            Text(
                                "Lets the Orchestrator base new agents on this template when you ask for it by name.",
                                bundle: .module
                            )
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        Toggle("", isOn: $availableToOrchestrator)
                            .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                            .labelsHidden()
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.tertiaryBackground.opacity(0.6)))
                    if let draft, !draft.requires.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            AgentSheetSectionLabel("Travels With the Template")
                            Text(
                                "Whoever imports this will be asked to set these up on their Mac.",
                                bundle: .module
                            )
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                            ForEach(draft.requires) { requirement in
                                HStack(spacing: 8) {
                                    Image(systemName: requirement.kind.icon)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(theme.tertiaryText)
                                        .frame(width: 14)
                                    Text(requirement.kind.title)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(theme.secondaryText)
                                    Text(requirement.label ?? requirement.value)
                                        .font(.system(size: 11))
                                        .foregroundColor(theme.tertiaryText)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(theme.tertiaryBackground.opacity(0.6)))
                    }
                    if let errorMessage {
                        Text(errorMessage).font(.system(size: 12)).foregroundColor(theme.errorColor)
                    }
                    Text(
                        "Secrets, folder access and knowledge files never travel. Only the configuration does.",
                        bundle: .module
                    )
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            AgentSheetFooter(
                primary: AgentSheetFooter.Action(
                    label: collision == nil ? "Save Template" : "Replace Template",
                    isEnabled: canSave, handler: save),
                secondary: AgentSheetFooter.Action(label: "Cancel", handler: onCancel),
                hint: nil
            )
        }
        .fittedSheetFrame(width: 560, height: 660)
        .background(theme.primaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.primaryBorder.opacity(0.5), lineWidth: 1))
        .opacity(hasAppeared ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: hasAppeared)
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

    /// What goes into the JSON. Everything is on by default; a user who
    /// wants to share a tool setup but keep the prompt private, or drop the
    /// folder hint, flips the section off here.
    private var includeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            AgentSheetSectionLabel("Include in Template")
            VStack(spacing: 0) {
                ForEach(Array(availableSections.enumerated()), id: \.element) { index, section in
                    if index > 0 { Divider().opacity(0.4) }
                    HStack(spacing: 12) {
                        Image(systemName: Self.icon(for: section))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.tertiaryText)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Self.title(for: section))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(theme.primaryText)
                            if let preview = preview(for: section) {
                                Text(preview)
                                    .font(.system(size: 10))
                                    .foregroundColor(theme.tertiaryText)
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
                            .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                            .labelsHidden()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.tertiaryBackground.opacity(0.6)))
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
            case .tools: return entry.tools?.mode == "manual" || entry.mcpServers != nil || entry.plugins != nil
            case .sandbox: return entry.sandbox != nil
            case .subagents: return entry.subagents?.enabled == true
            case .workingFolder: return entry.workingFolder.valueOrNil != nil
            case .knowledge: return entry.capabilities?.knowledgeEnabled == true || !draft.knowledgeCollectionNames.isEmpty
            case .pluginInstructions: return !(entry.pluginInstructions ?? [:]).isEmpty
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
            return L("\(count) tools")
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
        case .pluginInstructions: return L("\(entry.pluginInstructions?.count ?? 0) plugins")
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
        }
    }

    private func save() {
        let template = AgentTemplate.make(
            from: agent,
            name: name,
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : summary,
            availableToOrchestrator: availableToOrchestrator
        ).excluding(excluded)
        do {
            try store.save(template)
            onSaved(template)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Rename

struct RenameAgentTemplateSheet: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var store = AgentTemplateStore.shared

    let template: AgentTemplate
    let onDone: () -> Void

    @State private var name: String = ""
    @State private var errorMessage: String?

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var collides: Bool {
        let slug = AgentTemplate.slug(for: trimmed)
        return slug != template.id && store.templates.contains { $0.id == slug }
    }

    var body: some View {
        VStack(spacing: 0) {
            AgentSheetHeader(icon: "pencil", title: "Rename Template", subtitleText: template.name, onClose: onDone)
            VStack(alignment: .leading, spacing: 8) {
                AgentSheetSectionLabel("New Name")
                StyledTextField(placeholder: L("Template Name"), text: $name, icon: "textformat")
                if collides {
                    Text("Another template already uses this name.", bundle: .module)
                        .font(.system(size: 11)).foregroundColor(theme.warningColor)
                }
                if let errorMessage {
                    Text(errorMessage).font(.system(size: 11)).foregroundColor(theme.errorColor)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            AgentSheetFooter(
                primary: AgentSheetFooter.Action(
                    label: "Rename", isEnabled: !trimmed.isEmpty && !collides && trimmed != template.name,
                    handler: rename),
                secondary: AgentSheetFooter.Action(label: "Cancel", handler: onDone),
                hint: nil
            )
        }
        .fittedSheetFrame(width: 440, height: 240)
        .background(theme.primaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.primaryBorder.opacity(0.5), lineWidth: 1))
        .onAppear { if name.isEmpty { name = template.name } }
    }

    private func rename() {
        do {
            try store.rename(slug: template.id, to: trimmed)
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
        }
    }
}
