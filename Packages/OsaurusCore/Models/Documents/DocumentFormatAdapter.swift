//
//  DocumentFormatAdapter.swift
//  osaurus
//
//  Read-side handler for a single file format. Adapters are registered
//  with `DocumentFormatRegistry` at app launch (for in-tree adapters) or
//  at plugin load (for plugin-provided adapters), then looked up every
//  time a file is ingested. `canHandle` is kept separate from `parse` so
//  the registry can iterate candidates without paying parse cost on every
//  file type that doesn't match.
//

import Foundation

public protocol DocumentFormatAdapter: Sendable {
    /// Stable identifier used for logging, registry tie-breaks, and as the
    /// plugin registration key. Examples: "xlsx", "docx", "pdf", "csv".
    var formatId: String { get }

    /// Lightweight precondition check. Must NOT open the file; it is called
    /// before `parse` as the registry enumerates adapters. An adapter that
    /// narrows (e.g. "I only handle PDFs with a tagged text layer") uses
    /// this hook to defer to a more permissive adapter registered later.
    func canHandle(url: URL, uti: String?) -> Bool

    /// Parse a file into its typed representation. Adapters that read the
    /// whole file into memory must throw
    /// `DocumentAdapterError.sizeLimitExceeded` when the file exceeds
    /// `sizeLimit`. Streaming adapters may return a `StructuredDocument`
    /// whose representation carries an async stream (see CSVTable in
    /// stage-4 PR 4). The registry supplies a per-format cap from
    /// `DocumentLimits`.
    func parse(url: URL, sizeLimit: Int64) async throws -> StructuredDocument
}
