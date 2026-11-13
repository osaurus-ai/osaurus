# Skills

Import and manage reusable AI capabilities following the open [Agent Skills](https://agentskills.io/) specification.

Skills are packages of instructions, context, and resources that give your AI specialized expertise. Whether you need a research analyst, debugging assistant, or creative brainstormer, skills let you extend your AI's capabilities on demand.

---

## Quick Start

Osaurus comes with 9 built-in skills ready to use. Each one teaches the AI a concrete workflow built on real Osaurus tools:

| Skill | Description |
|-------|-------------|
| **Web Researcher** | Live web research with source retrieval, cross-checking, and cited reports |
| **Content Summarizer** | Extract key points and create structured summaries |
| **Mac Automator** | Control and query Mac apps with AppleScript automation |
| **Personal Organizer** | Manage calendar events, reminders, email, and messages |
| **Document Builder** | Create spreadsheets and presentations, delivered as downloadable files |
| **Workspace Assistant** | Work on files in the mounted folder: read, edit, search, run commands, commit |
| **Data Keeper** | Keep structured records across chats in the agent's private database |
| **Autonomous Scheduler** | Set up recurring or delayed self-running tasks with notifications |
| **Data Visualizer** | Render charts and graphs from attached, retrieved, or computed data |

**To get started:**

1. Open Settings… (`⌘,`) → **Skills** (in the Context group)
2. Browse the library — every installed skill is automatically available to your custom agents
3. Start a chat — the AI discovers and loads relevant skills on demand, or type `/skill-name` to invoke one explicitly for a single message

There are no enable/disable toggles: installing or creating a skill puts it in the library for every custom agent, and deleting it (or uninstalling its plugin) removes it. A custom agent can narrow the library with **Limit to selected skills** (Agents → the agent → Abilities → Tools; `agents[].skills` in the declarative document). The built-in Osaurus configuration agent does not use skills.

---

## Importing Skills

### From GitHub

Import skills from any GitHub repository that includes a skills marketplace:

1. Click **Add Skill** → **Import Claude plugin from GitHub**
2. Enter the repository URL (e.g., `github.com/owner/repo` or `owner/repo`)
3. Browse available skills and select which to import
4. Click **Import N Skills** (or **Install N Plugins** for full plugins)

Osaurus looks for `.claude-plugin/marketplace.json` in the repository to discover available skills.

> **Full Claude plugins:** Osaurus also recognises the directory-based Claude plugin layout (e.g. [`anthropics/claude-for-legal`](https://github.com/anthropics/claude-for-legal)) and can import scheduled agents, slash commands, MCP providers, and a shared `CLAUDE.md` context alongside the skills. See [Claude Plugins](CLAUDE_PLUGINS.md) for the full plugin import flow.

### From Files

Import skills from local files:

1. Click **Add Skill** → **Import Skill**
2. Select a `SKILL.md` / `.md` file or a `.zip` bundle

**Supported formats:**

| Format | Description |
|--------|-------------|
| `.md` / `SKILL.md` | Agent Skills format (Markdown with YAML frontmatter) |
| `.zip` | ZIP archive with `SKILL.md` and optional `references/` and `assets/` folders |

Local file imports are checked before they are saved:

- ZIP archives are bounded by archive size, file count, per-file size, and path depth.
- Archive entries must stay inside the archive root. Symlinks and non-regular files are refused.
- If a ZIP contains more than one `SKILL.md`, Osaurus imports the shallowest path, then the lexicographically first path, and reports the ignored candidates.
- Importing a file over an existing skill stops first and asks for an explicit replace confirmation.

---

## Managing Skills

### Library Tabs

The Skills view has three tabs: **All** (every installed skill), **Custom** (skills you created or imported), and **Claude Plugins** (the plugin marketplace and your installed Claude plugins). Built-ins are view-only, your own skills support the full edit/export/delete lifecycle, and plugin skills are removed by uninstalling their plugin.

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
   - **SKILL.md** — Agent Skills compatible Markdown file
   - **ZIP** — Complete package with references and assets

### Delete

Click **Delete** to remove a custom skill. Built-in skills cannot be deleted.

### Installed Plugins

Full Claude plugins you import from GitHub appear on the **Claude Plugins** tab, one card per plugin with its name, source, and what it contributed. Click **Uninstall** on the card (or in its detail view) to remove every artifact the plugin contributed (skills, schedules, slash commands, MCP providers, and any Keychain-stored tokens) in one shot.

Only plugins imported via the GitHub flow are listed here — Osaurus's built-in tool plugins are managed separately. See [Claude Plugins](CLAUDE_PLUGINS.md) for the full lifecycle.

---

## Creating Custom Skills

Create your own skills with the built-in editor:

1. Click **Add Skill** → **Create Skill**
2. Fill in the details:
   - **Name** — A clear, descriptive name
   - **Description** — Brief summary (shown in the skill list)
   - **Category** — Optional grouping (e.g., "Development", "Writing")
   - **Keywords** — Comma-separated discovery terms (see below)
   - **Instructions** — Detailed guidance for the AI (Markdown supported)
3. Click **Save**

**Tips for writing effective instructions:**

- Be specific about the skill's purpose and approach
- Include examples of expected behavior
- Define any frameworks or methodologies to follow
- Specify output formats when relevant

**Keywords are how the AI finds your skill.** The capability search indexes the skill's name, keywords, and description — not its instructions. Add the words a user would actually say when they need the skill ("summarize, tldr, key points" rather than "text processing"). Every built-in skill ships a rich keyword list for exactly this reason; a custom skill without keywords is only found through its name and description.

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

Skills are available to all custom agents automatically, unless an agent turns on **Limit to selected skills**. With it on, only the ticked skills appear in the agent's capabilities manifest, `capabilities_load`, and its slash commands.

**How it works with agents:**

- Each agent's system prompt guides its behavior and specialization
- The capabilities manifest tells the agent which skills exist in the library
- The agent loads skill instructions on demand via `capabilities_discover` / `capabilities_load`
- Typing `/skill-name` forces a specific skill for a single message

No per-agent skill configuration is needed; **Limit to selected skills** is the only per-agent control, and it starts off. The built-in Osaurus configuration agent does not use skills.

---

## Troubleshooting

### Skills not appearing in chat

- Verify the skill appears in the Skills library (Settings… → Skills)
- Add **keywords** to the skill (edit it in the library): the capability search indexes name + keywords + description, and keywords carry the most weight
- Check that the skill's description clearly describes its purpose (the search uses this too)
- Start a new chat session — the capabilities manifest is frozen when a chat starts, so skills added mid-conversation aren't listed until the next chat (they remain reachable via `capabilities_discover`)
- Type `/skill-name` to invoke the skill explicitly for one message — this injects the full instructions deterministically and doesn't depend on search at all
- Skills require **Auto** tool mode with tools enabled; **Custom** tool mode and the built-in Osaurus configuration agent don't use the skill library
- If the agent has **Limit to selected skills** on, check the skill is ticked under **Choose Skills…**

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

---

## Related Documentation

- [Claude Plugins](CLAUDE_PLUGINS.md) — Full plugin imports (skills + schedules + commands + MCP + `CLAUDE.md`)
- [Agents](../Packages/OsaurusCore/Resources/Guide/guide-agents.md) — Custom AI assistants
- [Tools & Plugins](plugins/README.md) — Extend with custom tools
- [Agent Skills Specification](https://agentskills.io/) — Open format documentation
- [Features: Methods](FEATURES.md#methods) — Reusable learned workflows
- [Features: Context Management](FEATURES.md#context-management) — Automated capability selection
