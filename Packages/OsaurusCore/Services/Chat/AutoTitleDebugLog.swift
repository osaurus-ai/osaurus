//
//  AutoTitleDebugLog.swift
//  osaurus
//
//  TEMPORARY test instrumentation for the auto-title feature. DO NOT SHIP:
//  drop this file (and its call sites) before pushing the branch.
//
//  Appends timestamped lines to `<repo>/tmp/auto-title-debug.log`. The repo
//  root is derived from `#filePath` at compile time, so the log lands in the
//  checkout that built the app on any dev machine — no hardcoded paths.
//  Writes are handed to a utility-QoS serial queue; the caller (often the
//  main actor) never touches the filesystem.
//

#if DEBUG
    import Foundation

    enum AutoTitleDebugLog {
        private static let queue = DispatchQueue(
            label: "ai.osaurus.autotitle.debuglog",
            qos: .utility
        )

        private static let url: URL = {
            // #filePath = <repo>/Packages/OsaurusCore/Services/Chat/AutoTitleDebugLog.swift
            var dir = URL(fileURLWithPath: #filePath)
            for _ in 0 ..< 5 { dir.deleteLastPathComponent() }
            let tmp = dir.appendingPathComponent("tmp", isDirectory: true)
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            return tmp.appendingPathComponent("auto-title-debug.log")
        }()

        /// Formatter used only on `queue`, so the non-thread-safe
        /// DateFormatter is never shared across threads.
        private static let timestampFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            return f
        }()

        static func log(_ message: String) {
            let now = Date()
            let thread = Thread.isMainThread ? "main" : "bg"
            queue.async {
                let line = "[\(timestampFormatter.string(from: now))] [\(thread)] \(message)\n"
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
#endif
