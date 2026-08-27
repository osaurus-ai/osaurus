//
//  ConfigManifest.swift
//  osaurus
//
//  The single source of truth for the declarative configuration schema.
//  Every key of `OsaurusConfigDocument` is declared here exactly once,
//  with its type, example value, documentation comment, and (where
//  applicable) allowed values. Everything else derives from this table:
//
//   * `ConfigYAML` strict validation (`knownKeys`, list item required
//     keys, freeform-map value checks) — the enforced schema.
//   * `ConfigSchemaReference.text` — the model-facing YAML reference.
//   * `ConfigManifest.jsonSchema()` — a machine-readable JSON Schema for
//     the CLI / CI (`osaurus config schema --format json`,
//     `GET /admin/config/schema`).
//   * `ConfigDeclarativeDomain` search keywords — capability discovery.
//   * `ConfigManifest.exampleDocumentYAML` — a decodable document built
//     from the examples, pinned by tests so the manifest can never
//     drift from the Codable structs in either direction.
//
//  Adding a key to the document model means adding it HERE plus the
//  Codable field; the schema text, validation, and JSON schema follow
//  automatically.
//

import Foundation

// MARK: - Value specs

/// Scalar leaf type. Drives the JSON Schema `type` and documentation.
public enum ConfigScalarType: String, Sendable {
    case boolean
    case integer
    case number
    case string

    var jsonType: String {
        switch self {
        case .boolean: return "boolean"
        case .integer: return "integer"
        case .number: return "number"
        case .string: return "string"
        }
    }
}

/// Recursive shape of a document value.
public indirect enum ConfigValueSpec: Sendable {
    /// Scalar leaf. `example` is rendered verbatim in the schema
    /// reference. `allowed` enumerates legal values (JSON Schema enum).
    /// `nullable` marks keys where an explicit `null` clears an override.
    case scalar(ConfigScalarType, example: String, allowed: [String]? = nil, nullable: Bool = false)
    /// A list of scalars (`models`, `plugins`, ranking, UUID lists).
    case scalarList(ConfigScalarType, example: [String])
    /// Fixed-key mapping — unknown keys are validation errors.
    case mapping([ConfigKeySpec])
    /// A list of fixed-key mappings. Items match existing entities by
    /// `requiredKey` (case-insensitive), which every item must carry.
    case entityList([ConfigKeySpec], requiredKey: String)
    /// Free-form map of user-chosen keys to scalars (`tools.enabled`).
    /// `allowedValues` constrains the VALUES (e.g. auto | ask | deny).
    case freeformMap(
        ConfigScalarType, allowedValues: [String]? = nil,
        exampleKey: String, exampleValue: String)
}

/// One named key inside a mapping / entity item.
public struct ConfigKeySpec: Sendable {
    public let key: String
    public let value: ConfigValueSpec
    /// Trailing comment on the key's first rendered line.
    public let comment: String?
    /// Continuation comment lines, rendered aligned under `comment`.
    public let moreComments: [String]

    public init(
        _ key: String, _ value: ConfigValueSpec,
        comment: String? = nil, moreComments: [String] = []
    ) {
        self.key = key
        self.value = value
        self.comment = comment
        self.moreComments = moreComments
    }
}

/// One top-level document section.
public struct ConfigSectionSpec: Sendable {
    public let id: ConfigSectionID
    /// Trailing comment on the section header line.
    public let comment: String?
    public let value: ConfigValueSpec

    public init(_ id: ConfigSectionID, comment: String? = nil, value: ConfigValueSpec) {
        self.id = id
        self.comment = comment
        self.value = value
    }
}

// MARK: - Manifest

public enum ConfigManifest {

    /// Supported document schema version.
    public static let version = 1

