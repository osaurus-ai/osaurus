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

## Smart Capability Selection

Skills uses a smart loading system that saves up to 80% of context space.

### How It Works

Instead of loading all skill instructions upfront (which can consume thousands of tokens), Osaurus uses a two-phase approach:

**Phase 1 — Catalog**
- The AI sees a lightweight menu of available skills (just names and descriptions)
- This uses minimal tokens (~10-20 per skill)

**Phase 2 — Selection**
- The AI picks which skills are relevant to your request
- Only selected skills are fully loaded into context
- Unneeded skills don't consume any context space

### Why This Matters

- **More room for conversation** — Your messages and the AI's responses have more space
- **Faster responses** — Less context to process means quicker replies
- **Better focus** — The AI works with relevant skills, not everything at once

### In Practice

You don't need to do anything special. When you start a chat with skills enabled, the AI automatically:

1. Reviews available skills from the catalog
2. Selects appropriate skills based on your first message
3. Uses those skills throughout the conversation
4. Can add more skills later if the conversation shifts

---

## Persona Integration

Skills work seamlessly with Personas. Each persona can have its own skill configuration:

1. Open **Personas** in the Management window
2. Edit a persona
3. Enable or disable specific skills for that persona

**Example configurations:**

| Persona | Enabled Skills |
|---------|---------------|
| Code Assistant | Debug Assistant |
| Research Helper | Research Analyst, Content Summarizer |
| Creative Writer | Creative Brainstormer |
| Study Buddy | Study Tutor, Content Summarizer |

When you switch personas, the skill configuration switches too.

---

## Troubleshooting

### Skills not appearing in chat

- Verify the skill is enabled (toggle is on)
- Check if the active persona has the skill enabled
- Start a new chat session

### GitHub import fails

- Ensure the repository is public or you have access
- Verify the repo contains `.claude-plugin/marketplace.json`
- Check your network connection

### Skill instructions not being followed

- Review the skill's instructions for clarity
- Ensure the skill is selected (check the AI's first response)
- Try being more explicit in your request

### Import format errors

- For `.md` files: Ensure valid YAML frontmatter between `---` markers
- For `.zip` files: Ensure `SKILL.md` is at the root or in a named folder
- For `.json` files: Validate JSON syntax

---

## Related Documentation

- [Personas](../README.md#personas) — Custom AI assistants
- [Tools & Plugins](PLUGIN_AUTHORING.md) — Extend with custom tools
- [Agent Skills Specification](https://agentskills.io/) — Open format documentation
