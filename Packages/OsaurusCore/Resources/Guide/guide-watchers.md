---
title: Watchers
summary: Point an agent at a folder; it runs your instructions automatically whenever the folder changes.
order: 92
---

# Watchers

Watchers are event-driven automation: while schedules run on a timer, a watcher reacts to files being added, changed, or removed in a folder and dispatches an agent with your instructions. Typical uses: a Downloads organizer, a screenshot renamer, an auto-commit for an Obsidian vault.

## Creating a watcher

- Management (⌘⇧M) → Watchers → Create Watcher: name, watched folder (Browse), instructions, and the custom agent that handles the task. Every watcher needs a custom agent — the built-in Default agent cannot run watchers.
- Or ask the default Osaurus assistant — it can create, update, pause/resume, and delete watchers (`osaurus_watcher`), creating a custom agent first if you don't have one. Folders it adds by path get standard file access; use Browse in the UI if a folder needs a security-scoped grant.
- Options: **Recursive** monitors subdirectories (off by default); **Responsiveness** sets the debounce window.

## Responsiveness

The debounce coalesces rapid changes into a single trigger:

- **Fast** (~200 ms) — screenshots, single file drops.
- **Balanced** (~1 s) — general purpose (default).
- **Patient** (~3 s) — large downloads, batch drops.
- **Relaxed** (~1 min), **Deferred** (~5 min), **Extended** (~10 min) — active editing sessions where you want one trigger after activity settles (e.g. wiki auto-commit).

## How it runs

- Changes are detected via FSEvents; only file metadata is read for change detection, never contents.
- Each trigger dispatches the agent with your instructions plus folder context (structure and recently changed files). All triggers from one watcher accumulate into a single chat session tagged `watcher` in the sidebar.
- A convergence loop re-checks the folder after the agent finishes: if the agent itself changed files, it runs again until the folder stabilizes (max 5 iterations), so an organizer can't re-trigger itself endlessly.
- Card badges: **Watching** (idle), **Running** (agent in progress), **Paused** (disabled). The context menu offers Edit, Trigger Now, Pause/Resume, and Delete.

## Tips

- Write idempotent instructions ("skip files already in a subfolder") so repeat runs are harmless.
- Watchers only fire while Osaurus is running.
- If a watcher stops triggering, check it is enabled, the folder still exists, and — if the bookmark went stale after a move — re-select the folder via Edit → Browse.
