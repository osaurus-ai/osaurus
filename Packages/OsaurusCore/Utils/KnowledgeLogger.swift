//
//  KnowledgeLogger.swift
//  osaurus
//
//  Structured logger for the knowledge subsystem using os.Logger.
//  Zero-cost when not collected; filterable in Console.app / Instruments.
//

import Foundation
import os

public enum KnowledgeLogger {
    static let database = Logger(subsystem: "ai.osaurus", category: "knowledge.database")
    static let index = Logger(subsystem: "ai.osaurus", category: "knowledge.index")
    static let search = Logger(subsystem: "ai.osaurus", category: "knowledge.search")
}

// MARK: - File debug log (temporary, for diagnosing search hangs)

/// Appends timestamped, stage-tagged lines to a `.log` file so a hanging
/// `search_knowledge` call can be traced without Console.app. Unlike
/// `os.Logger`, this flushes each line to disk immediately, so the last
/// line written is the stage the call was stuck in when it hung.
///
/// Destination (first that resolves):
///   1. `$OSAURUS_KNOWLEDGE_DEBUG_LOG` if set (absolute file path), else
///   2. `<repo>/tmp/knowledge-debug.log`, where `<repo>` is derived from
///      this source file's compile-time path (machine-independent).
///
/// Debug-only: remove before shipping. Enabled by default; set
/// `OSAURUS_KNOWLEDGE_DEBUG_LOG=off` to silence.
public enum KnowledgeDebugLog {
    private static let queue = DispatchQueue(label: "ai.osaurus.knowledge.debuglog")

    private static let fileURL: URL? = {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["OSAURUS_KNOWLEDGE_DEBUG_LOG"] {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased() == "off" || trimmed.isEmpty { return nil }
            return URL(fileURLWithPath: trimmed)
        }
        // Derive `<repo>/tmp/knowledge-debug.log` from this file's path:
        // .../osaurus/Packages/OsaurusCore/Utils/KnowledgeLogger.swift
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent()  // Utils
            .deletingLastPathComponent()  // OsaurusCore
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // <repo>
        return repoRoot.appendingPathComponent("tmp/knowledge-debug.log")
    }()

    private static let iso: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// Append one line; also mirrors to os.Logger so Console.app still sees it.
    public static func log(_ stage: String, _ message: @autoclosure () -> String = "") {
        guard let url = fileURL else { return }
        let msg = message()
        let line = "\(iso.string(from: Date())) [\(stage)] \(msg)\n"
        KnowledgeLogger.search.debug("\(stage, privacy: .public) \(msg, privacy: .public)")
        queue.async {
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Monotonic elapsed-ms helper for timing a span.
    public static func now() -> DispatchTime { DispatchTime.now() }
    public static func ms(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000
    }
}
