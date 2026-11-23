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
            + "model defaults (core and compaction model), chat switches, app basics (hotkey, "
            + "start at login, notifications), "
            + "models, plugins, MCP, providers, search, automations (schedules, folder watchers, "
            + "webhooks that run an agent or workflow), tools, delegation, commands, knowledge, "
            + "channels (who answers messages per room, who may post).",
        menuHint:
            "apply a small declarative YAML config change (schema documents the format; plan previews big or destructive changes)",
        // Hand-written user-language phrases, plus every section/key name
        // from the manifest (humanized) so new declarative keys rank
        // discovery without editing this list. Server phrases were dropped
        // with that section (Settings UI only).
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
            "event", "trigger", "webhook", "when a message arrives", "run workflow when",
            "imessage rule", "slack trigger", "discord trigger", "routing rule", "who answers",
            "route channel to agent", "agent posts to slack", "workflow inputs",
            "enable tool", "disable tool", "tool permission", "tool policy",
            "import", "install skill", "skill.md", "set up from link", "install from github",
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
            "run my triage workflow when a slack message arrives",
            "route #support on slack to the triage agent",
            "add a webhook that runs an agent",
            "apply this yaml config",
            "read https://example.com/SKILL.md and set it up",
        ],
        tools: [
            OsaurusConfigTool(),
            OsaurusImportTool(),
        ],
        writeToolNames: [
            "osaurus_config",
            OsaurusImportTool.toolName,
        ]
    )
}
