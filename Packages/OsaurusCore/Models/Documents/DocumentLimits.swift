//
//  DocumentLimits.swift
//  osaurus
//
//  Per-format byte ceilings applied to in-memory parsing. Streaming
//  adapters are not bound by these caps — they negotiate back-pressure
//  with their caller — but any adapter that reads the whole file into
//  memory must honour the limit returned by `limit(forFormatId:)`.
//
//  The numeric defaults here are intentionally generous compared to the
//  500 KB text cap on the legacy `DocumentParser`. They exist to prevent
//  OOM under adversarial input, not to shape the user-facing attachment
//  experience; the chat attachment flow keeps its own smaller caps.
//

import Foundation

public enum DocumentLimits {
    public static let plainText: Int64 = 5 * 1024 * 1024
    public static let csv: Int64 = 25 * 1024 * 1024
    public static let xlsx: Int64 = 50 * 1024 * 1024
    public static let pdf: Int64 = 100 * 1024 * 1024
    public static let docx: Int64 = 50 * 1024 * 1024

    /// Fallback for formats that haven't been assigned a tuned cap.
    public static let defaultLimit: Int64 = 10 * 1024 * 1024

    public static func limit(forFormatId id: String) -> Int64 {
        switch id.lowercased() {
        case "plaintext", "text", "txt", "md", "markdown": return plainText
        case "csv", "tsv": return csv
        case "xlsx", "xls", "ods": return xlsx
        case "pdf": return pdf
        case "docx", "doc", "rtf": return docx
        default: return defaultLimit
        }
    }
}