    /// Every section, in canonical render order. This table IS the schema.
    /// Server runtime, chat behavior, and app shell sections were removed
    /// in scope reduction 2 — those live in the Settings UI only.
    public static let sections: [ConfigSectionSpec] = [
        ConfigSectionSpec(
            .memory,
            comment: "cross-chat conversation memory — NOT the server prompt/KV cache (prompt-cache toggles live in Settings → Server, not here)",
            value: .mapping([
                ConfigKeySpec("enabled", .scalar(.boolean, example: "true")),
                ConfigKeySpec(
                    "budget_tokens", .scalar(.integer, example: "1000"),
                    comment: "100..4000"),
                ConfigKeySpec(
                    "retention_days", .scalar(.integer, example: "180"),
                    comment: "0..3650 (0 = forever)"),
            ])),

        ConfigSectionSpec(
            .defaultAgent,
            comment: "the built-in Default agent (the Orchestrator)",
            value: .mapping([
                ConfigKeySpec(
                    "name", .scalar(.string, example: "null", nullable: true),
                    comment: "custom display name; null = \"Osaurus\""),
                ConfigKeySpec(
                    "model", .scalar(.string, example: "null", nullable: true),
                    comment: "\"foundation\", local id, or \"<provider>/<model>\"",
                    moreComments: [
                        "(cloud ids need the provider prefix, e.g.",
                        "\"anthropic/claude-x\"; a bare cloud id is",
                        "auto-prefixed when unambiguous)",
                    ]),
                ConfigKeySpec(
                    "temperature", .scalar(.number, example: "null", nullable: true),
                    comment: "0..2 or null"),
                ConfigKeySpec("max_tokens", .scalar(.integer, example: "null", nullable: true)),
                ConfigKeySpec(
                    "system_prompt", .scalar(.string, example: "\"\""),
                    comment: "the persona"),
                ConfigKeySpec("disable_tools", .scalar(.boolean, example: "false")),
            ])),

        ConfigSectionSpec(
            .activeAgent,
            comment: "\"default\" or a custom agent's name",
            value: .scalar(.string, example: "default")),

        ConfigSectionSpec(
            .agents,
            comment: "custom agents (never the Default agent)",
            value: .entityList(
                [
                    ConfigKeySpec("name", .scalar(.string, example: "Research Agent")),
                    ConfigKeySpec("description", .scalar(.string, example: "\"\"")),
                    ConfigKeySpec("system_prompt", .scalar(.string, example: "\"\"")),
                    ConfigKeySpec(
                        "model", .scalar(.string, example: "null", nullable: true),
                        comment: "same format as default_agent.model"),
                    ConfigKeySpec(
                        "temperature", .scalar(.number, example: "null", nullable: true),
                        comment: "0..2"),
                    ConfigKeySpec(
                        "max_tokens", .scalar(.integer, example: "null", nullable: true)),
                    ConfigKeySpec(
                        "capabilities",
                        .mapping([
                            ConfigKeySpec("tools_enabled", .scalar(.boolean, example: "true")),
                            ConfigKeySpec("memory_enabled", .scalar(.boolean, example: "true")),
                            ConfigKeySpec(
                                "search_memory_enabled", .scalar(.boolean, example: "false")),
                            ConfigKeySpec(
                                "web_search_enabled", .scalar(.boolean, example: "false")),
                            ConfigKeySpec(
                                "knowledge_enabled", .scalar(.boolean, example: "false")),
                            ConfigKeySpec(
                                "knowledge_collection_ids",
                                .scalarList(.string, example: []),
                                comment: "UUIDs; needed for knowledge tools"),
                            ConfigKeySpec("db_enabled", .scalar(.boolean, example: "false")),
                            ConfigKeySpec(
                                "self_scheduling_enabled", .scalar(.boolean, example: "false")),
                            ConfigKeySpec(
                                "computer_use_enabled", .scalar(.boolean, example: "false"),
                                comment: "HIGH RISK"),
                            ConfigKeySpec(
                                "browser_use_enabled", .scalar(.boolean, example: "false"),
                                comment: "HIGH RISK"),
                            ConfigKeySpec("speak_enabled", .scalar(.boolean, example: "false")),
                            ConfigKeySpec(
                                "render_chart_enabled", .scalar(.boolean, example: "false")),
                            ConfigKeySpec(
                                "relay_enabled", .scalar(.boolean, example: "false"),
                                comment: "relay tunnel forwards to this agent",
                                moreComments: ["(HIGH RISK: reachable from outside)"]),
                        ]),
                        comment: "only provided keys change"),
                ],
                requiredKey: "name")),

        ConfigSectionSpec(
            .tools,
            comment: "global tool enablement / permission policies",
            value: .mapping([
                ConfigKeySpec(
                    "enabled",
                    .freeformMap(.boolean, exampleKey: "web_search", exampleValue: "true")),
                ConfigKeySpec(
                    "policies",
                    .freeformMap(
                        .string, allowedValues: ["auto", "ask", "deny"],
                        exampleKey: "file_write", exampleValue: "ask"),
                    comment: "auto | ask | deny (auto is HIGH RISK)"),
            ])),

        ConfigSectionSpec(
            .delegation,
            comment: "main-chat subagent delegation and child budgets",
            value: .mapping([
                ConfigKeySpec("local_text_enabled", .scalar(.boolean, example: "true")),
                ConfigKeySpec("image_enabled", .scalar(.boolean, example: "false")),
                ConfigKeySpec("video_enabled", .scalar(.boolean, example: "false")),
                ConfigKeySpec("applescript_enabled", .scalar(.boolean, example: "false")),
                ConfigKeySpec(
                    "applescript_execution_mode",
                    .scalar(
                        .string, example: "confirm_each",
                        allowed: ConfigAppBehaviorEnums.applescriptExecutionModes),
                    comment: "confirm_each | auto_run_with_warning",
                    moreComments: ["(auto_run is HIGH RISK)"]),
                ConfigKeySpec(
                    "spawnable_agents", .scalarList(.string, example: []),
                    comment: "custom agent NAMES the main chat may spawn;",
                    moreComments: ["replaces the pool"]),
                ConfigKeySpec(
                    "spawnable_models", .scalarList(.string, example: []),
                    comment: "raw model ids; replaces the pool"),
                ConfigKeySpec(
                    "spawn_tool_access",
                    .scalar(
                        .string, example: "none",
                        allowed: ConfigAppBehaviorEnums.spawnToolAccessValues),
                    comment: "none | read_only child tool grant"),
                ConfigKeySpec(
                    "permission_defaults",
                    .freeformMap(
                        .string, allowedValues: ConfigAppBehaviorEnums.permissionPolicies,
                        exampleKey: "spawn", exampleValue: "ask"),
                    comment: "kind id (spawn | image | video | applescript |",
                    moreComments: [
                        "computer_use | browser_use) -> ask | deny |",
                        "always_allow (always_allow is HIGH RISK); merge",
                    ]),
                ConfigKeySpec(
                    "budget_max_tokens", .scalar(.integer, example: "2048"),
                    comment: "256..32768 per child"),
                ConfigKeySpec(
                    "budget_max_turns", .scalar(.integer, example: "2"),
                    comment: "1..8"),
                ConfigKeySpec(
                    "budget_max_tool_calls", .scalar(.integer, example: "0"),
                    comment: "0..32 (0 = built-in default cap)"),
                ConfigKeySpec(
                    "budget_max_seconds", .scalar(.integer, example: "120"),
                    comment: "15..1800"),
                ConfigKeySpec(
                    "budget_max_parallel_spawns", .scalar(.integer, example: "3"),
                    comment: "1..32 (mirrors Server Concurrent Sessions)"),
                ConfigKeySpec(
                    "ram_safety_preflight", .scalar(.boolean, example: "true"),
                    comment: "false skips the RAM preflight (HIGH RISK)"),
                ConfigKeySpec(
                    "coexistence_enabled", .scalar(.boolean, example: "false"),
                    comment: "spawn model may load beside the chat model"),
            ])),

        ConfigSectionSpec(
            .commands,
            comment: "user template slash commands (built-ins stay)",
            value: .entityList(
                [
                    ConfigKeySpec(
                        "name", .scalar(.string, example: "summarize"),
                        comment: "invoke as /name"),
                    ConfigKeySpec("description", .scalar(.string, example: "\"\"")),
                    ConfigKeySpec(
                        "icon", .scalar(.string, example: "text.bubble"),
                        comment: "SF Symbol name"),
                    ConfigKeySpec(
                        "template",
                        .scalar(.string, example: "Summarize the conversation so far."),
                        comment: "prompt text; required to create"),
                ],
                requiredKey: "name")),

        ConfigSectionSpec(
            .knowledgeCollections,
            comment: "knowledge collection registry (documents are content)",
            value: .entityList(
                [
                    ConfigKeySpec("name", .scalar(.string, example: "Team Docs")),
                    ConfigKeySpec(
                        "folder_path", .scalar(.string, example: "~/Documents/TeamDocs"),
                        comment: "existing directory; ~ expands; required to",
                        moreComments: ["create; immutable after (recreate to move)"]),
                    ConfigKeySpec("summary", .scalar(.string, example: "\"\"")),
                    ConfigKeySpec("enabled", .scalar(.boolean, example: "true")),
                    ConfigKeySpec(
                        "include_globs", .scalarList(.string, example: []),
                        comment: "replaces the list"),
                    ConfigKeySpec(
                        "exclude_globs", .scalarList(.string, example: []),
                        comment: "replaces the list"),
                ],
                requiredKey: "name")),

        ConfigSectionSpec(
            .channels,
            comment: "channel routing (credentials/routes stay in Settings)",
            value: .mapping([
                ConfigKeySpec(
                    "write_enabled", .scalar(.boolean, example: "true"),
                    comment: "global kill switch over EVERY channel send;",
                    moreComments: ["re-enabling is HIGH RISK"]),
                ConfigKeySpec(
                    "discord",
                    .mapping(
                        ConfigManifestChannelExtras.platformKeys(
                            spaceComment: "configured guild ids;",
                            includeBotTokenRef: true))),
                ConfigKeySpec(
                    "slack",
                    .mapping(
                        ConfigManifestChannelExtras.platformKeys(
                            spaceComment: "configured team ids;",
                            includeBotTokenRef: true,
                            includeAppTokenRef: true))),
                ConfigKeySpec(
                    "telegram",
                    .mapping(
                        ConfigManifestChannelExtras.platformKeys(
                            spaceComment: nil,
                            includeBotTokenRef: true))),
                ConfigKeySpec(
                    "imessage",
                    .mapping(ConfigManifestChannelExtras.platformKeys(spaceComment: nil))),
                ConfigKeySpec(
                    "whatsapp",
                    .mapping(ConfigManifestChannelExtras.platformKeys(spaceComment: nil))),
            ])),

        ConfigSectionSpec(
            .mcpServers,
            comment: "user-added MCP servers (plugin-owned stay put)",
            value: .entityList(
                [
                    ConfigKeySpec("name", .scalar(.string, example: "GitHub")),
                    ConfigKeySpec(
                        "transport",
                        .scalar(
                            .string, example: "http",
                            allowed: ["http", "stdio"]),
                        comment: "http | stdio; immutable after create;",
                        moreComments: ["stdio launches a local process (HIGH RISK)"]),
                    ConfigKeySpec(
                        "url", .scalar(.string, example: "https://api.example.com/mcp"),
                        comment: "http transport only"),
                    ConfigKeySpec(
                        "auth",
                        .scalar(
                            .string, example: "none",
                            allowed: ["none", "bearer", "oauth"]),
                        comment: "none | bearer | oauth (http only;",
                        moreComments: ["finish auth in Settings)"]),
                    ConfigKeySpec("enabled", .scalar(.boolean, example: "true")),
                    ConfigKeySpec(
                        "command", .scalar(.string, example: "\"\""),
                        comment: "stdio executable; required to create stdio"),
                    ConfigKeySpec(
                        "args", .scalarList(.string, example: []),
                        comment: "replaces the list"),
                    ConfigKeySpec(
                        "env",
                        .freeformMap(.string, exampleKey: "NODE_ENV", exampleValue: "production"),
                        comment: "plain env only; secret values are set in",
                        moreComments: ["Settings and never appear here; merge"]),
                    ConfigKeySpec(
                        "working_directory", .scalar(.string, example: "\"\""),
                        comment: "stdio cwd; \"\" = default"),
                    ConfigKeySpec(
                        "execution_host",
                        .scalar(
                            .string, example: "sandbox",
                            allowed: ["sandbox", "host"]),
                        comment: "sandbox | host (host is HIGH RISK)"),
                    ConfigKeySpec(
                        "token_ref", .scalar(.string, example: "env:MCP_BEARER_TOKEN"),
                        comment: "write-only (http): env:VAR or",
                        moreComments: [
                            "keychain:service/account; the bearer token is",
                            "read from there at apply and stored in the",
                            "Keychain — never exported",
                        ]),
                    ConfigKeySpec(
                        "secret_env_refs",
                        .freeformMap(.string, exampleKey: "API_TOKEN", exampleValue: "env:MY_TOKEN"),
                        comment: "write-only (stdio): env KEY -> secret ref;",
                        moreComments: [
                            "values are read at apply and stored in the",
                            "Keychain; keys become secret env — never exported",
                        ]),
                ],
                requiredKey: "name")),

        ConfigSectionSpec(
            .models,
            comment: "desired installed local MLX models (HF repo ids) — listing an id that isn't installed STARTS its download; hiding a model from the API is Settings → Server, not this list",
            value: .scalarList(.string, example: ["mlx-community/Qwen2.5-7B-Instruct-4bit"])),

        ConfigSectionSpec(
            .plugins,
            comment: "desired installed plugins (registry ids)",
            value: .scalarList(.string, example: ["osaurus.weather"])),

        ConfigSectionSpec(
            .providers,
            comment: "cloud LLM providers",
            value: .entityList(
                [
                    ConfigKeySpec("name", .scalar(.string, example: "Anthropic")),
                    ConfigKeySpec(
                        "provider",
                        .scalar(
                            .string, example: "anthropic",
                            allowed: [
                                "anthropic", "openai", "codex_oauth", "azure_openai",
                                "google", "xai", "deepseek", "venice", "openrouter",
                                "ollama", "custom", "osaurus_agent",
                            ]),
                        comment: "anthropic | openai | codex_oauth | azure_openai |",
                        moreComments: [
                            "google | xai | deepseek | venice | openrouter |",
                            "ollama | custom | osaurus_agent",
                            "required to create; immutable after",
                        ]),
                    ConfigKeySpec("enabled", .scalar(.boolean, example: "true")),
                    ConfigKeySpec("auto_connect", .scalar(.boolean, example: "true")),
                    ConfigKeySpec(
                        "set_api_key", .scalar(.boolean, example: "true"),
                        comment: "request flag: opens the secure credential",
                        moreComments: [
                            "sheet during apply to set/rotate the key,",
                            "even when credentials already exist.",
                            "Never exported; secrets never in YAML.",
                        ]),
                    ConfigKeySpec(
                        "api_key_ref", .scalar(.string, example: "env:ANTHROPIC_API_KEY"),
                        comment: "write-only: env:VAR or keychain:service/account;",
                        moreComments: [
                            "the key is read from there at apply and stored",
                            "in the Keychain — never exported. Non-interactive",
                            "alternative to set_api_key (use one, not both).",
                        ]),
                    ConfigKeySpec(
                        "host", .scalar(.string, example: "api.anthropic.com"),
                        comment: "create-only: changing an existing provider's",
                        moreComments: [
                            "endpoint under a stored credential is refused —",
                            "recreate the provider instead",
                        ]),
                    ConfigKeySpec(
                        "protocol",
                        .scalar(
                            .string, example: "https",
                            allowed: ["http", "https"]),
                        comment: "create-only"),
                    ConfigKeySpec(
                        "port", .scalar(.integer, example: "null", nullable: true),
                        comment: "create-only; null = protocol default"),
                    ConfigKeySpec(
                        "base_path", .scalar(.string, example: "/v1"),
                        comment: "create-only"),
                    ConfigKeySpec(
                        "timeout_seconds", .scalar(.number, example: "60"),
                        comment: "1..600"),
                    ConfigKeySpec("disable_timeout", .scalar(.boolean, example: "false")),
                    ConfigKeySpec(
                        "manual_model_ids", .scalarList(.string, example: []),
                        comment: "pinned model ids (Azure deployments);",
                        moreComments: ["replaces the list"]),
                ],
                requiredKey: "name")),

        ConfigSectionSpec(
            .searchProviders,
            value: .mapping([
                ConfigKeySpec(
                    "ranking",
                    .scalarList(.string, example: ["tavily", "ddg_scrape"]),
                    comment: "fallback order, first = primary"),
                ConfigKeySpec(
                    "providers",
                    .entityList(
                        [
                            ConfigKeySpec(
                                "id", .scalar(.string, example: "tavily"),
                                comment: "keyed providers need the API key in Settings"),
                            ConfigKeySpec("enabled", .scalar(.boolean, example: "true")),
                        ],
                        requiredKey: "id")),
            ])),

        ConfigSectionSpec(
            .schedules,
            comment: "scheduled runs of CUSTOM agents",
            value: .entityList(
                [
                    ConfigKeySpec("name", .scalar(.string, example: "Morning news")),
                    ConfigKeySpec(
                        "agent", .scalar(.string, example: "Research Agent"),
                        comment: "custom agent name (never \"default\")"),
                    ConfigKeySpec(
                        "instructions", .scalar(.string, example: "Summarize the news.")),
                    ConfigKeySpec(
                        "frequency",
                        .scalar(
                            .string, example: "daily",
                            allowed: [
                                "once", "every_n_minutes", "hourly", "daily",
                                "weekly", "monthly", "yearly", "cron",
                            ]),
                        comment: "once | every_n_minutes | hourly | daily |",
                        moreComments: ["weekly | monthly | yearly | cron"]),
                    ConfigKeySpec(
                        "frequency_value", .scalar(.string, example: "null", nullable: true),
                        comment: "once: ISO8601; every_n_minutes: >=5;",
                        moreComments: [
                            "weekly: MON..SUN; monthly: 1..28;",
                            "yearly: MM-DD; cron: expression",
                        ]),
                    ConfigKeySpec(
                        "frequency_time_of_day", .scalar(.string, example: "\"08:00\""),
                        comment: "HH:mm for daily/weekly/monthly/yearly"),
                    ConfigKeySpec("enabled", .scalar(.boolean, example: "true")),
                ],
                requiredKey: "name")),

        ConfigSectionSpec(
            .watchers,
            comment: "folder watchers running CUSTOM agents",
            value: .entityList(
                [
                    ConfigKeySpec("name", .scalar(.string, example: "Downloads sorter")),
                    ConfigKeySpec("agent", .scalar(.string, example: "Research Agent")),
                    ConfigKeySpec(
                        "instructions", .scalar(.string, example: "Organize new files.")),
                    ConfigKeySpec(
                        "path", .scalar(.string, example: "~/Downloads"),
                        comment: "existing directory; ~ expands"),
                    ConfigKeySpec("recursive", .scalar(.boolean, example: "false")),
                    ConfigKeySpec(
                        "responsiveness",
                        .scalar(
                            .string, example: "balanced",
                            allowed: [
                                "fast", "balanced", "patient", "relaxed",
                                "deferred", "extended",
                            ]),
                        comment: "fast | balanced | patient | relaxed |",
                        moreComments: ["deferred | extended"]),
                    ConfigKeySpec("enabled", .scalar(.boolean, example: "true")),
                ],
                requiredKey: "name")),
    ]

