//
//  MobileConnectLog.swift
//  osaurus
//
//  A plain-text trail of everything Osaurus Connect does — server bind,
//  Bonjour publish, pairing requests — for the times Console is not at
//  hand or its unified log has already rolled. Debug builds write it to
//  `tmp/mobile-connect.log` in the checkout (the path is taken from this
//  file's own location at compile time); release builds go to
//  `~/Library/Logs/Osaurus/mobile-connect.log`. Never the code, the key,
//  or the device id — only what happened and when.
//

import Foundation

enum MobileConnectLog {

    /// Where the trail is written. Created on first use.
    static let fileURL: URL = {
        let url: URL
        #if DEBUG
            // …/Packages/OsaurusCore/Services/MobileConnect/MobileConnectLog.swift
            // → the checkout root, five levels up from the file.
            let source = URL(fileURLWithPath: #filePath)
            let root = source.deletingLastPathComponent()  // MobileConnect
                .deletingLastPathComponent()  // Services
                .deletingLastPathComponent()  // OsaurusCore
                .deletingLastPathComponent()  // Packages
                .deletingLastPathComponent()  // repo root
            url = root.appendingPathComponent("tmp", isDirectory: true).appendingPathComponent("mobile-connect.log")
        #else
            let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Logs/Osaurus", isDirectory: true)
            url = logs.appendingPathComponent("mobile-connect.log")
        #endif
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }()

    private static let queue = DispatchQueue(label: "com.osaurus.mobile-connect-log", qos: .utility)

    /// Appends one line, timestamped. Safe from any thread; never throws.
    static func write(_ message: String) {
        ConsoleLogFile.append("[MobileConnect] \(message)")
        let now = Date()
        queue.async {
            // Formatted on the queue: `ISO8601DateFormatter` is not Sendable,
            // so a shared instance cannot be touched from arbitrary threads.
            let stamp = ISO8601DateFormatter()
            stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let line = "\(stamp.string(from: now)) \(message)\n"
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
}
