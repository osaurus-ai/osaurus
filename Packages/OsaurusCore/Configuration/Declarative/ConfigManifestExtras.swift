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

/// One `events:` item. Matches `EventEntry` and its nested entries.
enum ConfigManifestEventKeys {
    static let itemKeys: [ConfigKeySpec] = [
        ConfigKeySpec("name", .scalar(.string, example: "Morning news")),
        ConfigKeySpec("enabled", .scalar(.boolean, example: "true")),
        ConfigKeySpec(
            "source", .mapping(sourceKeys),
            comment: "what fires the event; `kind` is required to create"),
        ConfigKeySpec(
            "filter", .mapping(filterKeys),
            comment: "optional; every non-empty clause must hold"),
        ConfigKeySpec(
            "agent", .scalar(.string, example: "Research Agent"),
            comment: "custom agent name (never \"default\"), or a shared",
            moreComments: [
                "workspace agent as <workspaceId>:<0x-address>; only for", "tool work; set agent OR workflow OR neither",
            ]),
        ConfigKeySpec(
            "instructions", .scalar(.string, example: "Summarize the news."),
            comment: "agent turn text; {{…}} payload bindings; alone (no",
            moreComments: [
                "agent/workflow) = one tool-less model answer; for channel",
                "messages, context placed ahead of the message",
            ]),
        ConfigKeySpec(
            "model", .scalar(.string, example: "null", nullable: true),
            comment: "instructions-only: the model that answers; null = default"),
        ConfigKeySpec(
            "working_folder", .scalar(.string, example: "\"\""),
            comment: "agent runs only; \"\" clears; folder events use the watched folder"),
        ConfigKeySpec(
            "fresh_session", .scalar(.boolean, example: "true"),
            comment: "new chat per fire (false continues the event's chat)"),
        ConfigKeySpec(
            "workflow", .scalar(.string, example: "null", nullable: true),
            comment: "installed workflow name (preferred over an agent);",
            moreComments: ["Run as (whose keys it uses) is set in the app"]),
        inputKey(
            example: "\"{{schedule.scheduled_for}}\"",
            kinds: [.schedule, .folder, .webhook, .rss, .sse, .runFailed, .app, .email]),
        ConfigKeySpec("delivery", .mapping(deliveryKeys), comment: "queueing; defaults depend on the source"),
        ConfigKeySpec("reply", .mapping(replyKeys), comment: "legacy channel_message only"),
    ]

    /// `input`, with the trigger values each source exposes listed from the
    /// same catalog the editor's Bind menu reads.
    static func inputKey(example: String, kinds: [EventSourceKind]) -> ConfigKeySpec {
        let lines = kinds.map { kind in
            "\(kind.rawValue): "
                + EventTriggerValues.catalog(for: kind).map { "{{\($0.path)}}" }.joined(separator: " ")
        }
        return ConfigKeySpec(
            "input",
            .freeformMap(.string, exampleKey: "date", exampleValue: example),
            comment: "workflow input -> template or fixed text; merge.",
            moreComments: [
                "Every `required` input must be bound (runs fail",
                "otherwise); omitted on create = prefilled. Values:",
            ] + lines + ["webhook body fields: {{webhook.body.<field>}}"])
    }

