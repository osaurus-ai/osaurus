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
- The approval sheet is titled with what the tool will do in plain words, such as **Run a Python script** or **Install Python packages**. A shell command is shown in full; for other tools, **Show details** reveals the exact arguments. Below it is a short list of what the app knows about the call. First, anything to check before you approve: deleting files, admin rights, downloads from the internet, **Runs on your Mac**, a background process, or a command it couldn't fully read. Then the protections that really apply to this call: **Inside the sandbox only** (it sees only the sandbox's own folders), the sandbox's CPU and memory limit, no internet or approved sites only (from the agent's Sandbox network settings), and the idle timeout when the command sets one. When a workflow step asks, a sandbox call adds **Can't see the folders you chose**, and a file step lists the folders the run may use instead of **Runs on your Mac**, such as **Access to dinos (read), dinos/png (write)**, or **Only this run's workspace** when it uses nothing else, plus **Asks before replacing a file** and **No file deletion** when it saves. A workflow file step also shows each path in full (hover for the whole path), both the file it touches and every folder the run may use. A tag beside each one says where it sits: **Osaurus · run workspace** (the run's own folder, which Osaurus creates and keeps), **Osaurus data** (elsewhere in the Osaurus data folder), **Agent's working folder**, **Chosen for this run** (picked when it started, bound in setup, or allowed while it ran), or **Outside this run's folders** (the step can't use it unless you allow that folder). The **⋯** menu beside a path has **Copy Path** and **Show in Finder**; a file that doesn't exist yet opens the nearest folder that does, and nothing is created before you approve. Last, a line such as **No file deletion, admin rights, or downloads** for the checks that came back clean. **Run once** allows this call and **Deny** refuses it. **Don't ask again** at the bottom left offers **For the Rest of This Reply** (the same tool runs without asking until the agent finishes this reply; your next message asks again) and **Always Allow…**. Return runs once and Esc denies. The agent waits until you decide: the sheet never times out on its own.
- Completed banner: the agent ends a run with a real summary of what it did.
- Clarifying questions: when the agent needs input, a bottom overlay appears (optionally with answer chips); answering resumes the run.
- Artifacts: files, charts, and reports the agent shares appear as cards; artifacts are stored under `~/.osaurus/artifacts/<sessionId>/`.

## Window layout

The chat window is three columns, left to right: the **navigation rail** (Chat and Workflows at the top, Usage and Settings at the bottom), the **sidebar**, and the **conversation**, with the **context panel** as a card in the top-right corner: wide windows set room aside for it so the conversation shifts over, and narrower windows float it over the conversation. The toolbar's sidebar button (left) shows and hides the sidebar, which you can resize by dragging its inner edge; the context button (right, a list icon) shows and hides the context panel. The context panel and its button only appear once the chat has changed a file.

- The **sidebar** is where you choose what to open: **Osaurus** (the Orchestrator) at the top with its recent chats, then **Pinned** chats from any agent (pin a chat from its … menu or right-click; it moves out of its agent's list until you unpin it), then **Agents** (click anywhere on a group's header row to fold it; the Agents **+** creates an agent, and its **…** menu (hover the header) has **Import Conversations** (into the agent on screen) and **Show Archived**, which lists archived chats under their agents with an archive mark), one row per agent with that agent's recent chats under it (click an agent to open or fold its chats, or to start one when it has none yet, **Show more** for older ones, or use the row's + for a fresh chat), then agents on your other Macs, one group per workspace, and agents shared with you. A workspace group folds like a project; its hover gear opens the workspace in Settings, its **+** starts a chat with a teammate's agent (or **Share an Agent…**), and right-clicking it opens Members, Shared Agents or Workflows. Click a teammate's agent to open or fold your chats with it in that workspace. Your own shared agent's row in a workspace lists the chats teammates started with it there; your own chats with it stay under Agents. Workspace chats can be pinned but not moved into a project. The search field at the top finds agents and workspaces by name and chats by title; while you search, each agent opens on its matching chats.
- The **conversation** keeps the chat's title centered at the top, and the thread, the notices above the input, the input box and question cards all share one readable column, centered in wide windows. **Find** (⌘F) docks a search bar at the top of that column and moves the conversation down rather than covering it.
- The **context panel** is a card holding this chat's **File Changes** (see below). It opens in the top-right corner when the chat makes its first file change, grows only as tall as its list (scrolling past that, and always clear of the input box), and stays hidden in chats that have none; closing it from the toolbar keeps it closed for later chats in that window until you open it again. Past chats are in the sidebar, and a workflow's past runs are on its page under Workflows. The Architect's chats have no context panel: the draft sits beside the chat under Workflows.

The layout follows the window's width:

