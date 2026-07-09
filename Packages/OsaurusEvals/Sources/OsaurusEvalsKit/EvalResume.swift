//
//  EvalResume.swift
//  OsaurusEvalsKit
//
//  Crash-resumable runs. The CLI writes every completed case row to a
//  `.partial.jsonl` sidecar next to `--out` as it lands (append-only,
//  one compact JSON object per line), so a crash/kill at case 40/50
//  loses nothing. `--resume` reads the sidecar (or, failing that, a
//  previously-written report JSON — e.g. the watchdog's partial report)
//  and carries the COMPLETED rows into the new run, re-running only
//  what's missing: errored rows and rows the watchdog marked as
//  blocked-behind-a-hang are always re-run.
//

import Foundation

public enum EvalResume {

    /// Note prefix `EvalRunner`'s watchdog writes on the rows queued behind
    /// a hung case. Those rows never ran, so a resume must re-run them.
    static let blockedNotePrefix = "blocked: not run"

    /// Sidecar path for incremental per-case rows: `<out>.partial.jsonl`.
    public static func partialSidecarURL(forOut outPath: String) -> URL {
        URL(fileURLWithPath: outPath + ".partial.jsonl")
    }

    /// Rows a resumed run may carry over without re-running: terminal
    /// outcomes only (`passed` / `failed` / genuine `skipped`). `errored`
    /// rows (harness trouble, watchdog timeouts, decode failures) and
    /// watchdog-blocked skips are dropped so they re-run.
    public static func completedRows(_ rows: [EvalCaseReport]) -> [EvalCaseReport] {
        rows.filter { row in
            switch row.outcome {
            case .passed, .failed:
                return true
            case .skipped:
                return !row.notes.contains { $0.hasPrefix(blockedNotePrefix) }
            case .errored:
                return false
            }
        }
    }

    /// Load prior rows for `--resume`: the `.partial.jsonl` sidecar when it
    /// has content, otherwise a previously-written report JSON at `outPath`
    /// (the watchdog's partial report lands there). Returns the raw rows —
    /// callers filter through `completedRows`.
    public static func loadPriorRows(outPath: String) -> [EvalCaseReport] {
        let sidecar = partialSidecarURL(forOut: outPath)
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: sidecar),
            let text = String(data: data, encoding: .utf8)
        {
            let rows = text.split(whereSeparator: \.isNewline).compactMap { line -> EvalCaseReport? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, let rowData = trimmed.data(using: .utf8) else { return nil }
                return try? decoder.decode(EvalCaseReport.self, from: rowData)
            }
            if !rows.isEmpty { return rows }
        }
        if let data = try? Data(contentsOf: URL(fileURLWithPath: outPath)),
            let report = try? decoder.decode(EvalReport.self, from: data)
        {
            return report.cases
        }
        return []
    }
}

/// Append-only JSONL writer for completed case rows. Opened lazily on the
/// first append so a run with zero cases leaves no empty sidecar; call
/// `finalizeSuccess()` after the full report is durably written to remove
/// the sidecar (it exists only to survive crashes mid-run).
public final class EvalPartialRowSink {
    private let url: URL
    private var handle: FileHandle?
    private let encoder: JSONEncoder

    public init?(outPath: String?) {
        guard let outPath else { return nil }
        self.url = EvalResume.partialSidecarURL(forOut: outPath)
        self.encoder = JSONEncoder()
        // Compact single-line rows keep the file append-safe and greppable.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    public func append(_ row: EvalCaseReport) {
        guard let data = try? encoder.encode(row) else { return }
        if handle == nil {
            let fm = FileManager.default
            try? fm.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Truncate any stale sidecar from an older run: its useful rows
            // were already consumed via --resume before this sink was made.
            fm.createFile(atPath: url.path, contents: nil)
            handle = try? FileHandle(forWritingTo: url)
        }
        guard let handle else { return }
        var blob = data
        blob.append(0x0A)
        try? handle.write(contentsOf: blob)
    }

    /// The report JSON is durably written — the crash sidecar is now
    /// redundant, so remove it to keep report dirs clean.
    public func finalizeSuccess() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: url)
    }

    /// Keep the sidecar (the report write failed or never happened).
    public func close() {
        try? handle?.close()
        handle = nil
    }
}