    static let sourceKeys: [ConfigKeySpec] = [
        ConfigKeySpec(
            "kind",
            .scalar(
                .string, example: "schedule",
                allowed: ["schedule", "folder", "webhook", "rss", "sse", "run_failed", "app", "email", "channel_message"]),
            comment: "schedule | folder | webhook | rss | sse | run_failed |",
            moreComments: ["app | channel_message; email is retired (ignored) —", "use channels.email"]),
        ConfigKeySpec(
            "frequency",
            .scalar(
                .string, example: "daily",
                allowed: ["once", "every_n_minutes", "hourly", "daily", "weekly", "monthly", "yearly", "cron"]),
            comment: "schedule: once | every_n_minutes | hourly | daily |",
            moreComments: ["weekly | monthly | yearly | cron"]),
        ConfigKeySpec(
            "frequency_value", .scalar(.string, example: "null", nullable: true),
            comment: "once: ISO8601; every_n_minutes: >=5; weekly: MON..SUN;",
            moreComments: [
                "monthly: 1..28; yearly: MM-DD; cron: 5 fields",
                "`min hour dom month dow` (dow 0-6, Sun = 0), e.g. \"0 8 * * 1-5\"",
            ]),
        ConfigKeySpec(
            "frequency_time_of_day", .scalar(.string, example: "\"08:00\""),
            comment: "HH:mm for daily/weekly/monthly/yearly"),
        ConfigKeySpec(
            "path", .scalar(.string, example: "~/Downloads"),
            comment: "folder: existing directory; ~ expands"),
        ConfigKeySpec("recursive", .scalar(.boolean, example: "false"), comment: "folder"),
        ConfigKeySpec(
            "responsiveness",
            .scalar(
                .string, example: "balanced",
                allowed: ["fast", "balanced", "patient", "relaxed", "deferred", "extended"]),
            comment: "folder: fast | balanced | patient | relaxed |",
            moreComments: ["deferred | extended"]),
        ConfigKeySpec(
            "provider",
            .scalar(
                .string, example: "generic",
                allowed: ["generic", "github", "stripe", "slack", "shopify", "twilio", "microsoft_graph", "facebook", "sns"]),
            comment: "webhook: generic (default) or the sending service;",
            moreComments: [
                "a service is checked its own way (omit verification);",
                "stripe/slack/shopify/twilio/facebook: paste their secret in the app",
            ]),
        ConfigKeySpec(
            "verification",
            .scalar(.string, example: "hmac_sha256", allowed: ["none", "shared_secret_header", "hmac_sha256"]),
            comment: "webhook: none (HIGH RISK) | shared_secret_header |",
            moreComments: ["hmac_sha256; the URL token and secret are created", "here and never appear in YAML"]),
        ConfigKeySpec(
            "signature_header", .scalar(.string, example: "X-Osaurus-Signature"),
            comment: "webhook: header carrying the secret / signature"),
        ConfigKeySpec(
            "signature_prefix", .scalar(.string, example: "sha256="),
            comment: "webhook hmac_sha256: prefix before the hex digest"),
        ConfigKeySpec(
            "max_body_bytes", .scalar(.integer, example: "262144"), comment: "webhook: 1..10485760"),
        ConfigKeySpec(
            "rate_limit_per_minute", .scalar(.integer, example: "60"), comment: "webhook: 1..600"),
        ConfigKeySpec(
            "sample_body", .scalar(.string, example: "'{\"action\": \"opened\"}'"),
            comment: "webhook: example of what the sender posts; its",
            moreComments: ["fields become {{webhook.body.<field>}}; Run Now sends it"]),
        ConfigKeySpec(
            "mailboxes", .scalarList(.string, example: ["INBOX"]),
            comment: "retired email automations only (ignored)"),
        ConfigKeySpec("unread_only", .scalar(.boolean, example: "false"), comment: "retired email (ignored)"),
        ConfigKeySpec("include_body", .scalar(.boolean, example: "true"), comment: "retired email (ignored)"),
        ConfigKeySpec("max_body_chars", .scalar(.integer, example: "8000"), comment: "retired email (ignored)"),
        ConfigKeySpec(
            "url", .scalar(.string, example: "https://example.com/feed.xml"),
            comment: "rss: RSS / Atom / JSON feed; sse: text/event-stream URL"),
        ConfigKeySpec(
            "poll_interval_seconds", .scalar(.integer, example: "900"), comment: "rss: 60..86400"),
        ConfigKeySpec(
            "catch_up", .scalar(.string, example: "latest_only", allowed: ["since_cursor", "latest_only", "skip"]),
            comment: "rss: items published while Osaurus was closed —",
            moreComments: ["since_cursor (all) | latest_only | skip"]),
        ConfigKeySpec(
            "max_items_per_tick", .scalar(.integer, example: "20"), comment: "rss: new items per check, 1..100"),
        ConfigKeySpec(
            "headers", .freeformMap(.string, exampleKey: "Accept", exampleValue: "text/event-stream"),
            comment: "sse: request headers (stored as written; not for secrets)"),
        ConfigKeySpec(
            "event_names", .scalarList(.string, example: ["update"]),
            comment: "sse: `event:` names that fire; empty = every message"),
        ConfigKeySpec(
            "heartbeat_timeout_seconds", .scalar(.integer, example: "0"),
            comment: "sse: reconnect after this long silent; 0 = off, else 10..3600"),
        ConfigKeySpec(
            "workflows", .scalarList(.string, example: ["Daily digest"]),
            comment: "run_failed: installed workflow names; empty = any"),
        ConfigKeySpec(
            "include_automation_runs", .scalar(.boolean, example: "false"),
            comment: "run_failed: also automations that run an agent"),
        ConfigKeySpec(
            "reasons", .scalarList(.string, example: ["app_launched"]),
            comment: "app: app_launched | automation_enabled |",
            moreComments: ["automation_updated"]),
        ConfigKeySpec(
            "platform",
            .scalar(
                .string, example: "slack",
                allowed: ["discord", "slack", "telegram", "imessage", "whatsapp", "email", "n8n", "custom_http"]),
            comment: "legacy channel_message (write channels.<platform>.routing):",
            moreComments: ["discord | slack | telegram | imessage | whatsapp | email | n8n | custom_http"]),
        ConfigKeySpec(
            "connection", .scalar(.string, example: "Ops bridge"),
            comment: "channel_message: n8n / custom_http connection name"),
        ConfigKeySpec(
            "rooms", .scalarList(.string, example: []),
            comment: "channel_message: room/channel/chat ids; empty = any"),
        ConfigKeySpec(
            "aliases", .scalarList(.string, example: []),
            comment: "channel_message: leading tokens that select this event"),
        ConfigKeySpec(
            "require_mention", .scalar(.boolean, example: "true"),
            comment: "channel_message: only when the bot is @mentioned"),
        ConfigKeySpec(
            "continue_threads", .scalar(.boolean, example: "true"),
            comment: "channel_message: follow-ups in a replied thread"),
    ]

