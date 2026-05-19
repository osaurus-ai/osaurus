//
//  UncaughtExceptionLogger.swift
//  osaurus
//
//  Captures NSException details to disk before AppKit kills the process
//

import Foundation

enum UncaughtExceptionLogger {
    static let logPath: String = {
        let base = (NSHomeDirectory() as NSString).appendingPathComponent(
            "Library/Logs/Osaurus"
        )
        return (base as NSString).appendingPathComponent("last-crash-reason.log")
    }()

    static func install() {
        try? FileManager.default.createDirectory(
            atPath: (logPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )

        NSSetUncaughtExceptionHandler { exception in
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let dump = """
                timestamp: \(timestamp)
                name:      \(exception.name.rawValue)
                reason:    \(exception.reason ?? "<nil>")
                userInfo:  \(String(describing: exception.userInfo))
                stack:
                \(exception.callStackSymbols.joined(separator: "\n"))
                """
            try? dump.write(
                toFile: UncaughtExceptionLogger.logPath,
                atomically: true,
                encoding: .utf8
            )
        }
    }
}
