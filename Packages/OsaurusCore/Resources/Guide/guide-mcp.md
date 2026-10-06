---
title: MCP (Model Context Protocol)
summary: Connect remote MCP tool servers (Linear, Notion, GitHub, …) and expose Osaurus as an MCP server.
order: 80
---

# MCP (Model Context Protocol)

MCP connects Osaurus to external tool servers — issue trackers, docs, code hosts — so agents can call their tools like local ones. Osaurus is also an MCP server itself, so other AI apps can use Osaurus tools.

## Connecting an MCP provider

- Settings… (⌘,) → Tools & MCP → Services → **Add Service** → pick a service from the catalog or Custom Server. The **Directory** below the Services list shows the same catalog as a list; click **Add** on a row to start adding it. Both have category chips (Legal, Finance & Accounting, Investing & Market Data, Healthcare & Life Sciences, Documents & Signatures, Compliance & Security, Business Productivity, Sales & CRM, Developer), and search also matches category names. The Services header shows a one-line summary (connected · needs attention · tools) and a ⋯ menu with Show (filter), Reconnect All, Test Connections, and Copy Diagnostics.
- Note: use the Tools sidebar item (under Agents & Automation), not the top-level Providers item — that one is for inference endpoints, not MCP tool servers.
- Catalog includes legal (CourtListener, CoCounsel, Bloomberg Law, Harvey, iManage, NetDocuments, Juro), finance and accounting (QuickBooks, Xero, FreshBooks, Gusto, Brex, Ramp, Mercury, Stripe), investing (Morningstar, PitchBook, S&P Global, Moody's, FactSet), healthcare and research (Consensus, Scite, Elicit, Medidata, SNOMED CT), documents (Dropbox, Docusign, PandaDoc, Box), compliance (Vanta), productivity (Microsoft 365, Google Drive, Gmail, Slack, Notion, Atlassian, Dropbox Dash, Zapier), CRM (Salesforce, HubSpot, Attio), and developer tools (GitHub, Linear, Vercel, Sentry). Services marked **Requires subscription** only work with a paid account.
- Not in the catalog: Clio, Filevine, ADP and Bill.com have no hosted MCP server; Everlaw only issues sign-in to partner apps; NetSuite uses a per-account URL, so add it with Custom Server.
- Auth: Sign In (OAuth), API key, or none — tokens are stored in the Keychain. Most services sign in with one tap. Google, Slack, Asana, Zoom, Xero, Box, Docusign, HubSpot, Microsoft 365 and Harvey need an OAuth app (for Microsoft 365, an Entra app your admin registers; for Harvey, credentials from your Harvey admin): register the redirect URI `http://127.0.0.1:33267/callback` shown on the connect screen, then paste the Client ID and Client Secret.
- If a tool call is refused because you aren't signed in (some services list tools first and ask for sign-in only when one runs) or lack permissions, the service shows as needing sign-in; click Sign In, then ask again. Connection problems show a plain-language message with a Details disclosure for the raw error. Non-secret config lives in `~/.osaurus/providers/mcp.json`.
- Custom Server options: Name, URL, auth (None / Bearer / OAuth), stdio command, Auto-connect, Streaming, Discovery Timeout (20s), Tool Call Timeout (45s; 120s when added from a Legal, Investing, or Healthcare template), and a Test button. The tool call timeout counts time without progress: each progress update from the server restarts it, up to 10 minutes per call, and the latest progress message shows on the running tool card.
- In chat, the built-in assistant adds an MCP server itself by applying an `mcp_servers:` entry with `osaurus_config` (OAuth sign-in and tokens still happen through secure native UI; bearer tokens are declarable via `token_ref`).

## Using MCP tools

- Tools are namespaced `provider_toolname` (e.g. `linear_search_issues`); exact names appear under Tools & MCP → All Tools.
- In Auto tool mode, agents discover and load remote tools on demand; in Manual mode you pick them explicitly. Per-agent allowlists live in the agent editor's Capabilities section.
- The default permission comes from the server's tool hints. Tools declared read-only run without asking, unless the server says they reach the wider web (such as web search or page fetch). Tools that may change or delete data (including tools with no hints) ask on every call; Always Allow and Auto don't apply to them. Other tools ask until you choose Always Allow. You can change the policy per tool under Tools & MCP → All Tools.
- A service can ask you something mid-task. A form card ("needs more information") lets you Submit, Decline, or Cancel; never type passwords, API keys or card numbers into it. A browser card ("finish in your browser") shows the site and opens it only when you click Open; it closes when the service reports it's done, or when you click Done. Background and API runs automatically cancel these requests.
- Start a new chat after adding providers so the session's capability manifest refreshes.

## Osaurus as an MCP server

- External MCP clients can launch Osaurus with `command: "osaurus"`, `args: ["mcp"]`.
- Over HTTP: `GET /mcp/tools` and `POST /mcp/call` on `http://127.0.0.1:1337`. If server network exposure is on, authenticate with an access key from Settings → Server.
- Debug connections and tool calls in the Insights tab: each call is an **MCP tool** row with the server, tool, arguments, result preview and transport (stdio servers are Local; HTTP servers are Cloud).
