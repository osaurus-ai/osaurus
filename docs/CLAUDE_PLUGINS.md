# Claude Plugins

Import full Claude plugins from any GitHub repository — skills, scheduled agents, slash commands, MCP providers, and shared `CLAUDE.md` context — as a single managed bundle.

The Skills > Import > From GitHub flow recognises both the legacy flat skill marketplace and the directory-based plugin layout used by repositories like [`anthropics/claude-for-legal`](https://github.com/anthropics/claude-for-legal). Plugins land tagged with a stable id so the whole bundle can be reinstalled, replaced, or uninstalled as a unit.

---

## What Gets Imported

| Plugin Artifact            | Mapped To              | Osaurus Surface                          |
| -------------------------- | ---------------------- | ---------------------------------------- |
| `skills/<name>/SKILL.md`   | Skill                  | Management → Skills                      |
| `agents/<name>.md`         | Schedule (disabled)    | Management → Schedules                   |
| `commands/<name>.md`       | Slash command          | Available in chat input                  |
| `.mcp.json` (HTTP/SSE)     | MCP provider           | Management → Providers (MCP)             |
| `CLAUDE.md`                | Reference file         | Attached to every imported skill         |

Skill instructions, slash commands, MCP tools, and the `CLAUDE.md` context are then visible to the agent through the same automatic RAG selection used by built-in skills — no additional configuration is required.

### Not Imported

- **Stdio MCP servers** — Osaurus's remote MCP transport is HTTP/SSE only. Stdio entries in `.mcp.json` are listed in the install summary as "skipped"; configure them manually if needed.
- **Hooks, scripts, binary assets** — Anything outside the four artifact families above is ignored.

---

## Plugin Discovery

Osaurus reads `.claude-plugin/marketplace.json` from the repository root. Two manifest shapes are supported:

### Directory-based (Claude plugin layout)

```json
{
  "name": "claude-for-legal",
  "plugins": [
    {
      "name": "commercial-legal",
      "source": "./commercial-legal",
      "description": "Drafts, reviews, and negotiates commercial agreements"
    }
  ]
}
```

When a plugin lists a `source` directory, Osaurus probes it for the artifact families listed above. The five probes (skills, agents, commands, `CLAUDE.md`, `.mcp.json`) run in parallel via the GitHub Contents API.

Expected layout:

```
<source>/
├── skills/
│   └── <skill-name>/SKILL.md
├── agents/
│   └── <agent-name>.md
├── commands/
│   └── <command-name>.md
├── CLAUDE.md
└── .mcp.json
```

### Legacy flat marketplace

```json
{
  "name": "my-skills",
  "plugins": [
    {
      "name": "research-tools",
      "skills": ["skills/research-analyst.md", "skills/citation-checker.md"]
    }
  ]
}
```

When `skills` is an array of paths and no `source` is given, Osaurus uses the older flat skill picker — no agent/command/MCP discovery is performed.

---

## Importing

1. Open Management (`⌘ Shift M`) → **Skills**.
2. Click **Import** → **From GitHub**.
3. Enter the repository (`owner/repo` or full URL).
4. Pick which plugins (and which artifacts within each plugin) to install.
5. Click **Install Selected**.

The progress indicator shows `current / total` artifacts. File fetches run concurrently; mutations are applied serially on the main actor so the four backing managers stay consistent.

### Install Summary

After install, the sheet shows a per-plugin summary including:

- **Imported counts** — skills, schedules, commands, MCP providers
- **Schedules needing cron** — agent markdown files where no recurrence could be inferred. Click a row to deep-link into the schedule editor with the cron field focused.
- **MCP providers with placeholder tokens** — when `.mcp.json` uses `${VAR}`, `$VAR`, or `<token>` style env references, the provider is created without a token. Paste a real one in Management → Providers before enabling.
- **Skipped stdio MCP servers** — listed for manual configuration.
- **Errors** — any per-artifact failures (one bad skill does not abort the import).

---

## Plugin IDs

Every artifact imported by the installer is tagged with:

```
github:<owner>/<repo>/<plugin-name>
```

For example, `commercial-legal` from `anthropics/claude-for-legal` becomes:

```
github:anthropics/claude-for-legal/commercial-legal
```

The plugin id is stored on each artifact (`Skill.pluginId`, `Schedule.parameters["pluginId"]`, `SlashCommand.pluginId`, `MCPProvider.pluginId`) and powers the grouped management UI.

### Idempotent Re-install

Re-importing the same plugin always **replaces** its non-skill artifacts (schedules, commands, MCP providers) before recreating them. Skills are deduplicated by `(pluginId, name)`. This means you can safely re-run the import to pick up upstream changes without piling up duplicates.

To opt out (e.g. in tests), pass `replaceExisting: false` to `ClaudePluginInstaller.install`.

---

## Managing Installed Plugins

The **Installed Plugins** card at the top of the Skills view aggregates everything tagged with a `github:` plugin id. Each row shows:

- Plugin name (e.g. "Commercial Legal") and source slug (`anthropics/claude-for-legal`)
- Chips for skill / schedule / command / MCP counts
- An **Uninstall** affordance that fades in on hover

Uninstalling a plugin removes the corresponding skills, schedules, slash commands, and MCP providers in one shot, including any Keychain-stored MCP tokens.

Osaurus's own internal plugins (`PluginManager`, Wasm-based tool plugins) are not surfaced here — only the `github:` namespace is shown.

---

## Cron Inference

Scheduled agents (`agents/*.md`) carry natural-language frequency text in their frontmatter or body (e.g. "Run every Monday at 9am"). The installer tries to map this to a cron expression; when it can't, the schedule lands **disabled** and appears under "Schedules needing cron" in the install summary so you can open the editor and set one explicitly.

---

## MCP Provider Import

The installer reads `.mcp.json` and creates one Osaurus MCP provider per HTTP/SSE server entry:

- **URL** → provider endpoint
- **Headers** → forwarded to the remote server
- **Token-like env vars** (`Bearer ${VAR}`, `Authorization: $TOKEN`) → stored in the Keychain when a literal value is provided; left blank when the value is a placeholder
- **Stdio servers** → skipped (listed in the install summary)

Providers are tagged with the plugin id, so uninstalling the plugin removes them and clears their Keychain secrets.

---

## Error Handling

### Rate Limiting

Unauthenticated GitHub requests are subject to a 60-per-hour limit shared across all repositories. When Osaurus detects a `403` response with `X-RateLimit-Remaining: 0`, the import sheet displays:

> GitHub rate-limited this app. Try again in ~45 minutes.

The relative time is parsed from `X-RateLimit-Reset`. Wait for the reset (or sign in to the GitHub CLI / set up a token in a future release) before retrying.

### Marketplace Not Found

If `.claude-plugin/marketplace.json` is missing, the import sheet reports that the repository has no plugins. The check is case-sensitive and runs against the repo's default branch.

### Per-Artifact Failures

The installer keeps going if any single file fails to download or parse. Failures are surfaced as `errors` entries in the install summary alongside the successful imports.

---

## Storage

| Artifact      | Location                                                          |
| ------------- | ----------------------------------------------------------------- |
| Skills        | `~/.osaurus/skills/<skill-name>/SKILL.md`                         |
| Schedules     | Persisted by `ScheduleManager`                                    |
| Slash commands| Persisted by `SlashCommandRegistry`                               |
| MCP providers | `MCPProviderConfiguration` + secrets in macOS Keychain            |
| `CLAUDE.md`   | Attached as a reference inside each owning skill directory        |

---

## Code Locations

| Layer        | File                                                                                 |
| ------------ | ------------------------------------------------------------------------------------ |
| Discovery    | `Packages/OsaurusCore/Services/GitHubSkillService.swift`                             |
| Installation | `Packages/OsaurusCore/Services/Skill/ClaudePluginInstaller.swift`                    |
| Import UI    | `Packages/OsaurusCore/Views/Skill/GitHubImportSheet.swift`                           |
| Management UI| `Packages/OsaurusCore/Views/Skill/InstalledPluginsSection.swift`                     |
| Schedule deep-link | `Packages/OsaurusCore/Managers/ManagementStateManager.swift`, `Views/Schedule/SchedulesView.swift` |
| Tests        | `Packages/OsaurusCore/Tests/Skill/ClaudePluginInstallerTests.swift`                  |

---

## Related Documentation

- [Skills](SKILLS.md) — Skill format, RAG selection, and built-in skills
- [Remote MCP Providers](REMOTE_MCP_PROVIDERS.md) — Manual MCP setup and HTTP/SSE transport details
- [Schedules](../README.md#schedules) — Recurring agent runs
- [Features Inventory](FEATURES.md#claude-plugin-import) — Canonical feature record