    // MARK: - Derived: strict validation tables

    /// Keys allowed in each mapping of the document, addressed by a
    /// dotted path (`""` = root, `"agents[]"` = one agents item, ...).
    public static let knownKeys: [String: Set<String>] = {
        var out: [String: Set<String>] = [
            "": Set(sections.map { $0.id.rawValue } + ["version"])
        ]
        for section in sections {
            collectKnownKeys(path: section.id.rawValue, value: section.value, into: &out)
        }
        return out
    }()

    private static func collectKnownKeys(
        path: String, value: ConfigValueSpec, into out: inout [String: Set<String>]
    ) {
        switch value {
        case .scalar, .scalarList, .freeformMap:
            return
        case .mapping(let keys):
            out[path] = Set(keys.map { $0.key })
            for key in keys {
                collectKnownKeys(path: "\(path).\(key.key)", value: key.value, into: &out)
            }
        case .entityList(let keys, _):
            out["\(path)[]"] = Set(keys.map { $0.key })
            for key in keys {
                collectKnownKeys(path: "\(path)[].\(key.key)", value: key.value, into: &out)
            }
        }
    }

    /// List paths whose items must each carry the given required key.
    public static let listItemRequiredKey: [String: String] = {
        var out: [String: String] = [:]
        for section in sections {
            collectRequiredKeys(path: section.id.rawValue, value: section.value, into: &out)
        }
        return out
    }()

