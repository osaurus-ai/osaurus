//
//  OnboardingProxyDebugLog.swift
//  osaurus
//
//  TEMPORARY — verification logging for the onboarding models-proxy route.
//  Appends timestamped lines to <repo>/tmp/onboarding-proxy.log so a manual
//  onboarding run can confirm which route (proxy vs anonymous HF) every file
//  took. Delete this file and its call sites once verified.
//

import Foundation

enum OnboardingProxyDebugLog {
    private static let logFileURL = URL(
        fileURLWithPath: "/workspace/osaurus/tmp/onboarding-proxy.log"
    )
    /// Serial queue keeps writes ordered and off the caller's thread — log
    /// calls happen on the main actor during downloads and must never block.
    private static let queue = DispatchQueue(
        label: "com.dinoki.osaurus.onboarding-proxy-debug-log",
        qos: .utility
    )
    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func log(_ message: String) {
        let line = "\(timestampFormatter.string(from: Date())) \(message)\n"
        queue.async {
            let fm = FileManager.default
            let dir = logFileURL.deletingLastPathComponent()
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: logFileURL)
            }
        }
    }
}
