# Skills

Import and manage reusable AI capabilities following the open [Agent Skills](https://agentskills.io/) specification.

Skills are packages of instructions, context, and resources that give your AI specialized expertise. Whether you need a research analyst, debugging assistant, or creative brainstormer, skills let you extend your AI's capabilities on demand.

---

## Quick Start

Osaurus comes with 6 built-in skills ready to use:

| Skill | Description |
|-------|-------------|
| **Research Analyst** | Structured research with source evaluation and citation |
| **Creative Brainstormer** | Ideation and creative problem solving |
| **Study Tutor** | Educational guidance using the Socratic method |
| **Productivity Coach** | Task management and productivity optimization |
| **Content Summarizer** | Distill long content into concise summaries |
| **Debug Assistant** | Systematic debugging methodology |

**To get started:**

1. Open Management window (`⌘ Shift M`) → **Skills**
2. Enable a skill by toggling it on
3. Start a new chat — the AI now has access to the skill's expertise

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

---

## Managing Skills

### Enable/Disable

Toggle skills on or off from the Skills view. Disabled skills won't be available to the AI.

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
name: Research Analyst
description: Structured research with source evaluation
category: Research
version: 1.0.0
author: Your Name
---

# Research Analyst

You are a research analyst specializing in thorough, well-sourced research.

## Methodology

1. Understand the research question
2. Identify reliable sources
3. Evaluate source credibility
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
└── research-analyst/
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

**Limits:** Each reference file can be up to 100KB.

---

## Automated Capability Selection

Osaurus uses a RAG-based system to automatically select and inject relevant skills into each conversation. No manual configuration is needed -- the right skills are loaded based on what you're asking about.

### How It Works

Before each agent loop, a **preflight capability search** runs across all indexed skills (as well as methods and tools). The search uses hybrid BM25 + vector matching to find capabilities relevant to your query, then injects matching skill instructions directly into the system prompt.

### Search Modes

You can control how aggressively the system searches for capabilities:

| Mode        | Skills Loaded | Description                               |
| ----------- | ------------- | ----------------------------------------- |
| `off`       | 0             | Disable automatic selection               |
| `narrow`    | 1             | Minimal context, fastest responses        |
| `balanced`  | 2             | Default — good coverage, moderate cost    |
| `wide`      | 4             | Maximum coverage, larger prompts          |

### Runtime Discovery

During a conversation, the AI can also discover and load additional capabilities on demand:

1. **`capabilities_search`** — Searches all indexed methods, tools, and skills in parallel
2. **`capabilities_load`** — Loads a specific capability into the active session

This means the AI starts with automatically selected skills and can dynamically expand its capabilities as the conversation evolves.

### Why This Matters

- **Zero configuration** — Skills are selected based on relevance, not manual toggles
- **Better focus** — Only relevant skills are loaded, keeping context lean
- **Adaptive** — The AI can discover additional skills mid-conversation if the topic shifts
- **Works with Methods** — Learned workflows (methods) are searched alongside skills, so the AI benefits from past experience

---

## Agent Integration

Skills are available to all agents automatically. The RAG-based preflight search selects relevant skills for each query regardless of which agent is active.

**How it works with agents:**

- Each agent's system prompt guides its behavior and specialization
- When you send a message, the preflight search finds skills relevant to your query
- Matching skill instructions are injected into the agent's context
- The agent can discover additional skills at runtime via `capabilities_search`

No per-agent skill configuration is needed. The system automatically matches the right skills to the right tasks.

---

## Troubleshooting

### Skills not appearing in chat

- Verify the skill is enabled (toggle is on)
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
