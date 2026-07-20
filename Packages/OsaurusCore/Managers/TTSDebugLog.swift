//
//  TTSDebugLog.swift
//  osaurus
//
//  Append-only diagnostic log for remote TTS at `~/.osaurus/tmp/tts.log`.
//  Exists because "static noise" and "silence" bugs are invisible in the UI:
//  the request, the server's declared content type, and the first bytes of
//  the body are what identify a format mismatch, and users can attach the
//  file to a report. Truncated when it grows past 1 MB so it never balloons.
//

import Foundation

enum TTSDebugLog {
    private static let queue = DispatchQueue(label: "ai.osaurus.tts.debuglog", qos: .utility)
    private static let maxBytes = 1_048_576
    private static var fileURL: URL {
        OsaurusPaths.root()
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent("tts.log")
    }

    /// Append a timestamped line. Fire-and-forget off the caller's thread;
    /// logging must never slow down or break audio delivery.
    static func log(_ message: String) {
        let url = fileURL
        queue.async {
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let line = "[\(timestamp)] \(message)\n"
            let fm = FileManager.default
            try? fm.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int,
                size > maxBytes
            {
                try? fm.removeItem(at: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    /// Hex dump of the first `count` bytes, for eyeballing magic numbers.
    static func hexPreview(_ data: Data, count: Int = 16) -> String {
        data.prefix(count).map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}
