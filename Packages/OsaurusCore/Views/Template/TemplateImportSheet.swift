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
    /// The host a deep link downloaded `initialText` from; shown first so
    /// the person knows where the file came from.
    var sourceHost: String? = nil
    /// Restricts the sheet to one kind (the Agents tab imports agents). A
    /// file of the other kind closes this sheet and reopens on its own tab.
    var expectedKind: TemplateKind? = nil
    /// The primary button for a new template, when the caller does more
    /// than save it (Workflows adds it right after).
    var importLabel: LocalizedStringKey = "Import"
    /// The saved template, and the bundled workflows this import added to
    /// the library (new, or a newer version).
    let onImported: (_ template: Template, _ bundled: [Template]) -> Void
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
        VStack(spacing: theme.space.s0) {
            SettingsSheetHeader(
                icon: "square.and.arrow.down",
                title: "Import Template",
                subtitle: "Choose a template file or drop one here",
                onClose: onCancel
            )
            ScrollView {
                VStack(alignment: .leading, spacing: theme.space.s16) {
                    if let sourceHost, !sourceHost.isEmpty {
                        note(
                            "link",
                            L(
                                "Downloaded from \(sourceHost). Review what it does before importing; it will be set up, not run, after import."
                            ),
                            tint: theme.status.info.foreground
                        )
                    }
                    if let parsed {
                        TemplateImportReviewView(template: parsed)
                        dispositionBox(parsed)
                    } else {
                        dropZone
                    }
                    if let parseError { errorBox(parseError) }
                }
                .padding(theme.space.s16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            SettingsSheetFooter(
                primary: primaryAction,
                secondary: SettingsSheetFooter.Action(label: "Cancel", handler: onCancel),
                hint: nil
            )
        }
        .fittedSheetFrame(width: 640, height: 620)
        .settingsSheetSurface()
        .overlay(RoundedRectangle(cornerRadius: theme.radius.xlarge).stroke(theme.border.subtle, lineWidth: theme.stroke.default))
        .opacity(hasAppeared ? 1 : 0)
        .animation(theme.motion.quick, value: hasAppeared)
        .onAppear {
            hasAppeared = true
            if parsed == nil, !initialText.isEmpty { parse(initialText) }
        }
    }

    private var dropZone: some View {
        VStack(spacing: theme.space.s12) {
            Image(systemName: "doc.badge.plus")
                .glyphSize(.display, weight: .light)
                .foregroundColor(isDropTargeted ? theme.text.link : theme.text.tertiary)
            Text("Drop a .osaurustemplate file here", bundle: .module)
                .font(SettingsFont.rowTitle)
                .foregroundColor(theme.text.primary)
            Button {
                TemplateFileExport.chooseFile(onText: parse, onError: { parseError = $0 })
            } label: {
                Label { Text("Choose File…", bundle: .module) } icon: { Image(systemName: "folder") }
                    .font(SettingsFont.compactLabel)
            }
            .assignedSettingsButtonStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .background(
            RoundedRectangle(cornerRadius: theme.radius.large)
                .strokeBorder(
                    isDropTargeted ? theme.action.primary.default.background : theme.border.strong,
                    style: StrokeStyle(lineWidth: theme.stroke.default, dash: [6, 5])
                )
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            TemplateFileExport.loadDroppedFile(providers, onText: parse, onError: { parseError = $0 })
        }
    }

    @ViewBuilder
    private func dispositionBox(_ template: Template) -> some View {
        switch disposition {
        case .alreadyPresent?:
            note(
                "checkmark.circle",
                L("This exact version is already in your library."),
                tint: theme.status.success.foreground
            )
        case .update(let from)?:
            note(
                "arrow.up.circle",
                L(
                    "Updates \"\(template.name)\" from version \(from) to \(template.version). Installed workflows keep their pin until you update them."
                ),
                tint: theme.status.info.foreground
            )
        case .older(let latest)?:
            note(
                "clock.arrow.circlepath",
                L("You already have version \(latest). This older version is added to its history."),
                tint: theme.text.secondary
            )
        case .signerMismatch(let address)?:
            VStack(alignment: .leading, spacing: theme.space.s8) {
                note(
                    "exclamationmark.triangle.fill",
                    L(
                        "Your copy of this template is signed by \(SharedAgentIdentity.shortAddress(address)) and this file is not. It can only be imported as a copy."
                    ),
                    tint: theme.status.warning.foreground
                )
                SettingsTextField(placeholder: L("Name for the copy"), text: $copyName, icon: "textformat")
            }
        case .conflict?:
            VStack(alignment: .leading, spacing: theme.space.s8) {
                note(
                    "exclamationmark.triangle.fill",
                    L("Version \(template.version) of this template is already here with different content."),
                    tint: theme.status.warning.foreground
                )
                AssignedBaseSegmentedPicker(
                    selection: $keepBoth,
                    options: [.init(true, "Keep both"), .init(false, "Replace")]
                )
                if keepBoth {
                    SettingsTextField(placeholder: L("Name for the copy"), text: $copyName, icon: "textformat")
                } else {
                    Text("Replacing saves the incoming content as the next version. History is kept.", bundle: .module)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
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

    private var primaryAction: SettingsSheetFooter.Action {
        guard let parsed, let disposition else {
            return SettingsSheetFooter.Action(label: "Import", isEnabled: false, handler: {})
        }
        if signatureBlocks {
            return SettingsSheetFooter.Action(label: "Import", isEnabled: false, handler: {})
        }
        switch disposition {
        case .alreadyPresent:
            return SettingsSheetFooter.Action(label: "Done") { onImported(store.latest(id: parsed.id) ?? parsed, []) }
        case .update:
            return SettingsSheetFooter.Action(label: "Import Update", handler: performImport)
        case .new where parsed.kind == expectedKind:
            return SettingsSheetFooter.Action(label: importLabel, handler: performImport)
        case .conflict:
            let name = copyName.trimmingCharacters(in: .whitespacesAndNewlines)
            return SettingsSheetFooter.Action(
                label: keepBoth ? "Import Copy" : "Replace",
                isEnabled: !keepBoth || !name.isEmpty,
                isDestructive: !keepBoth,
                handler: performImport)
        case .signerMismatch:
            let name = copyName.trimmingCharacters(in: .whitespacesAndNewlines)
            return SettingsSheetFooter.Action(label: "Import Copy", isEnabled: !name.isEmpty, handler: performImport)
        case .new, .older:
            return SettingsSheetFooter.Action(label: "Import", handler: performImport)
        }
    }

    private func parse(_ text: String) {
        parseError = nil
        do {
            let template = try Template.parse(text)
            if let expectedKind, template.kind != expectedKind {
                parsed = nil
                onCancel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    TemplateImportRouter.present(text: text)
                }
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
            let bundled = try parsed.bundled.filter { try TemplateBundleImport.importBundled($0, into: store) }
            let name = copyName.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolution: TemplateStore.ConflictResolution? = {
                switch disposition {
                case .conflict?: return keepBoth ? .keepBoth(name: name) : .replace
                case .signerMismatch?: return .keepBoth(name: name)
                default: return nil
                }
            }()
            let saved = try store.importTemplate(parsed, resolution: resolution)
            FeatureTelemetry.templateImported(
                kind: parsed.kind.rawValue,
                origin: sourceHost == nil ? "file" : "registry",
                result: Self.importResultToken(disposition, keepBoth: keepBoth))
            onImported(saved, bundled)
        } catch {
            parseError = error.localizedDescription
        }
    }

    /// Closed `template_imported` result token.
    static func importResultToken(_ disposition: TemplateStore.ImportDisposition?, keepBoth: Bool) -> String {
        switch disposition {
        case .update?: return "update"
        case .conflict?: return keepBoth ? "copy" : "replace"
        case .signerMismatch?: return "copy"
        case .older?: return "older"
        case .alreadyPresent?: return "already_present"
        case .new?, nil: return "new"
        }
    }

    private func note(_ icon: String, _ text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: theme.space.s8) {
            Image(systemName: icon).foregroundColor(tint)
            Text(text)
                .font(SettingsFont.caption)
                .foregroundColor(theme.text.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(theme.space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(.tinted(tint))
    }

    private func errorBox(_ message: String) -> some View {
        note("xmark.octagon.fill", message, tint: theme.status.error.foreground)
    }
}

/// Bundled workflow templates land in the library with their agent. A
/// copy already here at the same or a higher version is reused; a higher
/// incoming version is stored (installed workflows then offer the update);
/// a same-version content conflict keeps the local copy, which the agent's
/// reference resolves to.
enum TemplateBundleImport {
    /// True when the copy was stored.
    @MainActor @discardableResult
    static func importBundled(_ bundled: Template, into store: TemplateStore) throws -> Bool {
        switch store.disposition(for: bundled) {
        case .new, .update:
            try store.importTemplate(bundled)
            return true
        case .alreadyPresent, .older, .conflict, .signerMismatch:
            return false
        }
    }
}
