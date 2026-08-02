---
title: MCP (Model Context Protocol)
summary: Connect remote MCP tool servers (Linear, Notion, GitHub, …) and expose Osaurus as an MCP server.
order: 80
---

# MCP (Model Context Protocol)

MCP connects Osaurus to external tool servers — issue trackers, docs, code hosts — so agents can call their tools like local ones. Osaurus is also an MCP server itself, so other AI apps can use Osaurus tools.

## Connecting an MCP provider

- Management (⌘⇧M) → Providers → Add Provider → pick from the MCP catalog or Custom Server.
- Catalog includes Linear, Notion, GitHub, Atlassian, Vercel, Supabase, Stripe, Zapier, Exa Search, DeepWiki, Hugging Face, Sentry, and more.
- Auth: Sign In (OAuth), API key, or none — tokens are stored in the Keychain. Non-secret config lives in `~/.osaurus/providers/mcp.json`.
- Custom Server options: Name, URL, auth (None / Bearer / OAuth), stdio command, Auto-connect, Streaming, Discovery Timeout (20s), Tool Call Timeout (45s), and a Test button.
- Or ask the default Osaurus assistant to add an MCP server for you (OAuth sign-in and tokens still happen through secure native UI).

## Using MCP tools

- Tools are namespaced `provider_toolname` (e.g. `linear_search_issues`); exact names appear under Tools → Available.
- In Auto tool mode, agents discover and load remote tools on demand; in Manual mode you pick them explicitly. Per-agent allowlists live in the agent editor's Capabilities section.
- The default permission for remote MCP tools is Ask (one-tap approval per call until you grant always-allow).
- Start a new chat after adding providers so the session's capability manifest refreshes.

## Osaurus as an MCP server

- External MCP clients can launch Osaurus with `command: "osaurus"`, `args: ["mcp"]`.
- Over HTTP: `GET /mcp/tools` and `POST /mcp/call` on `http://127.0.0.1:1337`. If server network exposure is on, authenticate with an access key from Settings → Server.
- Debug connections and tool calls in the Insights tab.
