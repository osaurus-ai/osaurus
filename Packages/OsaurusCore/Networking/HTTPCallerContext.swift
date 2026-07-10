//
//  HTTPCallerContext.swift
//  OsaurusCore
//
//  Task-local description of the HTTP caller whose request task is currently
//  executing. Bound by `HTTPHandler.runRequestTask` for every request task the
//  local server spawns, and absent everywhere else (app chat, plugins,
//  evaluators, warmup). Downstream gates use it to distinguish "this inference
//  was triggered by an inbound HTTP request" — and whether that caller proved
//  possession of a valid Osaurus access key — from app-internal work, without
//  threading a flag through every request struct.
//

import Foundation

struct HTTPCallerContext: Sendable {
    /// `true` when the caller presented a Bearer token that validated against
    /// the configured access keys. Non-loopback callers can only reach a
    /// handler with a valid key (the global auth gate rejects them otherwise);
    /// loopback callers skip the gate, so this is `true` for them only when
    /// they volunteered a key that validated.
    let hasVerifiedAccessKey: Bool

    @TaskLocal static var current: HTTPCallerContext?
}
