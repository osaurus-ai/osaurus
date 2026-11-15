---
title: Troubleshooting and Support
summary: Common fixes, diagnostics, and where to get help.
order: 180
---

# Troubleshooting and Support

## Quick checks

- Model not responding or slow: check the model is downloaded (Local Models tab) and fits in RAM; a smaller or more-quantized model often fixes it. Server → health indicator shows whether the server is running.
- Tools not being used: make sure the agent has Tools on and the tools assigned (Abilities → Tools; in **Auto** mode, **Auto-discover relevant tools** loads more of them on demand), and use a model with good tool calling (curated catalog models are validated for this).
- Provider shows Error: open the provider card for the exact message; re-check the API key (Providers tab), then use the connectivity center's reconnect.
- New skill/plugin/MCP tools not appearing mid-chat: start a new chat so the session's capability manifest refreshes.
- Port already in use: change the server port (Server tab or ask the assistant); ports below 1024 need elevated permissions — pick a higher one.
- Permission prompts (Microphone, Accessibility, Screen Recording, Full Disk Access): grant in macOS System Settings → Privacy & Security, then retry.
- Broken data store: Settings… (⌘,) → Privacy & Security → Data & Storage → **Stores Needing Attention** → **Retry** or **Reset…** (Reset quarantines the file, never deletes it).

## Diagnostics

- Insights (main window rail): the persisted activity log — every model request (local or cloud), web search, URL fetch, MCP call, channel delivery, Router call, inbound API request and plugin call, with Local/Cloud badges, filters, Verify and Export. Open a row's Overview tab for the plain-language summary and any error message. Retention: Privacy & Security → Activity Log.
- Memory → Diagnostics for the memory store; Developer Tools → Sandbox → Troubleshooting → Run Diagnostics for the sandbox VM.
- CLI: `osaurus status`.

## Getting help

- Ask this assistant — it can read the guide and inspect your configuration.
- Tell the Osaurus team: click the question mark icon above the usage icon in the main window rail to open Help, then use **Report a Problem**. You see exactly what is sent (**What's Included** → **Show Details**), you tick the Terms and Privacy box, and the reply arrives in Help under **Your Reports**, with a dot on the icon until you read it. Needs an Osaurus ID. This is not Devices → Support Report (saves sync logs to a file) or Send Crash Reports (Privacy & Security).
- README and docs: https://docs.osaurus.ai
- Search GitHub issues (open and closed) for similar problems; file bugs with the "Bug report" template (steps, expected/actual, environment).
- Feature ideas: the "Feature request" template. Questions: GitHub Discussions.
- Security issues: never file publicly — follow SECURITY.md for private reporting.
