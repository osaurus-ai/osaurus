# Claude Plugins

Import full Claude plugins from any GitHub repository — skills, scheduled agents, slash commands, MCP providers, and shared `CLAUDE.md` context — as a single managed bundle.

The Skills > Import > From GitHub flow recognises every published Anthropic plugin layout in the wild — the legacy flat skill marketplace, the directory-based plugin layout used by repos like [`anthropics/claude-for-legal`](https://github.com/anthropics/claude-for-legal), and the object-shaped marketplace used by [`anthropics/claude-plugins-community`](https://github.com/anthropics/claude-plugins-community) that points at external repos pinned to a specific commit. Plugins land tagged with a stable id so the whole bundle can be reinstalled, replaced, or uninstalled as a unit.

### Coverage matrix

| Anthropic repo                              | Marketplace shape                  | Supported? |
| ------------------------------------------- | ---------------------------------- | ---------- |
| `anthropics/skills`                         | Legacy flat (`skills: [String]`)   | ✅ Skills only |
| `anthropics/claude-for-legal`               | Directory-based (`source: "./dir"`) | ✅ Full bundle |
| `anthropics/financial-services`             | Directory-based + co-located scripts/refs + sibling-skill deps | ✅ Full bundle |
| `anthropics/knowledge-work-plugins`         | Directory-based + OAuth MCP + `CONNECTORS.md` + `${CLAUDE_PLUGIN_ROOT}` | ✅ Full bundle (OAuth MCP imports disabled, needs sign-in) |
| `anthropics/claude-plugins-community`       | Source-as-object (`url` / `git-subdir`, pinned by sha) | ✅ Full bundle |

---

## What Gets Imported

| Plugin Artifact                       | Mapped To              | Osaurus Surface                          |
| ------------------------------------- | ---------------------- | ---------------------------------------- |
| `skills/<name>/SKILL.md`              | Skill                  | Management → Skills                      |
| `skills/<name>/scripts/*`             | Skill reference/asset  | Attached to the owning skill             |
| `skills/<name>/references/*`          | Skill reference        | Attached to the owning skill             |
| `skills/<name>/assets/*`              | Skill asset            | Attached to the owning skill             |
| `skills/<name>/templates/*`           | Skill asset            | Attached to the owning skill             |
| `skills/<name>/*` (loose files)       | Skill reference/asset  | Attached to the owning skill             |
| `agents/<name>.md`                    | Schedule (disabled)    | Management → Schedules                   |
| `commands/<name>.md`                  | Slash command          | Available in chat input                  |
| `.mcp.json` (HTTP/SSE)                | MCP provider           | Management → Providers (MCP)             |
| `.mcp.json` (OAuth)                   | OAuth MCP provider     | Disabled, needs sign-in                  |
| `CLAUDE.md`                           | Reference file         | Attached to every imported skill         |
| `CONNECTORS.md`, `README.md`          | Reference file         | Attached to every imported skill         |

Skill instructions, attached references, slash commands, MCP tools, and the plugin's root markdown are then visible to the agent through the same automatic RAG selection used by built-in skills — no additional configuration is required.

`SKILL.md` bodies that use `${CLAUDE_PLUGIN_ROOT}/...` env-var paths or relative `../../<file>` markdown links are **rewritten at import time** to point at the local `references/` or `assets/` paths where the matching files were attached. Anything we couldn't bundle is listed in a footnote on the skill itself so the operator can see what wasn't materialised.

### Skill-local asset discovery

For every skill we import, the installer walks the skill directory:

1. Pulls every loose file at the skill root (e.g. `requirements.txt`, `TROUBLESHOOTING.md`).
2. Walks one level deep into `scripts/`, `references/`, `assets/`, `templates/`.
3. Stores text-y files (`.py`, `.md`, `.json`, `.html`, …) under the skill's `references/` directory so the model can read them as part of context. Everything else goes under `assets/`.
4. Files larger than 2 MiB are skipped to keep imports bounded — surface them through the upstream repo instead.

All fetches are gated through a shared concurrency limiter (8 in-flight at a time) so plugins like `pitch-agent` (13 skills × ~5 supporting files each) don't burn through the unauthenticated GitHub rate-limit budget on a single import.

### Not Imported

- **Stdio MCP servers** — Osaurus's remote MCP transport is HTTP/SSE only. Stdio entries in `.mcp.json` are listed in the install summary as "skipped"; configure them manually if needed.
- **Skill-local scripts at run time** — Python helpers and similar are attached so the operator can read or re-use them, but Osaurus does not execute them; the agent reads the source text only.
- **Hooks** — Claude Code-style hook scripts are ignored.

---

## Plugin Discovery

Osaurus reads `.claude-plugin/marketplace.json` from the repository root. Each plugin entry's `source` field can take **three shapes**, decoded by the `MarketplaceSource` sum type:

### 1. Directory-based (Claude plugin layout)

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

When `source` is a string, Osaurus probes that path inside the marketplace repo for the artifact families above. The probes (skills, agents, commands, `CLAUDE.md`, `CONNECTORS.md`, `README.md`, `.mcp.json`) run in parallel via the GitHub Contents API.

Expected layout:

```
<source>/
├── skills/
│   └── <skill-name>/
│       ├── SKILL.md
│       ├── scripts/        ← walked one level deep
│       ├── references/
│       ├── assets/
│       └── templates/
├── agents/
│   └── <agent-name>.md
├── commands/
│   └── <command-name>.md
├── CLAUDE.md               ← attached to every skill
├── CONNECTORS.md           ← attached to every skill
├── README.md               ← attached to every skill
└── .mcp.json
```

### 2. External repo (claude-plugins-community)

```json
{
  "name": "0x",
  "source": {
    "source": "url",
    "url": "https://github.com/0xProject/0x-ai.git",
    "sha": "fdb8a21d6e3a1d933c1043e21874e432790682dc"
  }
}
```

When `source` is an object with `"source": "url"`, the plugin lives at the root of an entirely different repository. Osaurus pins fetches to the declared `sha` (preferred) or `ref`. Plugin IDs still use the **marketplace repo** so grouping/uninstall stay stable across re-imports.

### 3. External subdirectory (`git-subdir`)

```json
{
  "name": "a11y-fixer",
  "source": {
    "source": "git-subdir",
    "url": "barnburner121/claude-plugin-marketplace",
    "path": "generated-plugins/a11y-fixer",
    "ref": "main",
    "sha": "5f6b5d32d9f457dc9c2c7c0fb1d67dffc9140f33"
  }
}
```

`"git-subdir"` targets a subpath inside an external repo, again pinned at a specific commit. Used by community marketplaces that aggregate plugins from many upstream repos.

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

### Sibling-plugin dependencies

Agent-style plugins (e.g. `pitch-agent` in `anthropics/financial-services`) often delegate to sibling skills with prose like:

> Invoke the `comps-analysis` skill to lay out trading comps.

After the plugin list loads, Osaurus fetches every agent body in the background, scans for these references, and builds a dependency graph. When the user toggles a parent plugin on, sibling plugins that own the referenced skills are auto-checked and surfaced under "Also selected — referenced by …". This makes orchestrator-style plugins work end-to-end out of the box.

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
- **MCP servers needing OAuth sign-in** — `.mcp.json` entries with an `oauth` block (e.g. Slack, Notion in `anthropics/knowledge-work-plugins`) are imported with `authType: .oauth` and the declared `clientId` + `callbackPort` pre-populated. Open Management → Providers and click "Sign in" on each one before enabling.
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

The installer reads `.mcp.json` and classifies each server entry:

| Entry shape                                              | Imported as                                  |
| -------------------------------------------------------- | -------------------------------------------- |
| `{ url, env: { API_KEY: "literal" } }`                   | Bearer-token provider (token in Keychain)    |
| `{ url, env: { API_KEY: "${VAR}" } }`                    | No-auth provider, flagged as needing token   |
| `{ url, oauth: { clientId, callbackPort } }`             | OAuth provider (`authType: .oauth`), disabled, flagged as needing sign-in |
| `{ url: "" }` (placeholder)                              | Skipped (manual setup)                       |
| `{ command, args }` (stdio)                              | Skipped (manual setup)                       |

For OAuth providers, the declared `clientId` and a `http://127.0.0.1:<callbackPort>/callback` `redirectURI` are stashed on the provider so the existing MCP OAuth service can complete the discovery + Dynamic Client Registration + PKCE handshake when the user clicks "Sign in". The provider stays disabled until that completes.

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

| Artifact            | Location                                                                  |
| ------------------- | ------------------------------------------------------------------------- |
| Skills              | `~/.osaurus/skills/<skill-name>/SKILL.md`                                 |
| Skill references    | `~/.osaurus/skills/<skill-name>/references/<basename>`                    |
| Skill assets        | `~/.osaurus/skills/<skill-name>/assets/<basename>`                        |
| Schedules           | Persisted by `ScheduleManager`                                            |
| Slash commands      | Persisted by `SlashCommandRegistry`                                       |
| MCP providers       | `MCPProviderConfiguration` + secrets in macOS Keychain                    |
| `CLAUDE.md` / `CONNECTORS.md` / `README.md` | Attached as references inside each owning skill directory |

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
- [Schedules](FEATURES.md#schedules) — Recurring agent runs
- [Features Inventory](FEATURES.md#claude-plugin-import) — Canonical feature record