    static let filterKeys: [ConfigKeySpec] = [
        ConfigKeySpec("senders", .scalarList(.string, example: []), comment: "channel sender ids/handles"),
        ConfigKeySpec("keywords_any", .scalarList(.string, example: []), comment: "text contains one of"),
        ConfigKeySpec("keywords_all", .scalarList(.string, example: []), comment: "text contains all of"),
        ConfigKeySpec("path_globs", .scalarList(.string, example: []), comment: "folder: changed path matches"),
        ConfigKeySpec(
            "conditions",
            .freeformMap(.string, exampleKey: "webhook.body.action", exampleValue: "opened"),
            comment: "payload dot path -> required value; replaces the map"),
    ]

    static let deliveryKeys: [ConfigKeySpec] = [
        ConfigKeySpec(
            "queue", .scalar(.string, example: "default"),
            comment: "task queue slug or name; default = Default queue"),
        ConfigKeySpec(
            "allow_overlapping_runs", .scalar(.boolean, example: "false"),
            comment: "true overlaps runs (per conversation where there are conversations); wins over mode"),
        ConfigKeySpec(
            "mode",
            .scalar(.string, example: "serial", allowed: ["serial", "per_conversation", "parallel"]),
            comment: "serial | per_conversation | parallel"),
        ConfigKeySpec("max_concurrent", .scalar(.integer, example: "1"), comment: "parallel: 1..8"),
        ConfigKeySpec(
            "max_queued", .scalar(.integer, example: "0"),
            comment: "0..100 fires held while busy (0 = skip while busy)"),
        ConfigKeySpec(
            "steer_running_turn", .scalar(.boolean, example: "true"),
            comment: "channel agent runs: join the streaming turn"),
        ConfigKeySpec(
            "dedupe", .scalar(.string, example: "window", allowed: ["none", "window", "durable"]),
            comment: "repeated delivery ids: none | window (dedupe_window_seconds) | durable (never twice; email)"),
        ConfigKeySpec(
            "dedupe_window_seconds", .scalar(.integer, example: "600"),
            comment: "0..86400; with dedupe: window"),
        ConfigKeySpec(
            "missed_fire", .scalar(.string, example: "run_once", allowed: ["run_once", "skip", "run_catchup"]),
            comment: "schedule: run_once | skip | run_catchup (each missed slot, newest 24)"),
    ]

    static let replyKeys: [ConfigKeySpec] = [
        ConfigKeySpec(
            "auto_reply", .scalar(.boolean, example: "false"),
            comment: "send the agent's reply back (HIGH RISK)"),
        ConfigKeySpec(
            "workflow_output", .scalar(.boolean, example: "false"),
            comment: "send the workflow's output back"),
    ]
}

/// Wave 3c — per-platform channel keys.
enum ConfigManifestChannelExtras {

