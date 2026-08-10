---
title: Chat and the Agent Loop
summary: How chat works — plans, tool calls, clarifying questions, artifacts, working folders.
order: 50
---

# Chat and the Agent Loop

Every Osaurus chat is an agent loop: the model thinks, calls tools, tracks progress, and finishes with a summary. There is no separate "agent mode" — the loop is always on.

## What you'll see in chat

- Todo checklist: for multi-step work the agent posts a live checklist that updates as items complete.
- Tool cards: each tool call renders as a card with its arguments and result; some tools (shell, config changes) show a one-tap approval before running.
- Completed banner: the agent ends a run with a real summary of what it did.
- Clarifying questions: when the agent needs input, a bottom overlay appears (optionally with answer chips); answering resumes the run.
- Artifacts: files, charts, and reports the agent shares appear as cards; artifacts are stored under `~/.osaurus/artifacts/<sessionId>/`.

## Working folder

The folder selector on the chat input bar grants the current chat access to one folder: file read/write/edit/search, shell, and undo/history tools (plus git tools if it's a repo). It's per-chat, persists across relaunch, and new chats start folder-less.

## Sandbox toggle

On macOS 26+, the sandbox toggle on the input bar runs shell/code work inside an isolated Linux VM instead of your Mac. Combined with a working folder, the host folder is read-only and execution happens in the VM.

## Useful chat extras

- `/screenshot` captures your main display into the chat's artifacts (needs Screen Recording permission).
- `/skill-name` force-loads a skill for one message.
- Voice: the mic button dictates locally (see the Voice topic); the speaker button reads replies aloud when TTS is enabled.
- Clipboard monitoring (Settings → Chat) offers recently copied text as context.

## Tips

- Be specific; let the todo list show progress on long tasks.
- Use a working folder for repo work, the sandbox for scripts and package installs, and neither for plain Q&A.
- Tool approvals are per-tool; you can grant "always allow" per agent in Permissions.
