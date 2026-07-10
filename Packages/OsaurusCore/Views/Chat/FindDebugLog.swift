//
//  FindDebugLog.swift
//  osaurus
//
//  TEMPORARY instrumentation for the Cmd+F scroll accuracy bug (issue
//  #1964 follow-up): appends timestamped lines to <repo>/tmp/
//  find-scroll-debug.log so match-jump requests, occurrence→block
//  mapping, and the actual AppKit scroll can be correlated after a
//  repro session. Remove once the scroll bug is fixed.
//

import Foundation

enum FindDebugLog {
    /// Repo-root/tmp/find-scroll-debug.log, derived from this source
    /// file's compile-time path (…/Packages/OsaurusCore/Views/Chat/
    /// FindDebugLog.swift → five components up) so any checkout logs
    /// into its own workspace without a hardcoded machine path.
    private static let url: URL = {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { dir.deleteLastPathComponent() }
        dir.appendPathComponent("tmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("find-scroll-debug.log")
    }()

    /// Serial background queue: appends must never block the main thread.
    private static let queue = DispatchQueue(label: "com.osaurus.find-debug-log", qos: .utility)

    private static let timestamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func log(_ message: String) {
        // Build the line on the caller's thread (message may interpolate
        // main-thread-only view state); only the file I/O hops queues.
        let line = "\(timestamp.string(from: Date())) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