    /// One `routing` rule: who answers which messages.
    static let routingRuleKeys: [ConfigKeySpec] = [
        ConfigKeySpec(
            "name", .scalar(.string, example: "Triage in support"),
            comment: "match key; unique across all automations"),
        ConfigKeySpec("enabled", .scalar(.boolean, example: "true")),
        ConfigKeySpec(
            "agent", .scalar(.string, example: "Triage"),
            comment: "custom agent name or <workspaceId>:<0x-address>;",
            moreComments: ["set agent OR workflow"]),
        ConfigKeySpec(
            "workflow", .scalar(.string, example: "null", nullable: true),
            comment: "installed workflow name (instead of agent)"),
        ConfigKeySpec(
            "rooms", .scalarList(.string, example: ["C0123SUPPORT"]),
            comment: "room/channel/chat ids; omitted or [] = any room"),
        ConfigKeySpec(
            "aliases", .scalarList(.string, example: []),
            comment: "messages starting with one of these (\"ops:\")"),
        ConfigKeySpec(
            "require_mention", .scalar(.boolean, example: "true"),
            comment: "slack / discord: only when the bot is @mentioned"),
        ConfigKeySpec(
            "continue_threads", .scalar(.boolean, example: "true"),
            comment: "follow-ups in a thread it replied in"),
        ConfigKeySpec(
            "replies", .scalar(.string, example: "approval", allowed: ["automatic", "approval", "none"]),
            comment: "agent: automatic (HIGH RISK) | approval (default);",
            moreComments: ["workflow: automatic (posts its output) | none"]),
        ConfigKeySpec(
            "instructions", .scalar(.string, example: "\"\""),
            comment: "agent: context placed ahead of each message"),
        ConfigKeySpec("working_folder", .scalar(.string, example: "\"\""), comment: "agent runs only; \"\" clears"),
        ConfigKeySpec(
            "fresh_session", .scalar(.boolean, example: "false"),
            comment: "new chat per message (default continues per thread)"),
        ConfigManifestEventKeys.inputKey(example: "\"{{message.text}}\"", kinds: [.channelMessage]),
        ConfigKeySpec("filter", .mapping(ConfigManifestEventKeys.filterKeys), comment: "optional"),
        ConfigKeySpec("delivery", .mapping(ConfigManifestEventKeys.deliveryKeys), comment: "optional queueing"),
    ]

    /// One `posting` row: may this agent post here on its own?
    static let postingKeys: [ConfigKeySpec] = [
        ConfigKeySpec(
            "agent", .scalar(.string, example: "Triage"),
            comment: "custom agent name, or default"),
        ConfigKeySpec(
            "mode", .scalar(.string, example: "ask_first", allowed: ["off", "ask_first", "without_asking"]),
            comment: "off | ask_first | without_asking (HIGH RISK)"),
        ConfigKeySpec(
            "rooms", .scalarList(.string, example: []),
            comment: "writable room ids; omitted = every write_allowlist room"),
    ]

    static let routingKey = ConfigKeySpec(
        "routing", .entityList(routingRuleKeys, requiredKey: "name"),
        comment: "who answers messages (the Routing table); alias rules",
        moreComments: ["win, then room rules, then any-room rules"])
    static let postingKey = ConfigKeySpec(
        "posting", .entityList(postingKeys, requiredKey: "agent"),
        comment: "agents that post on their own (needs write_enabled",
        moreComments: ["and the rooms in write_allowlist)"])

    /// `spaceComment` names the guild/team allowlist for platforms that have
    /// one (discord, slack); nil omits the key entirely. `includeBotTokenRef`
    /// adds the write-only bot-token secret reference (discord, slack,
    /// telegram); `includeAppTokenRef` adds Slack's app-level token ref.
    static func platformKeys(
        spaceComment: String?,
        includeBotTokenRef: Bool = false,
        includeAppTokenRef: Bool = false,
        accountIdExample: String? = nil
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
        keys.append(routingKey)
        keys.append(postingKey)
        if let accountIdExample {
            keys.append(accountsKey(keys.filter { $0.key != "bot_token_ref" && $0.key != "app_token_ref" }, idExample: accountIdExample))
        }
        return keys
    }

    /// `accounts`: the platform's other accounts, each edited by its
    /// connection id with the same keys as the platform section.
    static func accountsKey(_ keys: [ConfigKeySpec], idExample: String) -> ConfigKeySpec {
        ConfigKeySpec(
            "accounts",
            .entityList(
                [
                    ConfigKeySpec(
                        "id", .scalar(.string, example: idExample),
                        comment: "the account's connection id",
                        moreComments: ["(agent_channel_list_connections)"])
                ] + keys,
                requiredKey: "id"),
            comment: "other accounts, same keys as above;",
            moreComments: ["bots and workspaces are added in Settings"])
    }

    /// Email: mailboxes are rooms, replies go to any watched mailbox once
    /// sending is on, and agents cannot post on their own.
    static var emailKeys: [ConfigKeySpec] {
        let keys = [
            ConfigKeySpec(
                "write_enabled", .scalar(.boolean, example: "false"),
                comment: "agents may reply to mail they received",
                moreComments: ["(enabling is HIGH RISK)"]),
            ConfigKeySpec(
                "default_read_limit", .scalar(.integer, example: "25"),
                comment: "1..100 messages per read"),
            ConfigKeySpec(
                "read_allowlist", .scalarList(.string, example: []),
                comment: "watched mailboxes: <mail account id>/<mailbox>;",
                moreComments: ["accounts are added in Settings; replaces the list"]),
            ConfigKeySpec(
                "sender_allowlist", .scalarList(.string, example: []),
                comment: "addresses or @domain; replaces the list"),
            routingKey,
        ]
        return keys + [accountsKey(keys, idExample: "email-<mail account id>")]
    }
}
