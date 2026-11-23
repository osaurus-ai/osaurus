---
title: Importing from Chat
summary: Paste a link, snippet, command, or agent file in chat to install skills, MCP servers, agents, and commands after a review card.
order: 62
---

# Importing from Chat

Paste what you found online into chat and ask Osaurus to set it up, for example "Read https://example.com/SKILL.md and set it up". Nothing installs until you approve it on a review card.

## What you can paste

- A link to a `SKILL.md` page, or any page with setup instructions for an agent tool.
- A public GitHub link: a repository, a folder (`/tree/...`), or a file (`/blob/...`). Repositories with skill folders (`SKILL.md` plus `scripts/`, `references/`, `assets/`), a Claude plugin marketplace, MCP configs, or agent and command files are read directly.
- MCP server config JSON (`mcpServers` or `servers`), Cursor and VS Code MCP install links, and MCP install commands such as `claude mcp add` or `codex mcp add`.
- Agent files from Claude Code, Copilot, Gemini, OpenCode, or Cursor, an `AGENTS.md`, or plain instructions.

## How it works

1. The assistant hands the request to the Configurator, which downloads the link (https only, public GitHub only). A server URL written in pasted config JSON or an `mcp add` command is installed as written and isn't opened beforehand.
2. Standard formats (skill folders, plugin marketplaces, MCP configs, agent frontmatter) are read by Osaurus directly. Anything else is read by a separate model call that can only report what it found and can't change anything.
3. Osaurus checks every value against the source: a URL, command, or setting that doesn't appear in what you shared is dropped. Agent abilities come from a fixed list, and a model is kept only if it's installed on this Mac.
4. If nothing could be read, the page is offered as a skill.

## The review card

- Each item has a checkbox. Unchecked items aren't installed.
- Instructions can install as a **Skill** or an **Agent**; pick one on the row.
- **Already installed** rows start unchecked. **Update** rows replace the earlier import. When a name is taken by something else, choose **Replace** or **Keep both** (keep both adds a number to the name).
- Risks and warnings show on each row. API keys and tokens are never copied from a page: the row says **Needs setup**, and you add the secret in Settings afterwards.
- **Manual steps** from the page are listed for you to do yourself. Osaurus never runs them.
- Install is all or nothing: if one item fails, everything installed in that step is removed again, and the result says what happened to each item.

## Sandbox

- MCP servers that run a local command (stdio) run inside the sandbox and need the Linux VM sandbox backend. On other backends the row is blocked with the reason.
- `npx` and `uvx` servers download packages on first start; the card warns when the agent's sandbox network is off.
- Servers started with `docker run` run on your Mac, not in the sandbox. They arrive unchecked with a risk line; check them only if you trust them.
- After install, new MCP servers are connected once as the agent that will use them. A sandbox that is still starting can take up to two minutes.
- Skill scripts and reference files are copied into a sandboxed agent's home at `/workspace/agents/<agent>/skills/<skill>`, and the skill's instructions give that path.

## In a New Agent chat

Paste the same things into a New Agent chat. An agent file fills the draft (name, description, instructions, model, abilities), and fields you edited on the card stay as you set them. Skills, MCP servers, and other items are listed under **Installs When You Create**, where you can remove any of them. They install when you click **Create Agent**: skills become available to the new agent and MCP servers are attached to it. If anything fails to install, the agent isn't created.

## Plugins

A Claude plugin marketplace repository installs its plugins' skills, commands, and MCP servers. Plugin `agents/*.md` files with a schedule become schedules; the others become custom agents. Updating the plugin replaces those agents, and uninstalling it removes them.

## What can't be imported

- SSH git remotes (share the https link instead), Azure DevOps repositories, and private or missing GitHub repositories.
- A2A agent cards: Osaurus doesn't connect to remote A2A agents.
- Osaurus template links that don't come from the template store; store links open the template review instead.
- Plain http links and downloads that are too large.

Osaurus records where each import came from in `~/.osaurus/chat-imports.json`, so importing the same source again shows what's already installed or has an update.
