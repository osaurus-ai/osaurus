# Skills

Import and manage reusable AI capabilities following the open [Agent Skills](https://agentskills.io/) specification.

Skills are packages of instructions, context, and resources that give your AI specialized expertise. Whether you need a research analyst, debugging assistant, or creative brainstormer, skills let you extend your AI's capabilities on demand.

---

## Quick Start

Osaurus comes with 9 built-in skills ready to use. Each one teaches the AI a concrete workflow built on real Osaurus tools:

| Skill | Description |
|-------|-------------|
| **Web Researcher** | Live web research with source retrieval, cross-checking, and cited reports |
| **Content Summarizer** | Retrieve pages or files, then distill them into structured summaries |
| **Mac Automator** | Control and query Mac apps with AppleScript automation |
| **Personal Organizer** | Manage calendar events, reminders, email, and messages |
| **Document Builder** | Create spreadsheets and presentations, delivered as downloadable files |
| **Workspace Assistant** | Read, edit, search, and commit files in the mounted working folder |
| **Data Keeper** | Keep structured records across chats in the agent's private database |
| **Autonomous Scheduler** | Set up recurring or delayed self-running tasks with notifications |
| **Data Visualizer** | Render charts and graphs from attached, retrieved, or computed data |

**To get started:**

1. Open Management window (`⌘ Shift M`) → **Skills**
2. Browse the library — every installed skill is automatically available to your custom agents
3. Start a chat — the AI discovers and loads relevant skills on demand, or type `/skill-name` to invoke one explicitly for a single message

There are no enable/disable toggles and no per-agent assignment: installing or creating a skill puts it in the library, and deleting it (or uninstalling its plugin) removes it. The built-in Osaurus configuration agent is the one exception — it does not use skills.

---

## Importing Skills

### From GitHub

Import skills from any GitHub repository that includes a skills marketplace:

1. Click **Import** → **From GitHub**
2. Enter the repository URL (e.g., `github.com/owner/repo` or `owner/repo`)
3. Browse available skills and select which to import
4. Click **Import Selected**

Osaurus looks for `.claude-plugin/marketplace.json` in the repository to discover available skills.

> **Full Claude plugins:** Osaurus also recognises the directory-based Claude plugin layout (e.g. [`anthropics/claude-for-legal`](https://github.com/anthropics/claude-for-legal)) and can import scheduled agents, slash commands, MCP providers, and a shared `CLAUDE.md` context alongside the skills. See [Claude Plugins](CLAUDE_PLUGINS.md) for the full plugin import flow.

### From Files

Import skills from local files:

1. Click **Import** → **From File**
2. Select a skill file

**Supported formats:**

| Format | Description |
|--------|-------------|
| `.md` / `SKILL.md` | Agent Skills format (Markdown with YAML frontmatter) |
| `.json` | JSON export format |
| `.zip` | ZIP archive with `SKILL.md` and optional `references/` and `assets/` folders |

Local file imports are checked before they are saved:

- ZIP archives are bounded by archive size, file count, per-file size, and path depth.
- Archive entries must stay inside the archive root. Symlinks and non-regular files are refused.
- If a ZIP contains more than one `SKILL.md`, Osaurus imports the shallowest path, then the lexicographically first path, and reports the ignored candidates.
- Importing a file over an existing skill stops first and asks for an explicit replace confirmation.

---

## Managing Skills

### Library Filters

The Skills view groups the library by source: **All**, **Built-in**, **Yours**, and **From Plugins**. Built-ins are view-only, your own skills support the full edit/export/delete lifecycle, and plugin skills are removed by uninstalling their plugin.

### Edit

Click a skill to expand it, then click **Edit** to modify:

- **Name** and **Description**
- **Category** for organization
- **Instructions** — the full guidance given to the AI
- **Version** and **Author** metadata

Built-in skills are read-only but can be viewed.

### Export

Export skills to share with others:

1. Expand a skill and click **Export**
2. Choose a format:
   - **JSON** — Osaurus format for backup
   - **Markdown** — Agent Skills compatible `.md` file
   - **ZIP** — Complete package with references and assets

### Delete

Click **Delete** to remove a custom skill. Built-in skills cannot be deleted.

### Installed Plugins

When you import a full Claude plugin from GitHub, the **Installed Plugins** card appears at the top of the Skills view. Each row shows the plugin name, source slug, and chips for its skill / schedule / command / MCP counts. Click **Uninstall** to remove every artifact the plugin contributed (skills, schedules, slash commands, MCP providers, and any Keychain-stored tokens) in one shot.

Only plugins imported via the GitHub flow are listed here — Osaurus's built-in tool plugins are managed separately. See [Claude Plugins](CLAUDE_PLUGINS.md) for the full lifecycle.

---

## Creating Custom Skills

Create your own skills with the built-in editor:

1. Click **Create Skill**
2. Fill in the details:
   - **Name** — A clear, descriptive name
   - **Description** — Brief summary (shown in the skill list)
   - **Category** — Optional grouping (e.g., "Development", "Writing")
   - **Instructions** — Detailed guidance for the AI (Markdown supported)
3. Click **Save**

**Tips for writing effective instructions:**

- Be specific about the skill's purpose and approach
- Include examples of expected behavior
- Define any frameworks or methodologies to follow
- Specify output formats when relevant

---

## Skill Format

Osaurus follows the [Agent Skills specification](https://agentskills.io/), using `SKILL.md` files with YAML frontmatter:

```markdown
---
name: Web Researcher
description: Live web research with source retrieval and cited reports
category: Research
version: 1.0.0
author: Your Name
---

# Web Researcher

You are a web researcher specializing in thorough, well-sourced research.

## Methodology

1. Understand the research question
2. Search the web for candidate sources
3. Retrieve and evaluate each source
4. Synthesize findings
5. Present with citations

## Output Format

Always include:
- Executive summary
- Key findings
- Source citations
- Confidence assessment
```

### Directory Structure

Skills are stored as directories:

```
~/.osaurus/skills/
└── web-researcher/
    ├── SKILL.md           # Main skill file
    ├── references/        # Optional: files loaded into context
    │   └── guidelines.txt
    └── assets/            # Optional: supporting files
        └── template.md
```

---

## Reference Files

Add context files that are automatically loaded when the skill is active:

1. Edit a skill
2. Add files to the `references/` folder
3. Text files (`.txt`, `.md`, etc.) are loaded into the AI's context

**Use cases:**

- Style guides and formatting rules
- Domain-specific terminology
- Process documentation
- Example templates

References ride along on both delivery paths: `/skill-name` invocation includes them in full, and model-initiated loading (`capabilities_load`) includes them up to a size budget — past it, remaining files are named in an omission note so the AI knows they exist.

**Limits:** Each reference file can be up to 100KB.

---

## Automated Capability Discovery

Osaurus gives the agent a complete, statically-ordered view of every available capability and lets it load the ones it needs on demand. No manual per-turn configuration is needed -- the right skills surface as the conversation evolves.

### How It Works

Each agent session's system prompt carries a **capabilities manifest** that lists every installed skill (as well as methods and the agent's assigned tools). The manifest is frozen at session start so the static prompt prefix stays byte-stable across turns. Skill instructions themselves are not all injected up front — the agent pulls in the ones it needs at runtime via `capabilities_discover` / `capabilities_load`, which use hybrid BM25 + vector matching over the indexed catalog.

### Runtime Discovery

During a conversation, the AI discovers and loads capabilities on demand:

1. **`capabilities_discover`** — Searches all indexed methods, tools, and skills in parallel
2. **`capabilities_load`** — Loads a specific capability into the active session

The AI starts with the manifest plus a fixed "hot set" of always-loaded tools, then dynamically expands its capabilities as the conversation evolves.

### Why This Matters

- **Zero configuration** — Capabilities are listed in the manifest, not toggled by hand
- **Better focus** — Only loaded capabilities ride in the schema, keeping context lean
- **Adaptive** — The AI can discover additional skills mid-conversation if the topic shifts
- **Cache-friendly** — Freezing the manifest keeps the static prompt prefix stable for KV-cache reuse
- **Works with Methods** — Learned workflows (methods) are searchable alongside skills, so the AI benefits from past experience

---

## Agent Integration

Skills are available to all custom agents automatically. The capabilities manifest lists the installed skill library for each agent, and `capabilities_discover` reaches the full catalog regardless of which custom agent is active.

**How it works with agents:**

- Each agent's system prompt guides its behavior and specialization
- The capabilities manifest tells the agent which skills exist in the library
- The agent loads skill instructions on demand via `capabilities_discover` / `capabilities_load`
- Typing `/skill-name` forces a specific skill for a single message

No per-agent skill configuration is needed — agent configuration only scopes **tools**. The built-in Osaurus configuration agent does not use skills.

---

## Troubleshooting

### Skills not appearing in chat

- Verify the skill appears in the Skills library (Management window → Skills)
- Check that the skill's description clearly describes its purpose (the RAG search uses this)
- Start a new chat session
- Try setting a wider search mode in chat configuration

### GitHub import fails

- Ensure the repository is public or you have access
- Verify the repo contains `.claude-plugin/marketplace.json`
- Check your network connection
- If you see "GitHub rate-limited this app", wait for the reset time shown in the error and retry — unauthenticated requests are capped at 60/hour. See [Claude Plugins → Rate Limiting](CLAUDE_PLUGINS.md#rate-limiting).

### Skill instructions not being followed

- Review the skill's instructions for clarity
- Ensure the skill's description is specific enough for the RAG search to match it
- Try being more explicit in your request to improve search relevance

### Import format errors

- For `.md` files: Ensure valid YAML frontmatter between `---` markers
- For `.zip` files: Ensure `SKILL.md` is at the root or in a named folder
- For `.json` files: Validate JSON syntax

---

## Related Documentation

- [Claude Plugins](CLAUDE_PLUGINS.md) — Full plugin imports (skills + schedules + commands + MCP + `CLAUDE.md`)
- [Agents](../README.md#agents) — Custom AI assistants
- [Tools & Plugins](plugins/README.md) — Extend with custom tools
- [Agent Skills Specification](https://agentskills.io/) — Open format documentation
- [Features: Methods](FEATURES.md#methods) — Reusable learned workflows
- [Features: Context Management](FEATURES.md#context-management) — Automated capability selection
