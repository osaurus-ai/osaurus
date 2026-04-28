//
//  DocumentFormatEmitter.swift
//  osaurus
//
//  Write-side handler for a single file format. Deliberately split from
//  `DocumentFormatAdapter` so read-only formats (XLS, OFX 1.x, PPTX in
//  the stage-2 priority list) don't have to carry a stub writer. Sandbox
//  containment and destination checking live in the caller
//  (`ShareArtifactTool` today); emitters are just byte producers.
//

import Foundation

public protocol DocumentFormatEmitter: Sendable {
    var formatId: String { get }

    /// Keyed on the concrete shape of `document.representation`, not on
    /// the file extension — an emitter produces exactly one representation
    /// shape, so the registry uses this hook to pick the right writer.
    func canEmit(_ document: StructuredDocument) -> Bool

    /// Write the document to `url`. The caller is responsible for having
    /// already resolved and contained `url`; the emitter writes raw bytes.
    func emit(_ document: StructuredDocument, to url: URL) async throws
}
