//
//  TemplateImportSheet.swift
//  osaurus
//
//  Import a template file (Choose File or drop). The file is parsed and
//  reviewed before anything is saved. Identity is id + version + content
//  hash: a new id imports, a higher version is an update, an older one is
//  kept for history, the same version with different content is a
//  conflict resolved as keep both (under a free name) or replace.
//  Nothing in the template runs here.
//

import SwiftUI
import UniformTypeIdentifiers

struct TemplateImportSheet: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var store = TemplateStore.shared

    /// A dropped file's contents. Empty opens on the file chooser.
    var initialText: String = ""
    /// Restricts the sheet to one kind (the Agents tab imports agents).
    var expectedKind: TemplateKind? = nil
    /// The primary button for a new template, when the caller does more
    /// than save it.
    var importLabel: LocalizedStringKey = "Import"
    let onImported: (Template) -> Void
    let onCancel: () -> Void

    @State private var parsed: Template?
    @State private var parseError: String?
    @State private var keepBoth = true
    @State private var copyName = ""
    @State private var isDropTargeted = false
    @State private var hasAppeared = false

    private var disposition: TemplateStore.ImportDisposition? {
        parsed.map { store.disposition(for: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            AgentSheetHeader(
                icon: "square.and.arrow.down",
                title: "Import Template",
                subtitle: "Choose a template file or drop one here",
                onClose: onCancel
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let parsed {
                        TemplateImportReviewView(template: parsed)
                        dispositionBox(parsed)
                    } else {
                        dropZone
                    }
                    if let parseError { errorBox(parseError) }
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            AgentSheetFooter(
                primary: primaryAction,
                secondary: AgentSheetFooter.Action(label: "Cancel", handler: onCancel),
                hint: nil
            )
        }
        .fittedSheetFrame(width: 640, height: 620)
        .background(theme.primaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.primaryBorder.opacity(0.5), lineWidth: 1))
        .opacity(hasAppeared ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: hasAppeared)
        .onAppear {
            hasAppeared = true
            if parsed == nil, !initialText.isEmpty { parse(initialText) }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(isDropTargeted ? theme.accentColor : theme.tertiaryText)
            Text("Drop a .osaurustemplate file here", bundle: .module)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.primaryText)
            Button {
                TemplateFileExport.chooseFile(onText: parse, onError: { parseError = $0 })
            } label: {
                Label { Text("Choose File…", bundle: .module) } icon: { Image(systemName: "folder") }
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isDropTargeted ? theme.accentColor : theme.inputBorder,
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            TemplateFileExport.loadDroppedFile(providers, onText: parse, onError: { parseError = $0 })
        }
    }

    @ViewBuilder
    private func dispositionBox(_ template: Template) -> some View {
        switch disposition {
        case .alreadyPresent?:
            note("checkmark.circle", L("This exact version is already in your library."), tint: theme.successColor)
        case .update(let from)?:
            note(
                "arrow.up.circle",
                L("Updates \"\(template.name)\" from version \(from) to \(template.version)."),
                tint: theme.infoColor)
        case .older(let latest)?:
            note(
                "clock.arrow.circlepath",
                L("You already have version \(latest). This older version is added to its history."),
                tint: theme.secondaryText)
        case .signerMismatch(let address)?:
            VStack(alignment: .leading, spacing: 8) {
                note(
                    "exclamationmark.triangle.fill",
                    L("Your copy of this template is signed by \(SharedAgentIdentity.shortAddress(address)) and this file is not. It can only be imported as a copy."),
                    tint: theme.warningColor)
                StyledTextField(placeholder: L("Name for the copy"), text: $copyName, icon: "textformat")
            }
        case .conflict?:
            VStack(alignment: .leading, spacing: 8) {
                note(
                    "exclamationmark.triangle.fill",
                    L("Version \(template.version) of this template is already here with different content."),
                    tint: theme.warningColor)
                Picker("", selection: $keepBoth) {
                    Text("Keep both", bundle: .module).tag(true)
                    Text("Replace", bundle: .module).tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if keepBoth {
                    StyledTextField(placeholder: L("Name for the copy"), text: $copyName, icon: "textformat")
                } else {
                    Text("Replacing saves the incoming content as the next version. History is kept.", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                }
            }
        case .new?, nil:
            EmptyView()
        }
    }

    /// A signed file whose signature no longer verifies is shown but
    /// never imported.
    private var signatureBlocks: Bool {
        guard let parsed else { return false }
        return parsed.author?.isSigned == true && !TemplateSigner.status(of: parsed).isValidSignature
    }

    private var primaryAction: AgentSheetFooter.Action {
        guard let parsed, let disposition else {
            return AgentSheetFooter.Action(label: "Import", isEnabled: false, handler: {})
        }
        if signatureBlocks {
            return AgentSheetFooter.Action(label: "Import", isEnabled: false, handler: {})
        }
        switch disposition {
        case .alreadyPresent:
            return AgentSheetFooter.Action(label: "Done") { onImported(store.latest(id: parsed.id) ?? parsed) }
        case .update:
            return AgentSheetFooter.Action(label: "Import Update", handler: performImport)
        case .new where parsed.kind == expectedKind:
            return AgentSheetFooter.Action(label: importLabel, handler: performImport)
        case .conflict:
            let name = copyName.trimmingCharacters(in: .whitespacesAndNewlines)
            return AgentSheetFooter.Action(
                label: keepBoth ? "Import Copy" : "Replace",
                isEnabled: !keepBoth || !name.isEmpty,
                isDestructive: !keepBoth,
                handler: performImport)
        case .signerMismatch:
            let name = copyName.trimmingCharacters(in: .whitespacesAndNewlines)
            return AgentSheetFooter.Action(label: "Import Copy", isEnabled: !name.isEmpty, handler: performImport)
        case .new, .older:
            return AgentSheetFooter.Action(label: "Import", handler: performImport)
        }
    }

    private func parse(_ text: String) {
        parseError = nil
        do {
            let template = try Template.parse(text)
            if let expectedKind, template.kind != expectedKind {
                parsed = nil
                parseError = TemplateError.wrongKind(expected: expectedKind, got: template.kind.rawValue).localizedDescription
                return
            }
            parsed = template
            copyName = Template.availableName(for: template.name, takenSlugs: store.takenSlugs)
        } catch {
            parsed = nil
            parseError = error.localizedDescription
        }
    }

    private func performImport() {
        guard let parsed else { return }
        do {
            let name = copyName.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolution: TemplateStore.ConflictResolution? = {
                switch disposition {
                case .conflict?: return keepBoth ? .keepBoth(name: name) : .replace
                case .signerMismatch?: return .keepBoth(name: name)
                default: return nil
                }
            }()
            let saved = try store.importTemplate(parsed, resolution: resolution)
            onImported(saved)
        } catch {
            parseError = error.localizedDescription
        }
    }

    private func note(_ icon: String, _ text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundColor(tint)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.08)))
    }

    private func errorBox(_ message: String) -> some View {
        note("xmark.octagon.fill", message, tint: theme.errorColor)
    }
}
