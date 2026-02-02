# Agents

Osaurus Agents provide autonomous task execution with built-in issue tracking, planning, and file operations. Use Agents for complex, multi-step tasks that benefit from systematic execution and progress tracking.

---

## Overview

Agents extend Osaurus beyond simple chat interactions. While Chat Mode is ideal for quick questions and single-turn interactions, Agent Mode excels at:

- **Multi-step tasks** — Building features, refactoring code, or writing documentation
- **File operations** — Reading, writing, and editing files within a project
- **Systematic execution** — Breaking work into trackable issues with dependencies
- **Parallel workflows** — Running multiple tasks simultaneously

---

## Getting Started

### Accessing Agent Mode

1. Open the Chat window
2. Click the **Agent** tab (or use the keyboard shortcut)
3. You'll see the Agent Mode interface with the issue tracker sidebar

### Setting a Working Directory

Before starting a task that involves file operations:

1. Click **Select Folder** in the Agent interface
2. Choose the project directory you want to work in
3. Grant folder access when prompted

The working directory determines where file operations can occur. All file paths are relative to this directory.

### Creating Your First Task

1. Type your task description in the input field (e.g., "Add a dark mode toggle to the settings page")
2. Press Enter or click Send
3. The agent will:
   - Analyze your request
   - Create an initial issue
   - Generate an execution plan
   - Begin executing steps

---

## Core Concepts

### Tasks

A **Task** represents a complete unit of work requested by the user. Each task:

- Has a unique identifier
- Contains one or more issues
- Is associated with a persona
- Tracks cumulative token usage

You can run **multiple tasks in parallel**, allowing you to work on different projects or features simultaneously.

### Issues

**Issues** are the building blocks of task execution. Each issue represents a discrete piece of work:

| Property        | Description                                     |
| --------------- | ----------------------------------------------- |
| **Status**      | `open`, `in_progress`, `blocked`, `closed`      |
| **Priority**    | P0 (critical), P1 (high), P2 (medium), P3 (low) |
| **Type**        | `task`, `bug`, `discovery`                      |
| **Title**       | Brief description of the work                   |
| **Description** | Detailed explanation and context                |
| **Result**      | Outcome after completion                        |

### Execution Plans

When working on an issue, the agent generates an **execution plan** — a step-by-step sequence of actions:

- Plans are bounded to **max 10 tool calls** per issue
- Each step uses available tools (file operations, shell commands, etc.)
- If a task is too large, it's automatically **decomposed** into subtasks

### Dependencies

Issues can have **dependencies** that control execution order:

| Relationship      | Description                                      |
| ----------------- | ------------------------------------------------ |
| `blocks`          | One issue must complete before another can start |
| `parent_child`    | Issue was decomposed from a larger issue         |
| `discovered_from` | Issue was discovered during execution of another |

### Discovery

During execution, the agent may **discover** additional work:

- **Errors** — Compilation errors, runtime failures
- **TODOs** — Code comments indicating pending work
- **Prerequisites** — Missing dependencies or setup steps

Discovered items become new issues automatically tracked in the issue list.

---

## Working Directory (Folder Context)

The working directory provides a sandboxed environment for file operations.

### Project Detection

Osaurus automatically detects your project type based on manifest files:

| Project Type | Detected By                                      |
| ------------ | ------------------------------------------------ |
| Swift        | `Package.swift`, `.xcodeproj`, `.xcworkspace`    |
| Node.js      | `package.json`                                   |
| Python       | `pyproject.toml`, `setup.py`, `requirements.txt` |
| Rust         | `Cargo.toml`                                     |
| Go           | `go.mod`                                         |

### Features

- **File tree generation** — Respects project-specific ignore patterns (`.gitignore`, `node_modules`, etc.)
- **Manifest reading** — Understands project structure and dependencies
- **Git integration** — Access to repository status and history
- **Security-scoped bookmarks** — Persistent folder access across sessions

---

## Available Tools

Agents have access to specialized tools for file and system operations:

### File Operations

| Tool            | Description                               |
| --------------- | ----------------------------------------- |
| `file_tree`     | List directory structure with filtering   |
| `file_read`     | Read file contents (supports line ranges) |
| `file_write`    | Create or overwrite files                 |
| `file_edit`     | Surgical text replacement within files    |
| `file_search`   | Search for text patterns across files     |
| `file_move`     | Move or rename files                      |
| `file_copy`     | Duplicate files                           |
| `file_delete`   | Remove files                              |
| `dir_create`    | Create directories                        |
| `file_metadata` | Get file information (size, dates, etc.)  |

