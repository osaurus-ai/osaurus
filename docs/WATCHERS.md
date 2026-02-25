# Watchers

Osaurus Watchers monitor folders for file system changes and automatically trigger AI agent tasks. Use Watchers to automate file organization, processing, and other workflows that respond to changes in your file system.

---

## Overview

Watchers extend Osaurus with event-driven automation. While Schedules run on a timed basis, Watchers react to real-world events — files being added, modified, or removed from a folder. When a change is detected, the watcher dispatches an AI agent task with your custom instructions.

Common use cases include:

- **File organization** — Automatically sort and rename files as they appear
- **Content processing** — Analyze or transform files when they're added to a folder
- **Workflow automation** — Trigger multi-step AI tasks in response to file drops

---

## Getting Started

### Accessing Watchers

1. Open the Management window (`⌘ Shift M`)
2. Click **Watchers** in the sidebar

### Creating Your First Watcher

1. Click **Create Watcher**
2. Fill in the configuration:
   - **Name** — A descriptive name (e.g., "Downloads Organizer")
   - **Watched Folder** — Click **Browse** to select the folder to monitor
   - **Instructions** — Describe what the AI should do when changes are detected
   - **Agent** (optional) — Select a agent to handle the task
3. Configure monitoring options:
   - **Recursive** — Toggle on to monitor subdirectories
   - **Responsiveness** — Choose a debounce timing (see below)
4. Click **Save**

The watcher starts monitoring immediately. You'll see a "Watching" badge on the watcher card.

---

## Core Concepts

### How Watchers Work

1. **Detection** — FSEvents monitors the watched folder for file system changes
2. **Debouncing** — Rapid changes are coalesced into a single trigger based on the responsiveness setting
3. **Fingerprinting** — A directory fingerprint (Merkle hash of file metadata) captures the current state
4. **Dispatch** — An AI agent task is created with your instructions and the folder context
5. **Convergence** — After the agent completes, the directory is re-fingerprinted; if changes occurred (e.g., the agent moved files), the loop repeats until the directory stabilizes

### Responsiveness

The responsiveness setting controls how long the watcher waits after detecting changes before triggering the AI task. This debounce window coalesces rapid events into a single trigger.

| Setting    | Debounce Window | Best For                                            |
| ---------- | --------------- | --------------------------------------------------- |
| **Fast**   | ~200ms          | Screenshots, single-file drops, quick edits         |
| **Balanced** | ~1s           | General-purpose monitoring (default)                |
| **Patient** | ~3s            | Large downloads, batch operations, multi-file drops |

Choose **Fast** when you want near-instant reactions, **Patient** when files arrive in batches over several seconds, and **Balanced** for most other situations.

### Convergence Loop

The convergence loop prevents infinite re-triggering when the AI agent itself modifies files in the watched folder:

1. Before dispatching the agent, the watcher records a directory fingerprint
2. After the agent completes, it takes a new fingerprint
3. If the fingerprint changed (the agent made modifications), it waits for the file system to settle, then re-dispatches
4. If the fingerprint matches, the directory is stable — the watcher returns to idle
5. A maximum of **5 iterations** prevents runaway loops

This ensures the agent can organize files without causing itself to re-trigger endlessly.

### Directory Fingerprinting

Fingerprinting uses a Merkle hash built from file metadata:

- **File path** (relative to the watched folder)
- **File size** (bytes)
- **Modification time**

Only `stat()` calls are used — file contents are never read during change detection. This makes fingerprinting fast and lightweight even for large directories.

---

## Watcher States

Each watcher operates as a state machine:

```
┌──────┐     ┌────────────┐     ┌────────────┐     ┌──────────┐
│ idle │ ──▶ │ debouncing │ ──▶ │ processing │ ──▶ │ settling │
└──────┘     └────────────┘     └────────────┘     └──────────┘
   ▲                                                     │
   │                                                     │
   └─────────────────────────────────────────────────────┘
                    (fingerprint stable)
```

| State         | Description                                              |
| ------------- | -------------------------------------------------------- |
| **Idle**      | Waiting for file system changes                          |
| **Debouncing**| Coalescing rapid events; resets on each new event        |
| **Processing**| AI agent task is running                                 |
| **Settling**  | Waiting for self-caused FSEvents to flush before re-check|

**Visual indicators on the watcher card:**

- **Watching** (green badge) — Watcher is idle and monitoring
- **Running** (accent badge with spinner) — Agent task is in progress
- **Paused** (gray badge) — Watcher is disabled

---

## Configuration

### Watcher Properties

