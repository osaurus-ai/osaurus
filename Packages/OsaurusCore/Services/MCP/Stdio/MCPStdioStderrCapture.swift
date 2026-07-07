//
//  MCPStdioStderrCapture.swift
//  OsaurusCore
//
//  Ring buffer for stdio MCP subprocess stderr. Used by host and sandbox
//  runners so unexpected exits surface the last diagnostic lines in UI.
//

import Foundation

/// Thread-safe stderr line ring buffer for MCP stdio subprocesses.
public final class MCPStdioStderrCapture: @unchecked Sendable {
    public static let defaultLineLimit = 32
    public static let defaultTailLength = 2_048

    private let lock = NSLock()
    private var lines: [String] = []
    private let lineLimit: Int

    public init(lineLimit: Int = defaultLineLimit) {
        self.lineLimit = lineLimit
    }

    public func append(_ data: Data) {
        guard !data.isEmpty else { return }
        let text = String(decoding: data, as: UTF8.self)
        lock.lock()
        defer { lock.unlock() }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            lines.append(trimmed)
            if lines.count > lineLimit {
                lines.removeFirst(lines.count - lineLimit)
            }
        }
    }

    public func tail(maxLength: Int = defaultTailLength) -> String {
        lock.lock()
        defer { lock.unlock() }
        let joined = lines.joined(separator: "\n")
        guard joined.count > maxLength else { return joined }
        return "…" + String(joined.suffix(maxLength))
    }
}