### Shell Operations

| Tool        | Description                                  |
| ----------- | -------------------------------------------- |
| `shell_run` | Execute shell commands (requires permission) |

### Git Operations

| Tool         | Description                                    |
| ------------ | ---------------------------------------------- |
| `git_status` | Show repository status                         |
| `git_diff`   | Display file differences                       |
| `git_commit` | Stage and commit changes (requires permission) |

All tools:

- Validate paths are within the working directory
- Log operations for undo support
- Respect permission policies

---

## Features

### Parallel Tasks

Run multiple agent tasks simultaneously:

- Start a new task while others are running
- Each task maintains its own issue list and execution state
- Background tasks continue running independently
- View all active tasks in the sidebar

### File Operation Logging

Every file operation is logged for transparency and reversibility:

- **Create** — New file created
- **Write** — File contents replaced
- **Edit** — Specific text replaced
- **Delete** — File removed
- **Move** — File relocated
- **Copy** — File duplicated

Use the **Undo** feature to revert individual operations or all changes for an issue.

### Background Execution

Tasks continue running even when:

- The Agent window is closed
- You switch to Chat Mode
- Osaurus is minimized

Background task progress appears in:

- Toast notifications
- Activity feed
- Menu bar indicators

### Clarification Requests

When a task is ambiguous, the agent pauses to ask for clarification:

- Questions appear in the chat interface
- May include predefined options for quick selection
- Execution resumes after you respond

### Token Usage Tracking

Monitor resource consumption per task:

- **Input tokens** — Context sent to the model
- **Output tokens** — Generated responses
- **Cumulative total** — Running count across all issues

---

## Integration

### Personas

Each task is associated with a **persona**:

- The active persona when you start a task is used throughout
- Persona's system prompt guides the agent's behavior
- Tool permissions from the persona apply to the task

### Skills

Agents use **two-phase capability selection**:

1. **Catalog phase** — Lightweight skill descriptions loaded initially
2. **Selection phase** — Agent chooses relevant skills for the task
3. **Execution phase** — Full skill instructions loaded for selected items

This reduces token usage while maintaining access to all capabilities.

---

## Issue Lifecycle

```
┌─────────┐     ┌─────────────┐     ┌─────────┐     ┌────────┐
│  open   │ ──▶ │ in_progress │ ──▶ │ blocked │ ──▶ │ closed │
└─────────┘     └─────────────┘     └─────────┘     └────────┘
     │                │                   │
     │                │                   │
     ▼                ▼                   ▼
  Created         Executing          Waiting on
  by user        plan steps         dependencies
  or agent
```

**Status Transitions:**

| From          | To            | Trigger                       |
| ------------- | ------------- | ----------------------------- |
| `open`        | `in_progress` | Agent starts working on issue |
| `in_progress` | `blocked`     | Dependency not yet resolved   |
| `in_progress` | `closed`      | Issue completed successfully  |
| `blocked`     | `in_progress` | Blocking issue resolved       |
| Any           | `closed`      | User manually closes issue    |

---

## Best Practices

### Writing Effective Task Descriptions

- **Be specific** — "Add a logout button to the navbar" vs "Update the UI"
- **Provide context** — Mention relevant files, frameworks, or patterns
- **Define success** — Describe the expected outcome

### Managing Multiple Tasks

- Use different working directories for unrelated projects
- Review task progress regularly in the sidebar
- Cancel stuck tasks and retry with clearer instructions

### Handling Clarifications

- Answer promptly to avoid blocking execution
- Choose from predefined options when available
- Provide additional context if the question is unclear

---

## Troubleshooting

### Agent Can't Access Files

- Verify the working directory is set correctly
- Check that folder permissions were granted
- Ensure the file path is within the working directory

### Task Seems Stuck

- Check for pending clarification requests
- Review the issue status in the sidebar
- Look for blocked dependencies

### Unexpected File Changes

- Use the file operation log to review changes
- Undo specific operations or all changes for an issue
- Check git status for uncommitted modifications

---

## Related Documentation

- [Skills Guide](SKILLS.md) — Creating and managing AI capabilities
- [Plugin Authoring Guide](PLUGIN_AUTHORING.md) — Extending with custom tools
- [Features Overview](FEATURES.md) — Complete feature inventory