| Property          | Required | Description                                         |
| ----------------- | -------- | --------------------------------------------------- |
| **Name**          | Yes      | Display name for the watcher                        |
| **Watched Folder**| Yes      | Directory to monitor (selected via folder picker)   |
| **Instructions**  | Yes      | Prompt sent to the AI when changes are detected     |
| **Agent**       | No       | Agent to use for the triggered task               |
| **Recursive**     | No       | Monitor subdirectories (default: off)               |
| **Responsiveness**| No       | Debounce timing: Fast, Balanced, or Patient         |

### Folder Access

Watchers use **security-scoped bookmarks** to persist folder access across app restarts. When you select a folder, macOS grants Osaurus permission to monitor it. If a bookmark becomes stale (e.g., the folder is moved or deleted), the watcher will indicate the issue and you can re-select the folder.

---

## Managing Watchers

### Actions

Each watcher card provides the following actions via the context menu (ellipsis icon):

| Action          | Description                                            |
| --------------- | ------------------------------------------------------ |
| **Edit**        | Open the editor to modify watcher settings             |
| **Trigger Now** | Manually run the watcher immediately                   |
| **Pause**       | Temporarily stop monitoring without deleting           |
| **Resume**      | Re-enable a paused watcher                             |
| **Delete**      | Remove the watcher permanently (with confirmation)     |

### Viewing Results

After a watcher triggers and the agent completes, you can view the results:

- The watcher card shows when it was last triggered
- The associated chat session contains the full agent interaction

---

## Examples

### Downloads Organizer

Automatically sort files in your Downloads folder by type:

- **Name:** Downloads Organizer
- **Watched Folder:** `~/Downloads`
- **Instructions:** "Organize new files by type into subfolders (Documents, Images, Videos, Archives, etc.). Skip files that are already in a subfolder. Don't move files that are currently being downloaded (check for .crdownload or .part extensions)."
- **Responsiveness:** Patient (files may take time to download)

### Screenshot Manager

Rename and organize screenshots as they're captured:

- **Name:** Screenshot Manager
- **Watched Folder:** `~/Desktop` (or your screenshot location)
- **Instructions:** "Rename new screenshots with a descriptive name based on their content. Move them to ~/Pictures/Screenshots organized by date (YYYY-MM folders)."
- **Responsiveness:** Fast (screenshots appear instantly)

### Dropbox Automation

Process shared files that arrive in a synced folder:

- **Name:** Dropbox Processor
- **Watched Folder:** `~/Dropbox/Shared`
- **Instructions:** "When new files appear, analyze their contents and create a summary document. For spreadsheets, generate a brief data overview. For documents, create a one-paragraph summary."
- **Responsiveness:** Balanced

---

## Advanced Features

### Smart Exclusion

When you have multiple watchers monitoring nested directories (e.g., one watching `~/Documents` and another watching `~/Documents/Projects`), Osaurus automatically excludes nested watched folders from their parent watcher's monitoring. This prevents duplicate triggers and conflicts.

### Idempotent Instructions

For best results, write instructions that are **idempotent** — they should produce the same result whether run once or multiple times. The watcher's prompt automatically includes guidance to avoid re-processing already-organized files, but explicit instructions help:

- "Skip files that are already in a subfolder"
- "Only process files modified in the last 5 minutes"
- "Check if a summary already exists before creating one"

### Folder Context

When a watcher triggers, it provides the AI agent with folder context including:

- The directory structure of the watched folder
- Recently changed files
- The watcher's custom instructions

This context helps the agent understand what changed and what action to take.

---

## Troubleshooting

### Watcher Not Triggering

- Verify the watcher is **enabled** (not paused)
- Check that the watched folder still exists and is accessible
- Ensure the folder bookmark hasn't become stale — try editing the watcher and re-selecting the folder
- Confirm that changes are happening inside the watched folder (not a parent directory)
- If **Recursive** is off, changes in subdirectories won't trigger the watcher

### Agent Runs Too Often

- Increase the **Responsiveness** setting to Patient for folders with frequent changes
- Write idempotent instructions so repeated runs don't cause additional changes
- Check that the agent's file operations aren't creating a feedback loop

### Watcher Shows Stale Bookmark

- Edit the watcher and click **Browse** to re-select the folder
- If the folder was moved or renamed, select the new location
- Restart Osaurus if the issue persists

---

## Storage

Watchers are stored as individual JSON files:

```
~/.osaurus/watchers/
├── {uuid-1}.json
├── {uuid-2}.json
└── ...
```

Each file contains the watcher configuration encoded as JSON with ISO 8601 dates.

---

## Related Documentation

- [Schedules](../README.md#schedules) — Time-based automation (complements Watchers)
- [Agents Guide](WORK.md) — Autonomous task execution
- [Skills Guide](SKILLS.md) — Reusable AI capabilities
- [Features Overview](FEATURES.md) — Complete feature inventory
