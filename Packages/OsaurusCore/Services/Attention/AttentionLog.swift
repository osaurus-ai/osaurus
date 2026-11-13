//
//  AttentionLog.swift
//  osaurus
//
//  Always-on structured logging for attention items, owner approvals and
//  notification delivery. Metadata only — item ids, kinds, outcomes,
//  surfaces, channel ids and tool names. Never message text, tool
//  arguments, handles, wallets or push tokens: the string is `.public`.
//

import Foundation
import os

enum AttentionLog {
    private static let logger = Logger(subsystem: "ai.osaurus", category: "Attention")

    static func info(_ message: String) {
        ConsoleLogFile.append("[Attention] \(message)")
        logger.info("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        ConsoleLogFile.append("[Attention] ERROR \(message)")
        logger.error("\(message, privacy: .public)")
    }
}
