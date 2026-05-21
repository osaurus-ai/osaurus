//
//  FolderPluginHints.swift
//  osaurus
//
//  Static lookup mapping detected file extensions in the working folder
//  to the plugin id that knows how to handle them. Used by preflight to
//  deterministically inject those plugins' tools when the user has them
//  installed — agents shouldn't have to guess that "summarize this file"
//  in a folder full of `.xlsx` needs the spreadsheet plugin.
//
//  Bias-only: a missing plugin is silently dropped. The onboarding flow
//  ships `osaurus.xlsx` default-on and `osaurus.pptx` opt-in; users who
//  declined them won't suddenly see install side-effects from picking a
//  folder.
//

import Foundation

enum FolderPluginHints {
    /// Extension (lowercased, no leading dot) → plugin id.
    /// Multiple extensions may map to the same plugin (the xlsx plugin
    /// also builds spreadsheets from `.csv` input). Add entries here as
    /// new file-format plugins land in the catalog.
    ///
    /// Criterion for inclusion: core's `DocumentFormatRegistry` adapters
    /// can already READ this format (`PDFAdapter`, `RichDocumentAdapter`,
    /// etc.), so an entry only earns its place when a plugin adds value
    /// beyond reading — typically write/build/generate paths.
    static let extensionToPluginId: [String: String] = [
        "xlsx": "osaurus.xlsx",
        "pptx": "osaurus.pptx",
        // CSV reading is handled by core's `CSVAdapter`. The plugin
        // entry is for the "convert this csv to a real xlsx" / "build a
        // pivot from this csv" flows that need spreadsheet semantics.
        "csv": "osaurus.xlsx",
    ]

    /// All extensions the scanner cares about. Lowercased, no leading dot.
    /// Pulled out so the folder-context scanner can early-exit once it has
    /// seen every key.
    static var watchedExtensions: Set<String> {
        Set(extensionToPluginId.keys)
    }

    /// Plugin ids whose tools should be merged into preflight given a
    /// folder context. Filters by `PluginManager.shared.plugins` so a
    /// detected extension whose plugin isn't installed produces no
    /// effect — keeping with the bias-only contract.
    ///
    /// Order is deterministic (sorted by plugin id) so the resulting
    /// preflight tool list is byte-stable across turns and KV-cache
    /// friendly.
    @MainActor
    static func suggestedPluginIds(for context: FolderContext) -> [String] {
        guard !context.detectedFileExtensions.isEmpty else { return [] }
        let installed = Set(PluginManager.shared.plugins.map { $0.plugin.id })
        return suggestedPluginIds(
            extensions: context.detectedFileExtensions,
            installedPluginIds: installed
        )
    }

    /// Pure form of `suggestedPluginIds(for:)` — same lookup + sort
    /// rules, but the installed-plugin set is injected. Lets unit tests
    /// exercise the table mapping without standing up `PluginManager`.
    static func suggestedPluginIds(
        extensions: Set<String>,
        installedPluginIds: Set<String>
    ) -> [String] {
        var ids: Set<String> = []
        for ext in extensions {
            guard let pluginId = extensionToPluginId[ext],
                installedPluginIds.contains(pluginId)
            else { continue }
            ids.insert(pluginId)
        }
        return ids.sorted()
    }
}