    private static func collectRequiredKeys(
        path: String, value: ConfigValueSpec, into out: inout [String: String]
    ) {
        switch value {
        case .scalar, .scalarList, .freeformMap:
            return
        case .mapping(let keys):
            for key in keys {
                collectRequiredKeys(path: "\(path).\(key.key)", value: key.value, into: &out)
            }
        case .entityList(let keys, let requiredKey):
            out[path] = requiredKey
            for key in keys {
                collectRequiredKeys(path: "\(path)[].\(key.key)", value: key.value, into: &out)
            }
        }
    }

    /// Freeform-map value constraints, addressed by the dotted path of the
    /// freeform key (e.g. `"tools.policies"` -> auto | ask | deny).
    public static let freeformValueConstraints: [String: [String]] = {
        var out: [String: [String]] = [:]
        for section in sections {
            collectFreeformConstraints(path: section.id.rawValue, value: section.value, into: &out)
        }
        return out
    }()

    private static func collectFreeformConstraints(
        path: String, value: ConfigValueSpec, into out: inout [String: [String]]
    ) {
        switch value {
        case .scalar, .scalarList:
            return
        case .freeformMap(_, let allowedValues, _, _):
            if let allowedValues { out[path] = allowedValues }
        case .mapping(let keys):
            for key in keys {
                collectFreeformConstraints(
                    path: "\(path).\(key.key)", value: key.value, into: &out)
            }
        case .entityList(let keys, _):
            for key in keys {
                collectFreeformConstraints(
                    path: "\(path)[].\(key.key)", value: key.value, into: &out)
            }
        }
    }

