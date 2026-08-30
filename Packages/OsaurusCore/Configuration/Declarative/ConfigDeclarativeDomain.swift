//
//  ConfigDeclarativeDomain.swift
//  osaurus
//
//  The single `ConfigurationDomain` for the declarative `osaurus_config`
//  tool. Replaces the nine per-domain write tools (osaurus_settings,
//  osaurus_agent, osaurus_mcp, osaurus_model, osaurus_plugin,
//  osaurus_provider, osaurus_search, osaurus_schedule, osaurus_watcher)
//  as the only configuration write surface for the Default agent.
//

import Foundation

enum ConfigDeclarativeDomain {
    static let domain = ConfigurationDomain(
        id: "config",
        displayName: "Configuration",
        summary:
            "Configure Osaurus with one declarative YAML document: memory, agents, "
            + "models, plugins, MCP, providers, search, schedules, watchers, tools, "
            + "delegation, commands, knowledge, channels.",
        menuHint:
            "export / plan / apply a declarative YAML config (schema first, plan before apply)",
        // Hand-written user-language phrases, plus every section/key name
        // from the manifest (humanized) so new declarative keys rank
        // discovery without editing this list. Server/chat/app phrases were
        // dropped with those sections (Settings UI only).
        searchKeywords: [
            "config", "configuration", "configure", "settings", "setup", "yaml", "json",
            "template",
            "custom agent", "persona", "create agent", "delete agent",
            "switch agent", "activate agent",
            "model", "download model", "delete model", "huggingface", "mlx",
            "plugin", "install plugin", "uninstall plugin",
            "mcp", "mcp server", "model context protocol", "tool server",
            "provider", "api key", "anthropic", "openai", "claude", "gpt",
            "gemini", "openrouter", "deepseek", "ollama", "connect provider", "sign in",
            "search provider", "tavily", "brave search", "search ranking",
            "schedule", "cron", "daily", "every morning",
            "watcher", "watch folder", "when files change",
            "enable tool", "disable tool", "tool permission", "tool policy",
        ] + ConfigManifest.derivedSearchKeywords(),
        exampleQueries: [
            "set up osaurus for research work",
            "export my configuration as a template",
            "create a research agent with web search",
            "download Llama 3",
            "install the weather plugin",
            "add an MCP server",
            "connect anthropic",
            "add tavily as a search provider",
            "summarize news every morning at 8",
            "watch my downloads folder",
            "apply this yaml config",
        ],
        tools: [
            OsaurusConfigTool()
        ],
        writeToolNames: [
            "osaurus_config"
        ]
    )
}
