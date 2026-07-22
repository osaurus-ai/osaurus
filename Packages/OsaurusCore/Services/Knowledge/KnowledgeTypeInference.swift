//
//  KnowledgeTypeInference.swift
//  osaurus
//
//  Derives a document category when frontmatter carries no `type`, so
//  users get type-filterable collections without hand-editing files.
//  Inference is metadata-only: results live in the index's
//  `inferred_type` column and the files on disk are never modified.
//  An explicit frontmatter `type` always wins over inference.
//

import Foundation

public enum KnowledgeTypeInference {
    /// Infer a category from the document's location: the top-level
    /// folder it lives in, slugified. Users who organize a collection
    /// into subfolders ("Medical Records/", "recipes/") have already
    /// categorized their documents — reuse that. Returns "" for
    /// root-level files, which a later classification pass may fill in.
    public static func infer(relPath: String) -> String {
        guard let slash = relPath.firstIndex(of: "/") else { return "" }
        return slugify(String(relPath[..<slash]))
    }

    /// Lowercased, whitespace/underscores collapsed to single dashes,
    /// anything non-alphanumeric dropped — mirrors how explicit `type`
    /// values are conventionally written (e.g. "meeting-notes").
    static func slugify(_ raw: String) -> String {
        var out = ""
        var pendingDash = false
        for scalar in raw.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingDash && !out.isEmpty { out.append("-") }
                pendingDash = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        return out
    }
}
