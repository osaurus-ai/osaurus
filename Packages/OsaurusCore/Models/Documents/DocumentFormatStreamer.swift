//
//  DocumentFormatStreamer.swift
//  osaurus
//
//  Optional streaming read for formats where whole-file-into-memory is
//  not viable — multi-GB CSVs, page-by-page PDFs, row-by-row XLSX.
//  Orthogonal to `DocumentFormatAdapter` so small formats (QIF, MT940)
//  can skip the streaming surface entirely. Callers that can back-
//  pressure (the agent tool surface in particular) prefer streaming when
//  both an adapter and a streamer are registered for the same format.
//

import Foundation

public protocol DocumentFormatStreamer: Sendable {
    associatedtype Element: Sendable

    var formatId: String { get }

    /// Stream format-native records out of the file. `AsyncThrowingStream`
    /// gives callers cancellation and back-pressure without bespoke
    /// plumbing; adapters that can't produce records incrementally should
    /// not conform to this protocol at all.
    func stream(url: URL) -> AsyncThrowingStream<Element, Error>
}
