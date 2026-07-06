//
//  ChatDebugLog.swift
//  osaurus
//
//  TEMPORARY debug logger for the chat rendering pipeline (code blocks
//  rendering as plain text / missing syntax highlighting). Appends to
//  /tmp/osaurus-chat-debug.log on a utility queue so logging never touches
//  the main thread. Remove (or gate behind a default) once the streaming
//  code-block investigation closes.
//

import Foundation

final class ChatDebugLog: @unchecked Sendable {

    static let shared = ChatDebugLog()

    private let queue = DispatchQueue(label: "com.osaurus.chat-debug-log", qos: .utility)
    private let url = URL(fileURLWithPath: "/tmp/osaurus-chat-debug.log")

    private let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init() {}

    /// Append one tagged line. The message string is built on the caller's
    /// thread (cheap interpolation); only the file I/O hops to the queue.
    func log(_ tag: String, _ message: String) {
        let stamp = timestampFormatter.string(from: Date())
        queue.async { [url] in
            let line = "\(stamp) [\(tag)] \(message)\n"
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

    /// Compact single-line preview of a text's head and tail with newlines
    /// escaped — enough to see fences/structure without dumping the payload.
    static func preview(_ text: String, edge: Int = 90) -> String {
        let escaped = text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        guard escaped.count > edge * 2 else { return "\"\(escaped)\"" }
        return "\"\(escaped.prefix(edge))…\(escaped.suffix(edge))\""
    }
}