    /// Spec lookup for the generic validation walk: dotted path -> spec.
    /// Top-level section values live under their raw section name.
    static let sectionValueByName: [String: ConfigValueSpec] = {
        var out: [String: ConfigValueSpec] = [:]
        for section in sections { out[section.id.rawValue] = section.value }
        return out
    }()

    // MARK: - Derived: JSON Schema

    /// Machine-readable JSON Schema (draft-07 subset) for the document.
    /// Used by `osaurus config schema --format json`,
    /// `GET /admin/config/schema`, and CI validation of stored templates.
    public static func jsonSchema() -> [String: Any] {
        var properties: [String: Any] = [
            "version": [
                "type": "integer",
                "const": version,
                "description": "Schema version. Currently always \(version).",
            ] as [String: Any]
        ]
        for section in sections {
            var schema = jsonSchema(for: section.value)
            if let comment = section.comment {
                schema["description"] = comment
            }
            properties[section.id.rawValue] = schema
        }
        return [
            "$schema": "http://json-schema.org/draft-07/schema#",
            "title": "Osaurus declarative configuration",
            "description":
                "Merge-by-default: absent keys stay untouched; explicit null clears an "
                + "override. Entities match by name (case-insensitive). Secrets never "
                + "appear in the document.",
            "type": "object",
            "additionalProperties": false,
            "properties": properties,
        ]
    }

