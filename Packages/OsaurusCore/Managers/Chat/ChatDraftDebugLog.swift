//
//  ChatDraftDebugLog.swift
//  osaurus
//
//  TEMPORARY: file logger for tracing composer draft stash/restore (#2708).
//  Appends to <repo>/tmp/chat-draft-debug.log. The repo root is derived
//  from this file's compile-time path, so nothing machine-specific is
//  hard-coded. Remove before merging.
//

import Foundation

enum ChatDraftDebugLog {
    private static let queue = DispatchQueue(label: "ai.osaurus.chat-draft-debug-log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static let fileURL: URL = {
        // .../Packages/OsaurusCore/Managers/Chat/ChatDraftDebugLog.swift -> repo root
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        let dir = url.appendingPathComponent("tmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("chat-draft-debug.log")
    }()

    static func log(_ message: @autoclosure @escaping () -> String, function: String = #function) {
        let line = "[\(formatter.string(from: Date()))] \(function): \(message())\n"
        print("[DraftDebug] \(line)", terminator: "")
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    static func short(_ s: String) -> String {
        let trimmed = s.replacingOccurrences(of: "\n", with: "\\n")
        return trimmed.count > 40 ? "\"\(trimmed.prefix(40))…\"(\(s.count))" : "\"\(trimmed)\""
    }

    static func key(_ k: ChatDraftStore.Key) -> String {
        switch k {
        case .session(let id): return "session:\(id.uuidString.prefix(8))"
        case .newChat(let agentId): return "newChat:\(agentId?.uuidString.prefix(8) ?? "default")"
        }
    }
}
