//
//  TemplateFileExport.swift
//  osaurus
//
//  How a template leaves or enters the Mac as a file: Export File writes a
//  sanitized `.osaurustemplate` (JSON) through a save panel, signed with
//  the master key whenever this Mac has an Osaurus identity, and a dropped
//  or chosen file is read for the import sheet. There is no link,
//  clipboard, or paste path.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum TemplateFileExport {
    static let fileExtension = "osaurustemplate"

    static var contentType: UTType {
        UTType(filenameExtension: fileExtension, conformingTo: .json) ?? .json
    }

    /// Types the import panel and drop target accept. Plain `.json` stays
    /// accepted so a template renamed by a mail client still opens.
    static var importTypes: [UTType] { [contentType, .json] }

    static let maxImportBytes = 2 * 1024 * 1024

    static func suggestedFileName(_ template: Template) -> String {
        "\(template.slug)-v\(template.version).\(fileExtension)"
    }

    /// The exact bytes written: the sanitized template, bundles included.
    static func exportData(_ template: Template) throws -> Data {
        Data(try TemplateExportSanitizer.sanitized(template).jsonString().utf8)
    }

    /// Where to write `template`; nil when the user cancels.
    @MainActor
    static func chooseDestination(for template: Template, signing: Bool) async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = suggestedFileName(template)
        panel.title = L("Export Template")
        panel.message =
            signing
            ? L("Signed with your Osaurus ID. Saved answers, secret values, bindings, run history, and absolute paths are left out.")
            : L("Saved answers, secret values, bindings, run history, and absolute paths are left out.")
        guard await panel.beginModal() == .OK else { return nil }
        return panel.url
    }

    enum SignOutcome: Equatable {
        case signed
        case unsigned
        /// Signing was asked for and did not finish (declined or failed);
        /// the file was written unsigned.
        case signingFailed(String)
    }

    /// Writes the sanitized template, signed when asked. A signature that
    /// does not finish leaves the file unsigned rather than unwritten.
    @MainActor
    static func write(_ template: Template, to url: URL, sign: Bool, authorName: String?) throws -> SignOutcome {
        let sanitized = TemplateExportSanitizer.sanitized(template)
        var outgoing = sanitized
        var outcome = SignOutcome.unsigned
        if sign {
            do {
                outgoing = try TemplateSigner.signedWithMasterKey(sanitized, authorName: authorName)
                outcome = .signed
            } catch {
                outcome = .signingFailed(error.localizedDescription)
            }
        } else if let authorName {
            outgoing.author = TemplateAuthor(name: authorName, address: nil)
            outgoing = outgoing.sealed()
        }
        try exportData(outgoing).write(to: url, options: .atomic)
        return outcome
    }

    /// Export File: asks where to save, then writes the template signed
    /// with the master key when this Mac has one. An unsigned file carries
    /// no author name: without the signature it would be an unverifiable
    /// claim.
    @MainActor
    static func export(_ template: Template) {
        let signs = MasterKey.exists()
        let authorName = signs ? OsaurusIDService.shared.claimedHandle.map { "@" + $0 } : nil
        Task { @MainActor in
            guard let url = await chooseDestination(for: template, signing: signs) else { return }
            do {
                let outcome = try write(template, to: url, sign: signs, authorName: authorName)
                let message: String? = {
                    if case .signingFailed = outcome { return L("It's unsigned because signing didn't finish.") }
                    return nil
                }()
                ToastManager.shared.action(
                    L("Saved \"\(template.name)\""), message: message, action: .revealInFinder(url),
                    buttonTitle: L("Show in Finder"))
            } catch {
                ToastManager.shared.error(L("Could not export \"\(template.name)\""), message: error.localizedDescription)
            }
        }
    }

    static func readFile(_ url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? Int, size > maxImportBytes {
            throw TemplateStore.StoreError.tooLarge
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    @MainActor
    static func chooseFile(onText: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = importTypes
        panel.title = L("Import Template")
        Task { @MainActor in
            guard await panel.beginModal() == .OK, let url = panel.url else { return }
            do {
                onText(try readFile(url))
            } catch {
                onError(L("Could not read \(url.lastPathComponent): \(error.localizedDescription)"))
            }
        }
    }

    /// Accepts one dropped file URL. Dropped text is not accepted.
    static func loadDroppedFile(
        _ providers: [NSItemProvider],
        onText: @escaping (String) -> Void,
        onError: @escaping (String) -> Void
    ) -> Bool {
        // Called from a main-actor view; the callbacks only run back on main.
        nonisolated(unsafe) let onText = onText
        nonisolated(unsafe) let onError = onError
        guard let provider = providers.first, provider.canLoadObject(ofClass: URL.self) else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.isFileURL else { return }
            let result = Result { try readFile(url) }
            Task { @MainActor in
                switch result {
                case .success(let text): onText(text)
                case .failure(let error):
                    onError(L("Could not read \(url.lastPathComponent): \(error.localizedDescription)"))
                }
            }
        }
        return true
    }
}
