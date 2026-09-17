---
title: Chat and the Agent Loop
summary: How chat works — plans, tool calls, clarifying questions, artifacts, working folders.
order: 50
---

# Chat and the Agent Loop

Every **custom-agent** chat is an agent loop: the model thinks, calls tools, tracks progress, and finishes with a summary. There is no separate "agent mode" — the loop is always on for custom agents. The built-in Orchestrator is the exception (see The Orchestrator topic): it configures Osaurus and delegates work; it can read a working folder but never gets write, shell, or sandbox tools.

## What you'll see in chat

- Todo checklist: for multi-step work the agent posts a live checklist that updates as items complete.
- Tool cards: each tool call renders as a card with its arguments and result; some tools (shell, config changes) show a one-tap approval before running.
- Completed banner: the agent ends a run with a real summary of what it did.
- Clarifying questions: when the agent needs input, a bottom overlay appears (optionally with answer chips); answering resumes the run.
- Artifacts: files, charts, and reports the agent shares appear as cards; artifacts are stored under `~/.osaurus/artifacts/<sessionId>/`.

## Working folder

On a **custom agent**, the folder selector on the chat input bar grants the current chat access to one folder: file read/write/edit/search, shell, and undo/history tools (plus git tools if it's a repo). It's per-chat, persists across relaunch, and new chats start folder-less. On the **Orchestrator** the same chip sets its working folder: the Orchestrator can read it (`file_read`, `file_search`), and agents it delegates to that have no folder of their own work inside it — with write access. Hands-on editing still happens through a delegated or directly-used custom agent.

### File formats the folder tools handle

- `file_read` opens any file in the folder: source and text as-is; PDF, Word (`.docx`, `.doc`, `.rtf`), PowerPoint (`.pptx`) and Excel (`.xlsx`, sheet preview) extracted to text; images shown to vision models directly and read via OCR for text-only models (image-only PDFs are OCR'd too). It also lists directories. Legacy/iWork/ODF formats (`.xls`, `.pages`, `.numbers`, `.key`, `.odt`…) are named as unsupported with the nearest working alternative.
- `file_write` creates text and code, and generates documents by extension: `.xlsx` from CSV/TSV or JSON rows, `.docx` and `.pdf` from Markdown or HTML. `.pptx` is not built in (write `.docx`/`.pdf`/Markdown or use a presentation plugin). Overwrites of existing documents are undoable with `file_undo`.
- `file_edit` and the redaction tools work on text only; for a document the agent reads it, edits the text, and regenerates it with `file_write`.
- `file_search` matches inside PDF/Word/PowerPoint/Excel content (results carry a page/slide/sheet locator), and `file_copy` duplicates any file, including binaries, undoably.
- `share_artifact` on a `.docx`/`.xlsx`/`.pptx` shows a typed document card; `db_import`/`db_export` accept `.xlsx` alongside CSV/JSON.

The same formats work on `/workspace/...` paths in the sandbox.

## Sandbox toggle

On macOS 26+, the sandbox toggle on the input bar runs shell/code work inside an isolated Linux VM instead of your Mac. Combined with a working folder, the host folder is read-only and execution happens in the VM.

## Useful chat extras

- `/screenshot` captures your main display into the chat's artifacts (needs Screen Recording permission).
- `/skill-name` force-loads a skill for one message.
- Voice: the mic button dictates locally (see the Voice topic); the speaker button reads replies aloud when TTS is enabled.
- Clipboard monitoring (Settings → Chat) offers recently copied text as context.
- Context window cap (how much history fits) is Management → Server → Settings → Cache → Context Window Cap, not the Chat tab. The composer Context Budget popover is read-only.

## Tips

- Be specific; let the todo list show progress on long tasks.
- On a custom agent, use a working folder for repo work, the sandbox for scripts and package installs, and neither for plain Q&A. On the Orchestrator, set a working folder when you want delegated work to land somewhere you can see; stay on it for setup, questions, and delegation.
- Tool approvals are per-tool; you can grant "always allow" per agent in Permissions.
