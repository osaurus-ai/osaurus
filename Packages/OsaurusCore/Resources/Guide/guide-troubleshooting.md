---
title: Troubleshooting and Support
summary: Common fixes, diagnostics, and where to get help.
order: 180
---

# Troubleshooting and Support

## Quick checks

- Model not responding or slow: check the model is downloaded (Local Models tab) and fits in RAM; a smaller or more-quantized model often fixes it. Server → health indicator shows whether the server is running.
- Tools not being used: make sure the agent has Tools on and the tools assigned (Abilities → Tools; in **Auto** mode, **Auto-discover relevant tools** under **Tool Settings** loads more of them on demand), and use a model with good tool calling (curated catalog models are validated for this).
- Provider shows Error: open the provider card for the exact message; re-check the API key (Providers tab), then use the connectivity center's reconnect.
- New skill/plugin/MCP tools not appearing mid-chat: start a new chat so the session's capability manifest refreshes.
- Port already in use: change the server port (Server tab or ask the assistant); ports below 1024 need elevated permissions — pick a higher one.
- Permission prompts (Microphone, Accessibility, Screen Recording, Full Disk Access): grant in macOS System Settings → Privacy & Security, then retry.
- Too many tool approval cards for one agent: on that agent's Tools tab open **Tool Settings** and set **Tool Approvals** to **Never Ask**, or use **Don't ask again** → **Always Allow for *Agent*…** on a card for just that tool. Cards that keep appearing anyway are the ones that always ask: tools set to Deny under Tools & MCP → All Tools, sends and deletes, MCP tools their server marks as destructive (choose **Always Allow…** on that tool's card), configuration changes, delegation, image and video costs, Computer or Browser Use, a teammate's call on a shared agent, and workflow steps (an agent's settings don't apply inside a workflow run).
- A tool ran without asking: its card says **Ran without asking**; hover it to see why (the agent's **Never Ask**, the agent's own **Auto** policy for that tool, or **Auto-Allow All Tool Calls**). The composer's **Approvals Off** chip has **Turn Back On** (**Ask for This Agent** when the global switch is the cause).
- Broken data store: Settings… (⌘,) → Privacy & Security → Data & Storage → **Stores Needing Attention** → **Retry** or **Reset…** (Reset quarantines the file, never deletes it).

## Diagnostics

- Insights (main window rail): the persisted activity log — every model request (local or cloud), web search, URL fetch, MCP call, channel delivery, Router call, inbound API request and plugin call, with Local/Cloud badges, filters, Verify and Export. Open a row's Overview tab for the plain-language summary and any error message. Retention: Privacy & Security → Activity Log.
- Memory → Diagnostics for the memory store; Developer Tools → Sandbox → Troubleshooting → Run Diagnostics for the sandbox VM.
- CLI: `osaurus status`.

## Getting help

- Ask this assistant — it can read the guide and inspect your configuration.
- Tell the Osaurus team: click the question mark icon above the usage icon in the main window rail to open Help, then use **Report a Problem**. Pick what it is about (Something Isn't Working, Osaurus Cloud, Agent Problem, Workflow Problem, iPhone App, Store, Model Trouble), choose the agent, workflow, model or listing from the menus, describe it, and attach up to 3 screenshots (**Add Image**, or drop or paste them into the description). Under **Review and Send** you see exactly what is sent (**What's Included** → **Show Details**) and tick the Terms and Privacy box. Replies arrive in Help under **Your Reports**, with a dot on the icon until you read it; **All Reports** lists every report, open and resolved. Open a report to reply (with images too) or click **Mark as Resolved** when it is fixed; writing again reopens it. Needs an Osaurus ID. This is not Devices → Support Report (saves sync logs to a file) or Send Crash Reports (Privacy & Security).
- Help also links to the documentation, the Osaurus Discord and GitHub issues under **Other Ways to Get Help**.
- README and docs: https://docs.osaurus.ai
- Search GitHub issues (open and closed) for similar problems; file bugs with the "Bug report" template (steps, expected/actual, environment).
- Feature ideas: the "Feature request" template. Questions: GitHub Discussions.
- Security issues: never file publicly — follow SECURITY.md for private reporting.
