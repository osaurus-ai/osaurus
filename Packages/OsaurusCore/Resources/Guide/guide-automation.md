---
title: Computer Use, Browser, and Sandbox
summary: Desktop control, an isolated in-app browser agent, and a Linux VM for safe code execution.
order: 160
---

# Computer Use, Browser, and Sandbox

Three ways agents can act beyond chat — each isolated, gated, and off by default where it matters.

## Computer Use (experimental)

- An agent drives real macOS apps through accessibility APIs. Custom agents only (never the default agent); off by default.
- Enable per agent: Agents → Configure → Subagents → Computer Use. Global policy in Settings → Computer Use: autonomy preset (default balanced), per-app overrides, app allowlist.
- Needs Accessibility permission (and Screen Recording for visual grounding). Dangerous apps — Terminal, System Settings, Keychain, password managers — always require per-action confirmation.
- Live steps stream into chat; consequential actions show a confirm overlay; Stop cancels at any point. Limits: ~24 steps / ~5 minutes per goal.
- Cloud vision is off by default; if enabled, screenshots are scrubbed (text masked) before any cloud model sees them.

## Browser Use

- A persistent, isolated in-app browser per agent (WebKit) — sign-ins and cookies persist across chats but are never shared with other agents or Safari.
- Custom agents only; enable in the agent's Subagents tab. Sessions are managed in Settings → Browser (open / close / reset; idle-close after 15 minutes).
- The agent never types credentials: a sign-in opens a visible window for you, then the run resumes. Only http/https; no downloads or file uploads.
- Edits and consequential actions confirm first; ~15 minute budget per goal; Stop always works.

## Sandbox

- An isolated Linux VM (Apple Containerization) for shell and code work — keeps execution off your Mac. Needs macOS 26+ on Apple Silicon; older macOS falls back to Seatbelt process isolation (weaker).
- Management (⌘⇧M) → Sandbox → Provision (~1 minute). Resources: CPUs (default 2), memory (default 2 GB), network mode (outbound / proxy with per-agent allowed domains / none).
- Toggle the sandbox on the chat input bar; write/exec tools additionally require the agent's autonomous-exec setting.
- Live tool cards stream output with Terminate/Copy. Secrets injected into the sandbox come from the Keychain via a secure overlay — values never enter chat. Workspace: `~/.osaurus/container/workspace/`.
