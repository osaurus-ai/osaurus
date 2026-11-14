---
title: Computer Use, Browser, and Sandbox
summary: Desktop control, an isolated in-app browser agent, and a Linux VM for safe code execution.
order: 160
---

# Computer Use, Browser, and Sandbox

This topic is about desktop and browser control. For schedules, folder changes, webhooks, feeds, failed runs and channel messages that start work on their own, read the `automations` topic.

Three ways agents can act beyond chat — each isolated, gated, and off by default where it matters. All three (like AppleScript and image generation) are custom-agent abilities: the built-in Orchestrator has none of them itself and reaches them only by delegating to an agent that does (Settings → Agents → Delegation → Allowed subagents).

## Computer Use (experimental)

- An agent drives real macOS apps through accessibility APIs. Custom agents only (never the default agent); off by default.
- Enable per agent: Agents → the agent → Abilities → Subagents → Computer Use. Global policy in Settings → Computer & Browser Use → Autonomy: autonomy preset (default balanced), per-app overrides, app allowlist.
- Needs Accessibility permission (and Screen Recording for visual grounding). Dangerous apps — Terminal, System Settings, Keychain, password managers — always require per-action confirmation.
- Live steps stream into chat; consequential actions show a confirm overlay; Stop cancels at any point. Limits: ~24 steps / ~5 minutes per goal.
- Cloud vision is off by default; if enabled, screenshots are scrubbed (text masked) before any cloud model sees them.

## Browser Use

- A persistent, isolated in-app browser per agent (WebKit) — sign-ins and cookies persist across chats but are never shared with other agents or Safari.
- Custom agents only; enable in the agent's Abilities → Subagents. Sessions are managed in Settings → Computer & Browser Use → Browser Use (open / close / reset; idle-close after 15 minutes).
- The agent never types credentials: a sign-in opens a visible window for you, then the run resumes. Only http/https; no downloads or file uploads.
- Edits and consequential actions confirm first; ~15 minute budget per goal; Stop always works.

## Sandbox

- An isolated Linux VM (Apple Containerization) for shell and code work — keeps execution off your Mac. Needs macOS 26+ on Apple Silicon; older macOS falls back to Seatbelt process isolation (weaker).
- Settings… (⌘,) → Developer Tools → Sandbox → **Set Up Sandbox** (~1 minute). Resources: CPUs (default 2), memory (default 2 GB). **Network** is read-only and shows **Open**, **Filtered per agent**, **Off**, or **Per agent**; each agent's own **Sandbox Network** and **Allowed Domains** decide it.
- There is no sandbox toggle on the chat input bar: the sandbox is per agent (Agents → the agent → Sandbox → Execution → **Autonomous Execution**).
- Live tool cards stream output with Terminate/Copy. Keys from General → Vault marked **Agents Can Use This When Running Code** (and the agent's own keys) are injected into the sandbox as environment variables via a secure overlay — values never enter chat. Workspace: `~/.osaurus/container/workspace/`.
- Workflows that declare dependencies (pip, npm, or apk packages) get a sandbox environment of their own under `~/.osaurus/container/workspace/agents/wf-<id>/`; their shell steps run there instead of on your Mac, and the setup wizard's **Dependencies** step installs the packages. **Reset Sandbox** clears apk packages but keeps every agent's home folder (with its pip and npm packages) and the shared folder; **Remove Sandbox** also deletes the downloaded runtime. After either, each such workflow asks to install its dependencies again. See Workflows → Dependencies.