- **Wide** and **medium** windows dock the sidebar beside the conversation.
- **Narrow** windows (down to 560 points wide) give the conversation the full width: the sidebar slides in over it as a drawer. Click outside, press Escape, or pick a chat to close it. Narrowing the window never changes whether the sidebar is docked when it widens again. The context panel closes when the window becomes narrow (so it never covers a narrow conversation on its own) and comes back when it widens; the context button opens it at any width.

## Working folder

On a **custom agent**, the folder selector on the chat input bar grants the current chat access to one folder: file read/write/edit/search, shell, and undo/history tools (plus git tools if it's a repo). It's per-chat, persists across relaunch, and new chats start folder-less. When a chat has no folder and the agent needs one (and its sandbox is off), the agent can ask for it directly: its `prompt_working_folder` tool opens the same folder picker as the chip, with the agent's reason shown in the dialog. Picking a folder attaches it to the chat (and remembers it on the agent, like the chip) and the agent continues on its own with the file tools; cancelling leaves the chat folder-less and ends that turn with a short notice, so nothing is written and the picker is not re-opened until you ask again. On the **Orchestrator** the same chip sets its working folder: the Orchestrator can read it (`file_read`, `file_search`), and agents it delegates to that have no folder of their own work inside it — with write access. Hands-on editing still happens through a delegated or directly-used custom agent.

### File formats the folder tools handle

- `file_read` opens any file in the folder: source and text as-is; PDF, Word (`.docx`, `.doc`, `.rtf`), PowerPoint (`.pptx`) and Excel (`.xlsx`, sheet preview) extracted to text; images shown to vision models directly and read via OCR for text-only models (image-only PDFs are OCR'd too). PDF text carries `--- Page N of M ---` markers, pages whose drawing order scrambles the layout (flattened forms that draw every label before every value) are rebuilt from glyph geometry so a label and its value share a line, and `pages: "3-5"` reads a page range. It also lists directories. Legacy/iWork/ODF formats (`.xls`, `.pages`, `.numbers`, `.key`, `.odt`…) are named as unsupported with the nearest working alternative.
- `file_write` creates text and code, and generates documents by extension: `.xlsx` from CSV/TSV or JSON rows, `.docx` and `.pdf` from Markdown or HTML, `.pptx` from Markdown (each `#`/`##` heading starts a slide). Every file change is recorded per chat and undoable with `file_undo` or from the chat's File Changes panel (see below).
- `file_edit` edits `.docx`, `.xlsx`, `.pptx` and `.pdf` in place with `operations`, keeping formatting, styles and media: Word paragraphs, text and table cells; spreadsheet cells, formulas, rows and sheets (references are adjusted when rows or sheets move); slide text and slide order; PDF pages, rotation, merging, form fields, text boxes, notes and highlights. `file_read` with `mode: "structure"` lists the numbered paragraphs, cells, slides or pages to address. Each edit is checked by re-opening the result before the original is replaced. PDF body text can't be rewritten in place, and legacy formats (`.doc`, `.xls`, `.odt`…) are still read, edited as text, and regenerated. The redaction tools work on text only.
- `file_search` matches inside PDF/Word/PowerPoint/Excel content (results carry a page/slide/sheet locator), and `file_copy` duplicates any file, including binaries, undoably.
- `share_artifact` on a `.docx`/`.xlsx`/`.pptx` shows a typed document card; `db_import`/`db_export` accept `.xlsx` alongside CSV/JSON.

The same formats work on `/workspace/...` paths in the sandbox.

### Reviewing and undoing file changes

Every file a chat creates, edits, or deletes is snapshotted before and after the change, so nothing the agent does to your files is final. Two ways in:

- The **context** button at the right of the chat toolbar (the mirror of the sidebar button on the left) shows and hides the context panel, which holds this chat's **File Changes**; the button appears once the chat has changed a file. While the panel is closed, the button's badge counts the files this chat still has changed.
- Under an answer that changed files, **“N files changed · View changes”** opens the panel on that turn, and every file-edit card in the transcript has its own **Revert** / **View change**.

Inside the panel, the header reads **File Changes** over “N files changed · M changes”, with **Revert All** in its **…** menu, and under it two tabs, each with its count: **Timeline** lists every change in order (one row per edit or command, grouped under the request that caused it) — expand a row to see which files it touched and a before/after difference for each. **Files** shows the net result per file: what it was before this chat versus what it is now.

- **Revert** on a Timeline row (it appears when you point at the row, or right-click it) undoes that one change. **Revert File** (the ↶ button on a Files row when you point at it, or right-click) returns one file to how it was before the chat. **Roll Back to Before This** (inside an expanded row) undoes that change and everything after it. **Revert All** (in the **…** menu of the panel's header) returns every file the chat touched.
- Anything that touches more than one file asks first and lists what will happen to each file (“back to before this change”, “will be deleted”, “will be recreated”).
- **Edited since** marks a file you (or another app) changed after the chat did. Reverts skip those unless you choose **Overwrite Edited Files**; the overwritten version is kept, so even that is undoable.
- Every revert is itself recorded: use **Undo** in the confirmation toast, or the **Undo** button on the revert's own Timeline row, to put things back.
- Files too large to keep in history are marked “can't be restored”; word documents, spreadsheets, slides and PDFs show changed paragraphs, cells, slides or pages instead of raw file contents.
- While the chat is still running a command, the panel says so and reverts wait until it finishes, so a revert never races the tool that is writing.

Settings → Privacy & Security → Data & Storage → **File History** controls how long snapshots are kept; deleting a chat always deletes its history. When retention has trimmed a file's oldest changes, its **Revert File** preview says “back to the oldest change still in history” instead of “back to before this chat”.

## Sandbox

On macOS 26+, a custom agent runs shell/code work inside an isolated Linux VM instead of your Mac; it is on by default and switched per agent under Settings → Agents → the custom agent → Sandbox → Execution → **Autonomous Execution**. The input bar has no sandbox toggle. Picking a working folder turns the sandbox off for that agent, and the agent itself never offers the folder picker while its sandbox is on.

Only one Osaurus app per Mac user can run the sandbox. While another one holds it, a red **Sandbox unavailable** chip appears on the input bar of sandbox chats; hovering names the app, and clicking offers the fix (quit it, end the process, or retry). The agent says the same in its reply instead of moving the work to your Mac, and the sandbox starts on its own once the other app lets go.

## Agent generation defaults

Set persistent generation overrides under Settings → Agents → the custom agent → General → Configure → Advanced Settings → Generation Overrides. The chat input bar has no Next turn control. These defaults stay specific to the agent; the model picker's shared per-model settings are unchanged.

Inherit leaves a parameter unset. Explicit request or workflow overrides take priority over the saved agent default. A submitted message captures its defaults for its tool steps, queue and regeneration, including after reopening the chat. Editing the agent affects later submissions.

Template parameters (JSON) passes an object to a supporting model's own chat template. The template defines each variable's type; nested null values are preserved. Conversation, tool-list and special-token variables cannot be replaced. A shared workspace agent uses its host's settings.

## Useful chat extras

- `/screenshot` captures your main display into the chat's artifacts (needs Screen Recording permission).
- `/skill-name` force-loads a skill for one message.
- `/workflow-name` opens one of the agent's workflows: its run form in Workflows.
- Voice: the mic button dictates locally (see the Voice topic); the speaker button reads replies aloud when TTS is enabled.
- Clipboard monitoring (Settings → Chat → Behavior) offers recently copied text as context.
- Context window cap (how much history fits) is Settings… (⌘,) → Server → Settings → Cache → Context Window Cap, not the Chat page (Chat → Advanced has a link that jumps there). The composer Context Budget popover is read-only.

## Tips

- Be specific; let the todo list show progress on long tasks.
- On a custom agent, use a working folder for repo work, the sandbox for scripts and package installs, and neither for plain Q&A. On the Orchestrator, set a working folder when you want delegated work to land somewhere you can see; stay on it for setup, questions, and delegation.
- Tool approvals are per-tool; you can grant "always allow" per agent in Permissions.


## Choosing a model in chat

Open the model pill to browse Provider and Model columns. Installed Local models come first, followed by active Osaurus Cloud models and connected providers. Inactive Local and Osaurus Cloud entries remain available with an Explore action. Local opens model downloads in Settings; Osaurus Cloud opens the Cloud model browser.

The Cloud shortlist contains favorites plus the current Cloud model. Use the star to add or remove a favorite in either the shortlist or the full browser. More models opens the same Local or Cloud destination.

In the Cloud browser, search by model name or provider and filter by Category or Context. Category tags identify each model’s task; models with available minimum pricing show From credits beneath their name. Selecting a model closes the browser, while starring a model keeps it open. Manage Credits opens your Cloud account controls.

Selecting a model with options reveals an options column beside Provider and Model. When the model exposes a single option the column is named after it (for example Reasoning Effort, whether that's On/Off or Low through Extra High); otherwise it is titled Model options. Every option the model exposes lives there in the same row style: thinking (Default, On, Off), the reasoning level, speculative decoding (Off or Adaptive), and any toggles, each with the saved choice or model default checked and a Reset to default link when you have overridden it. Selections keep the card open; click outside or press Escape to close it. There is no separate Model options page.

## Credits in chat

Hover over the Credits button to preview your wallet, or click to keep it open. The arrowless card aligns with the button's trailing edge and stays inside the chat window. If space is limited, scroll to reach the remaining activity and actions. Click outside or press Escape to dismiss it. Add Credits opens the top-up dialog; View all opens Osaurus ID → Wallet & Credits in Settings.
