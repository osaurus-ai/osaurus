//
//  ConfigManifestExtras.swift
//  osaurus
//
//  Key groups appended to pre-existing manifest sections by the parity
//  waves. Kept separate so each wave's additions stay reviewable next to
//  the exporter / planner / applier code that consumes them. The Wave 3a
//  server-runtime keys left with the `server` section (scope reduction 2).
//

import Foundation

/// Wave 3c — per-platform channel keys.
enum ConfigManifestChannelExtras {

    /// `spaceComment` names the guild/team allowlist for platforms that have
    /// one (discord, slack); nil omits the key entirely. `includeBotTokenRef`
    /// adds the write-only bot-token secret reference (discord, slack,
    /// telegram); `includeAppTokenRef` adds Slack's app-level token ref.
    static func platformKeys(
        spaceComment: String?,
        includeBotTokenRef: Bool = false,
        includeAppTokenRef: Bool = false
    ) -> [ConfigKeySpec] {
        var keys: [ConfigKeySpec] = [
            ConfigKeySpec(
                "write_enabled", .scalar(.boolean, example: "false"),
                comment: "agents may SEND here (enabling is HIGH RISK)"),
            ConfigKeySpec(
                "default_read_limit", .scalar(.integer, example: "50"),
                comment: "1..100 messages per read"),
        ]
        if let spaceComment {
            keys.append(
                ConfigKeySpec(
                    "space_allowlist", .scalarList(.string, example: []),
                    comment: spaceComment,
                    moreComments: ["replaces the list"]))
        }
        keys.append(contentsOf: [
            ConfigKeySpec(
                "read_allowlist", .scalarList(.string, example: []),
                comment: "readable room/chat ids; replaces the list"),
            ConfigKeySpec(
                "write_allowlist", .scalarList(.string, example: []),
                comment: "writable room/chat ids; replaces the list"),
            ConfigKeySpec(
                "sender_allowlist", .scalarList(.string, example: []),
                comment: "authorized sender ids; replaces the list"),
            ConfigKeySpec(
                "inbound_enabled", .scalar(.boolean, example: "false"),
                comment: "dispatch incoming messages to an agent"),
            ConfigKeySpec(
                "inbound_agent", .scalar(.string, example: "null", nullable: true),
                comment: "CUSTOM agent name for unrouted messages (never",
                moreComments: ["\"default\"); null clears; routes stay in Settings"]),
            ConfigKeySpec("require_mention", .scalar(.boolean, example: "true")),
            ConfigKeySpec("continue_threads", .scalar(.boolean, example: "true")),
            ConfigKeySpec(
                "auto_reply_enabled", .scalar(.boolean, example: "false"),
                comment: "reply without confirmation (HIGH RISK)"),
        ])
        if includeBotTokenRef {
            keys.append(
                ConfigKeySpec(
                    "bot_token_ref", .scalar(.string, example: "env:BOT_TOKEN"),
                    comment: "write-only: env:VAR or keychain:service/account;",
                    moreComments: [
                        "the token is read from there at apply and stored",
                        "in the Keychain — never exported",
                    ]))
        }
        if includeAppTokenRef {
            keys.append(
                ConfigKeySpec(
                    "app_token_ref", .scalar(.string, example: "env:SLACK_APP_TOKEN"),
                    comment: "write-only: Slack app-level (Socket Mode) token"))
        }
        return keys
    }
}
