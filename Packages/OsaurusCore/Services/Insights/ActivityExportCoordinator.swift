//
//  ActivityExportCoordinator.swift
//  osaurus
//
//  Save-panel glue for exporting the Insights activity log. Streams rows
//  out of `ActivityLogStore` (so a large log never has to fit in the UI's
//  page), runs a chain verification to embed in the manifest, renders via
//  `ActivityExportService`, and writes atomically.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
enum ActivityExportCoordinator {
    static func run(options: ActivityExportOptions, filter: ActivityFilter) {
        let service = InsightsService.shared
        let effectiveFilter = options.filteredOnly ? filter : .empty

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = ActivityExportService.suggestedFilename(format: options.format)
        panel.allowedContentTypes = [
            UTType(filenameExtension: options.format.fileExtension) ?? .plainText
        ]
        panel.title = L("Export Activity Log")

        Task { @MainActor in
            guard await panel.beginModal() == .OK, let url = panel.url else { return }
            let store = service.activityStore
            let hotRows = service.logs
            let result: Result<Int, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    var rows: [RequestLog] = []
                    var verification: ActivityLogVerification?
                    if let store {
                        try store.forEach(filter: effectiveFilter) { rows.append($0) }
                        verification = try? store.verify()
                    } else {
                        rows = InsightsService.filterInMemory(hotRows, effectiveFilter)
                    }
                    let data = try ActivityExportService.render(
                        logs: rows,
                        options: options,
                        filterDescription: ActivityExportService.describe(effectiveFilter),
                        verification: verification
                    )
                    try data.write(to: url, options: [.atomic])
                    // Chain-of-custody: the export itself goes on the chain
                    // (after the file is written, so the file's manifest
                    // reflects the head *before* this row). Leaf name only —
                    // never the user's folder layout.
                    if let store {
                        var details: [String: String] = [
                            "format": options.format.rawValue,
                            "records": String(rows.count),
                            "include_content": options.includeContent ? "true" : "false",
                            "filter": options.filteredOnly ? ActivityExportService.describe(effectiveFilter) : "all",
                            "file_name": url.lastPathComponent,
                        ]
                        if let hash = verification?.lastHash { details["head_hash"] = hash }
                        if let seq = verification?.lastSeq { details["head_seq"] = String(seq) }
                        _ = try? store.appendSystemEvent("exported", details: details)
                        await MainActor.run { InsightsService.shared.noteExternalStoreChange() }
                    }
                    return .success(rows.count)
                } catch {
                    return .failure(error)
                }
            }.value

            switch result {
            case .success(let count):
                ToastManager.shared.action(
                    L("Export complete"),
                    message: String(format: L("%d records → %@"), count, url.lastPathComponent),
                    action: .revealInFinder(url),
                    buttonTitle: L("Reveal in Finder")
                )
            case .failure(let error):
                let alert = NSAlert()
                alert.messageText = L("Export failed")
                alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: L("OK"))
                alert.runModal()
            }
        }
    }
}
