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

## Sidebar and inspector

The chat window has a rail on each side, both toggled from the ends of the toolbar (sidebar button on the left, inspector button on the right) and both resizable by dragging their inner edge.

- The **sidebar** (left) is where you choose what to open: its lens bar switches between **Agents** (one row per agent — pick one to chat with it, or use the row's + for a fresh chat) and **Projects**. Under the lens bar, a header row counts what the lens holds (“8 agents”, “3 projects”) with the lens's **+** (New Agent, New Project) on the right, and a search field narrows the list by name — for agents it also filters your workspaces' shared agents and network peers. **Settings** sits at the foot of the rail.
- The **inspector** (right) is about what is on screen. For a chat, its lens bar switches between **File Changes** (this chat's edits, see below) and **History** — the past conversations of this chat's agent, with search, a **Filter** for source, project, workspace and archived chats, and **New Chat** and **Import Conversations** in its header. While a chat has no file changes yet, opening the inspector shows History; File Changes takes over once the first change lands (or when you pick it in the lens bar). Selecting a past chat opens it in the current tab and the rail stays open; the row's actions offer a new tab or window. Switch to a tab with a different agent and History follows.
- Open a **project** from the sidebar and the content area shows the project as a folder of chats — the same list and search as History, with **New Chat** and **Add Chats** in its header row — while the inspector shows **Project Settings**: instructions, knowledge collections, working folder, shared memory and the default agent. The same toolbar button shows and hides it, and it keeps the inspector's width.

## Working folder

On a **custom agent**, the folder selector on the chat input bar grants the current chat access to one folder: file read/write/edit/search, shell, and undo/history tools (plus git tools if it's a repo). It's per-chat, persists across relaunch, and new chats start folder-less. When a chat has no folder and the agent needs one, the agent can ask for it directly: its `prompt_working_folder` tool opens the same folder picker as the chip, with the agent's reason shown in the dialog. Picking a folder attaches it to the chat (and remembers it on the agent, like the chip) and the agent continues on its own with the file tools; cancelling leaves the chat folder-less and ends that turn with a short notice, so nothing is written and the picker is not re-opened until you ask again. On the **Orchestrator** the same chip sets its working folder: the Orchestrator can read it (`file_read`, `file_search`), and agents it delegates to that have no folder of their own work inside it — with write access. Hands-on editing still happens through a delegated or directly-used custom agent.

### File formats the folder tools handle

- `file_read` opens any file in the folder: source and text as-is; PDF, Word (`.docx`, `.doc`, `.rtf`), PowerPoint (`.pptx`) and Excel (`.xlsx`, sheet preview) extracted to text; images shown to vision models directly and read via OCR for text-only models (image-only PDFs are OCR'd too). It also lists directories. Legacy/iWork/ODF formats (`.xls`, `.pages`, `.numbers`, `.key`, `.odt`…) are named as unsupported with the nearest working alternative.
- `file_write` creates text and code, and generates documents by extension: `.xlsx` from CSV/TSV or JSON rows, `.docx` and `.pdf` from Markdown or HTML, `.pptx` from Markdown (each `#`/`##` heading starts a slide). Every file change is recorded per chat and undoable with `file_undo` or from the chat's File Changes panel (see below).
- `file_edit` edits `.docx`, `.xlsx`, `.pptx` and `.pdf` in place with `operations`, keeping formatting, styles and media: Word paragraphs, text and table cells; spreadsheet cells, formulas, rows and sheets (references are adjusted when rows or sheets move); slide text and slide order; PDF pages, rotation, merging, form fields, text boxes, notes and highlights. `file_read` with `mode: "structure"` lists the numbered paragraphs, cells, slides or pages to address. Each edit is checked by re-opening the result before the original is replaced. PDF body text can't be rewritten in place, and legacy formats (`.doc`, `.xls`, `.odt`…) are still read, edited as text, and regenerated. The redaction tools work on text only.
- `file_search` matches inside PDF/Word/PowerPoint/Excel content (results carry a page/slide/sheet locator), and `file_copy` duplicates any file, including binaries, undoably.
- `share_artifact` on a `.docx`/`.xlsx`/`.pptx` shows a typed document card; `db_import`/`db_export` accept `.xlsx` alongside CSV/JSON.

The same formats work on `/workspace/...` paths in the sandbox.

### Reviewing and undoing file changes

Every file a chat creates, edits, or deletes is snapshotted before and after the change, so nothing the agent does to your files is final. Three ways in:

- The **inspector** button at the right of the chat toolbar (the mirror of the sidebar button on the left) opens the rail beside the chat; its **File Changes** lens is this chat's edits. While the rail is closed, the button's badge counts the files this chat still has changed. Drag the rail's inner edge to resize it, like the sidebar.
- The **badge on a chat** in the inspector's History shows how many files that chat still has changed; clicking it opens the same panel.
- Under an answer that changed files, **“N files changed · View changes”** opens the panel on that turn, and every file-edit card in the transcript has its own **Revert** / **View change**.

Inside the panel, the header row summarizes “N files changed · M changes” and offers two views as chips: **Timeline** lists every change in order (one row per edit or command, grouped under the request that caused it) — expand a row to see which files it touched and a before/after difference for each. **Files** shows the net result per file: what it was before this chat versus what it is now.

- **Revert** on a Timeline row undoes that one change. **Revert File** on a Files row returns one file to how it was before the chat. **Roll Back to Before This** (inside an expanded row) undoes that change and everything after it. **Revert All** in the pane's header row returns every file the chat touched.
- Anything that touches more than one file asks first and lists what will happen to each file (“back to before this change”, “will be deleted”, “will be recreated”).
- **Edited since** marks a file you (or another app) changed after the chat did. Reverts skip those unless you choose **Overwrite Edited Files**; the overwritten version is kept, so even that is undoable.
- Every revert is itself recorded: use **Undo** in the confirmation toast, or the **Undo** button on the revert's own Timeline row, to put things back.
- Files too large to keep in history are marked “can't be restored”; word documents, spreadsheets, slides and PDFs show changed paragraphs, cells, slides or pages instead of raw file contents.
- While the chat is still running a command, the panel says so and reverts wait until it finishes, so a revert never races the tool that is writing.

Settings → General → Advanced → Data & Storage → **File History** controls how long snapshots are kept; deleting a chat always deletes its history. When retention has trimmed a file's oldest changes, its **Revert File** preview says “back to the oldest change still in history” instead of “back to before this chat”.

## Sandbox toggle

On macOS 26+, the sandbox toggle on the input bar runs shell/code work inside an isolated Linux VM instead of your Mac. Combined with a working folder, the host folder is read-only and execution happens in the VM.

## Useful chat extras

- `/screenshot` captures your main display into the chat's artifacts (needs Screen Recording permission).
- `/skill-name` force-loads a skill for one message.
- Voice: the mic button dictates locally (see the Voice topic); the speaker button reads replies aloud when TTS is enabled.
- Clipboard monitoring (Settings → Conversation → Behavior) offers recently copied text as context.
- Context window cap (how much history fits) is Settings… (⌘,) → Server → Settings → Cache → Context Window Cap, not the Conversation tab (Conversation → Advanced has a link that jumps there). The composer Context Budget popover is read-only.

## Tips

- Be specific; let the todo list show progress on long tasks.
- On a custom agent, use a working folder for repo work, the sandbox for scripts and package installs, and neither for plain Q&A. On the Orchestrator, set a working folder when you want delegated work to land somewhere you can see; stay on it for setup, questions, and delegation.
- Tool approvals are per-tool; you can grant "always allow" per agent in Permissions.