    private static func jsonSchema(for value: ConfigValueSpec) -> [String: Any] {
        switch value {
        case .scalar(let type, _, let allowed, let nullable):
            var schema: [String: Any] =
                nullable
                ? ["type": [type.jsonType, "null"]]
                : ["type": type.jsonType]
            if let allowed { schema["enum"] = nullable ? allowed + [NSNull()] : allowed }
            return schema
        case .scalarList(let type, _):
            return [
                "type": "array",
                "items": ["type": type.jsonType],
            ]
        case .mapping(let keys):
            var properties: [String: Any] = [:]
            for key in keys {
                var schema = jsonSchema(for: key.value)
                if let comment = documentation(for: key) {
                    schema["description"] = comment
                }
                properties[key.key] = schema
            }
            return [
                "type": "object",
                "additionalProperties": false,
                "properties": properties,
            ]
        case .entityList(let keys, let requiredKey):
            var properties: [String: Any] = [:]
            for key in keys {
                var schema = jsonSchema(for: key.value)
                if let comment = documentation(for: key) {
                    schema["description"] = comment
                }
                properties[key.key] = schema
            }
            return [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": [requiredKey],
                    "properties": properties,
                ] as [String: Any],
            ]
        case .freeformMap(let type, let allowedValues, _, _):
            var valueSchema: [String: Any] = ["type": type.jsonType]
            if let allowedValues { valueSchema["enum"] = allowedValues }
            return [
                "type": "object",
                "additionalProperties": valueSchema,
            ]
        }
    }

    private static func documentation(for key: ConfigKeySpec) -> String? {
        var parts: [String] = []
        if let comment = key.comment { parts.append(comment) }
        parts.append(contentsOf: key.moreComments)
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: - Derived: schema reference text

    /// Column at which trailing comments start in the rendered reference.
    private static let commentColumn = 29

    /// The YAML sections of the model-facing schema reference, rendered
    /// from the specs. `ConfigSchemaReference` wraps this in the prose
    /// preamble / footer.
    public static func renderedSchemaSections(only filter: Set<ConfigSectionID>? = nil) -> String {
        var lines: [String] = ["version: \(version)"]
        for section in sections {
            if let filter, !filter.contains(section.id) { continue }
            lines.append("")
            lines.append(contentsOf: renderSection(section))
        }
        return lines.joined(separator: "\n")
    }

    /// A decodable example document built from the same specs — pinned by
    /// tests so every manifest key round-trips through `ConfigYAML.decode`
    /// (a manifest key with no Codable field, or a typo'd example, fails
    /// the suite instead of shipping).
    public static func exampleDocumentYAML() -> String {
        renderedSchemaSections()
    }

    private static func renderSection(_ section: ConfigSectionSpec) -> [String] {
        switch section.value {
        case .scalar(_, let example, _, _):
            return [
                withComment(
                    "\(section.id.rawValue): \(example)", comment: section.comment,
                    moreComments: [])
            ]
        case .scalarList(_, let example):
            var lines = [withComment("\(section.id.rawValue):", comment: section.comment, moreComments: [])]
            for item in example {
                lines.append("  - \(item)")
            }
            return lines
        case .mapping(let keys):
            var lines = [withComment("\(section.id.rawValue):", comment: section.comment, moreComments: [])]
            for key in keys {
                lines.append(contentsOf: renderKey(key, indent: 2, listItemHead: false))
            }
            return lines
        case .entityList(let keys, _):
            var lines = [withComment("\(section.id.rawValue):", comment: section.comment, moreComments: [])]
            lines.append(contentsOf: renderEntityItem(keys, indent: 2))
            return lines
        case .freeformMap:
            return [withComment("\(section.id.rawValue):", comment: section.comment, moreComments: [])]
        }
    }

    private static func renderEntityItem(_ keys: [ConfigKeySpec], indent: Int) -> [String] {
        var lines: [String] = []
        for (index, key) in keys.enumerated() {
            let head = index == 0
            lines.append(
                contentsOf: renderKey(
                    key, indent: head ? indent : indent + 2, listItemHead: head))
        }
        return lines
    }

    private static func renderKey(
        _ key: ConfigKeySpec, indent: Int, listItemHead: Bool
    ) -> [String] {
        let pad = String(repeating: " ", count: indent)
        let prefix = listItemHead ? "- " : ""
        switch key.value {
        case .scalar(_, let example, _, _):
            return [
                withComment(
                    "\(pad)\(prefix)\(key.key): \(example)",
                    comment: key.comment, moreComments: key.moreComments)
            ]
        case .scalarList(_, let example):
            if example.isEmpty {
                return [
                    withComment(
                        "\(pad)\(prefix)\(key.key): []",
                        comment: key.comment, moreComments: key.moreComments)
                ]
            }
            let inline = example.joined(separator: ", ")
            return [
                withComment(
                    "\(pad)\(prefix)\(key.key): [\(inline)]",
                    comment: key.comment, moreComments: key.moreComments)
            ]
        case .mapping(let keys):
            var lines = [
                withComment(
                    "\(pad)\(prefix)\(key.key):",
                    comment: key.comment, moreComments: key.moreComments)
            ]
            for child in keys {
                lines.append(
                    contentsOf: renderKey(
                        child, indent: indent + (listItemHead ? 4 : 2), listItemHead: false))
            }
            return lines
        case .entityList(let keys, _):
            var lines = [
                withComment(
                    "\(pad)\(prefix)\(key.key):",
                    comment: key.comment, moreComments: key.moreComments)
            ]
            lines.append(contentsOf: renderEntityItem(keys, indent: indent + 2))
            return lines
        case .freeformMap(_, _, let exampleKey, let exampleValue):
            var lines = [
                withComment(
                    "\(pad)\(prefix)\(key.key):",
                    comment: key.comment, moreComments: key.moreComments)
            ]
            lines.append("\(pad)  \(exampleKey): \(exampleValue)")
            return lines
        }
    }

    private static func withComment(
        _ line: String, comment: String?, moreComments: [String]
    ) -> String {
        guard let comment else { return line }
        let padded: String
        if line.count + 2 <= commentColumn {
            padded = line + String(repeating: " ", count: commentColumn - line.count)
        } else {
            padded = line + "  "
        }
        var out = padded + "# " + comment
        let continuationPad = String(repeating: " ", count: max(padded.count, commentColumn))
        for extra in moreComments {
            out += "\n" + continuationPad + "# " + extra
        }
        return out
    }

    // MARK: - Derived: discovery keywords

    /// Search keywords derived from the schema itself (section names and
    /// key names, humanized) — merged with the hand-written user-language
    /// phrases in `ConfigDeclarativeDomain` for capability discovery.
    public static func derivedSearchKeywords() -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func add(_ raw: String) {
            let phrase = raw.replacingOccurrences(of: "_", with: " ")
            guard seen.insert(phrase).inserted else { return }
            out.append(phrase)
        }
        for section in sections {
            add(section.id.rawValue)
            collectKeywords(value: section.value, add: add)
        }
        return out
    }

    private static func collectKeywords(value: ConfigValueSpec, add: (String) -> Void) {
        switch value {
        case .scalar, .scalarList, .freeformMap:
            return
        case .mapping(let keys), .entityList(let keys, _):
            for key in keys {
                add(key.key)
                collectKeywords(value: key.value, add: add)
            }
        }
    }
}
