//
//  TTSDebugLog.swift
//  osaurus
//
//  Append-only diagnostic log for remote TTS at /tmp/osaurus/tts.log.
//  Exists because "static noise" and "silence" bugs are invisible in the UI:
//  the request, the server's declared content type, and the first bytes of
//  the body are what identify a format mismatch, and users can attach the
//  file to a report. /tmp is wiped by macOS, so this never grows unbounded.
//

import Foundation

enum TTSDebugLog {
    private static let queue = DispatchQueue(label: "ai.osaurus.tts.debuglog", qos: .utility)
    private static let fileURL = URL(fileURLWithPath: "/tmp/osaurus/tts.log")

    /// Append a timestamped line. Fire-and-forget off the caller's thread;
    /// logging must never slow down or break audio delivery.
    static func log(_ message: String) {
        queue.async {
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let line = "[\(timestamp)] \(message)\n"
            let fm = FileManager.default
            try? fm.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: fileURL)
            }
        }
    }

    /// Hex dump of the first `count` bytes, for eyeballing magic numbers.
    static func hexPreview(_ data: Data, count: Int = 16) -> String {
        data.prefix(count).map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}
