//
//  RemoteAgentRunLog.swift
//  osaurus
//
//  Always-on (info-level) structured logging for remote agent (Mode 2) runs,
//  split by side (caller vs host) so a single run can be traced end-to-end in
//  Console.app without flipping a debug flag. Metadata only — provider ids,
//  resolved model, endpoint, tool names/phases, counts, exit state, and error
//  descriptions. Never log message content here: the privacy specifier marks
//  the composed string `.public`, so callers must pass only metadata.
//

import Foundation
import os

enum RemoteAgentRunLog {
    private static let clientLogger = Logger(
        subsystem: "ai.osaurus",
        category: "RemoteAgentRun.client"
    )
    private static let serverLogger = Logger(
        subsystem: "ai.osaurus",
        category: "RemoteAgentRun.server"
    )

    /// Caller side (the device initiating the Mode 2 run): routing decision,
    /// endpoint selection, SSE/tool-trace progress, terminal status.
    ///
    /// These are always-on (info/error level), so the message is composed
    /// eagerly at the call site — a plain `String` (not an `@autoclosure`)
    /// keeps it out of the escaping OSLog interpolation closure, which can't
    /// capture a non-escaping autoclosure parameter.
    static func client(_ message: String) {
        clientLogger.info("\(message, privacy: .public)")
    }

    static func clientError(_ message: String) {
        clientLogger.error("\(message, privacy: .public)")
    }

    /// Host side (the device running `/agents/{id}/run`): agent + model
    /// resolution, per-tool start/complete, run exit state, errors.
    static func server(_ message: String) {
        serverLogger.info("\(message, privacy: .public)")
    }

    static func serverError(_ message: String) {
        serverLogger.error("\(message, privacy: .public)")
    }
}
