# Projects

A **project** groups related chats so they share the same context — instructions, knowledge, and memory — no matter which agent each chat uses. It's the container that makes "everything about this topic" behave as one workspace instead of a pile of unrelated conversations.

The mental model: agents are *who* you talk to; a project is *what* you're working on. A project pulls three orthogonal subsystems into one scope:

- **Instructions** — shared guidance prepended to every chat in the project (see [Agent Loop](AGENT_LOOP.md)).
- **Knowledge** — collections every chat in the project can search, on top of each agent's own grants (see [KNOWLEDGE.md](KNOWLEDGE.md)).
- **Memory** — a shared memory namespace every chat in the project reads and writes, across agents (see [MEMORY.md](MEMORY.md)).

> **Orthogonal to agents.** A project can hold chats from any agent, and an agent can be used in any project or none. Project membership lives on the chat session, not the agent.

---

## Table of Contents

- [Getting Started](#getting-started)
- [Model](#model)
- [Membership](#membership)
- [Shared Instructions](#shared-instructions)
- [Shared Knowledge](#shared-knowledge)
- [Shared Memory](#shared-memory)
- [Immediate vs Distilled Memory](#immediate-vs-distilled-memory)
- [KV-Cache Safety](#kv-cache-safety)
- [Storage](#storage)
- [Deletion and Purge](#deletion-and-purge)

---

## Getting Started

1. Sidebar → **Projects** tab → **New Project**
2. On the project page, set **Instructions**, grant **Knowledge** collections, and optionally pick a **Default Agent**
3. **New Chat** from the project page — the chat is a member of the project
4. Chat with any agent. Instructions and knowledge apply automatically, and everything the chats learn accumulates in the project's shared memory

Existing chats can be moved in from the sidebar (right-click → **Move to Project**).

---

## Model

`Project` (`Models/Project/Project.swift`) is a small Codable record persisted as JSON via `ProjectStore`, managed by the `@MainActor` `ProjectManager.shared`:

| Field | Meaning |
|---|---|
| `id` | UUID |
| `name` | display name |
| `instructions` | shared system-prompt text (empty = none) |
| `knowledgeCollectionIds` | collections granted to the project |
| `defaultAgentId` | agent new project chats start with (nil = the window's current agent) |
| `createdAt` / `updatedAt` | timestamps |

All optional fields decode with `decodeIfPresent`, so records written by older builds load cleanly.

---

## Membership

A chat belongs to a project via `ChatSessionData.projectId` (chat-history schema **v15** adds the `project_id` column). The live `ChatSession.projectId` mirrors it for the compose pipeline.

- **Set/clear:** `ChatSessionsManager.setProject(id:projectId:)` persists the column and posts `.chatSessionProjectDidChange` so any open window holding a live `ChatSession` updates its copy — otherwise the next compose would inject the wrong project's context.
- **New chat from the project page** stamps `session.projectId` before the first turn.
- **Switching agents** preserves `projectId` (a fresh chat started by an agent switch stays in the project).
- **Delete:** `ChatSessionsManager.deleteProject(id:)` detaches every member session, removes the record, and purges the project's memory namespace.

---

## Shared Instructions

Per turn, the composer appends the project's instructions to the system prompt as a `## Project: <name>` block (`ChatView` reads the live `session.projectId`; `AgentConfigSnapshot.capture(projectId:)` threads it through). Because instructions are constant within a project chat, they're part of the **stable** system-prompt prefix — see [KV-Cache Safety](#kv-cache-safety).

---

## Shared Knowledge

Project knowledge **overrides** each agent's own knowledge configuration — the same way granting a collection is an explicit opt-in:

- `AgentConfigSnapshot.capture` unions the project's `knowledgeCollectionIds` with the agent's own grants for the turn.
- The knowledge tools (`search_knowledge` / `read_knowledge` / `list_knowledge`) are forced into the model schema **even if the agent's own knowledge opt-in is off**, and even if it has zero collections of its own.

Rationale: knowledge is read-only reference material you deliberately attached to the project; any chat there should be able to reach it.

---

## Shared Memory

Project memory lives in its own namespace, `MemoryNamespace.project(uuid)` → key `project-<uuid>` (the hyphen prefix is filesystem-safe for vector-index directories and collision-proof against bare agent UUIDs).

Memory is **always shared** across a project — there is no per-project toggle, because a project without shared memory defeats the point. The only master switch is the **global** memory setting.

The override is **directional and namespace-scoped**:

- **Read (recall):** every chat in the project recalls the project's shared memory, regardless of the agent's own memory toggle. `SystemPromptComposer.resolveMemory` assembles the project lane even when the agent's own lane is off; `appendProjectMemory` adds it under a `## Shared project memory` header, deduped against the agent lane (exact + Jaccard ≥ 0.85).
- **Write:** a project chat's distillate is mirrored into the project namespace. When the agent's own memory is **off**, the distill writes to the **project namespace only** — never the agent's own episodes, pinned facts, or identity. So "memory off" still means "this agent builds no personal memory of me"; it just contributes to the project pool while in the project.

Everything stays under the global memory switch (`bufferTurn` and `performDistillSession` both enforce `config.enabled`).

---

## Immediate vs Distilled Memory

Distillation is a heavy, asynchronous LLM call on the **core** model — debounced and gated. If it were the only path to recall, a fact stated seconds ago wouldn't be recallable in a new chat until the distiller ran (which, for a large local core model, may be much later). So project memory has **two lanes**:

- **Immediate (transcript).** Every turn in a project chat is indexed into the project namespace the moment it's sent — a SQL transcript row + a vector doc, no LLM call (`MemoryService.mirrorTranscriptToProject`, called from `ChatView`). Runs for any project chat, even when the agent's own memory is off, under the global switch. This gives **instant** cross-chat recall.
- **Distilled (episodes/pinned).** The background distiller compacts those raw turns into clean episodes and pinned facts (`mirrorDistillateToProject`), which recall prefers.

At recall time, `appendProjectMemory` blends both: the curated lane plus a small transcript search, with transcript hits deduped against the curated lane so a fact isn't echoed once distilled.

**Compaction / bloat control.** Once a distilled episode supersedes a conversation's raw turns, `pruneTranscript` drops that conversation's older project transcripts, keeping only the most recent few (`projectTranscriptKeepLast`) as an in-flight window, and evicts the matching vectors. Crucially the prune runs *only inside* `mirrorDistillateToProject` — a namespace whose distillation never runs never prunes, so its transcripts persist as its only memory. Distillation is therefore an **optimization**, not a prerequisite for recall, and works identically for local, remote, or Apple Foundation core models.

---

## KV-Cache Safety

Memory (both lanes) is injected into the **latest user message**, never the system prompt (`SystemPromptComposer.injectMemoryPrefix`). This keeps the system-prompt prefix byte-stable across turns so the paged KV cache reuses the whole prior exchange; only the fresh user turn — which is prefilled anyway — carries the memory, and its injected bytes are frozen once sent (`composeInjectedUserPrefix`) so later turns replay identically. Project *instructions* do live in the system prompt, but they're constant within a project chat, so they don't churn the prefix either.

---

## Storage

| Data | Where |
|---|---|
| Project records | JSON via `ProjectStore` (`ProjectManager.shared`) |
| Chat membership | `sessions.project_id` in `chat_history.db` (schema v15) |
| Project memory rows | `episodes` / `pinned_facts` / `transcript` keyed `agent_id = project-<uuid>` in the memory DB |
| Project memory vectors | `memory/vectura/project-<uuid>/` |

---

## Deletion and Purge

Deleting a project (or **Forget** on its Memory-settings row) runs the same purge:

- `MemoryDatabase.deleteNamespaceData(project-<uuid>)` — episodes, pinned facts, **and** transcripts.
- `MemorySearchService.purgeNamespaceStorage(project-<uuid>)` — evicts the in-memory index and removes the on-disk vector directory.
- `MemoryContextAssembler.invalidateCache(project-<uuid>)` — drops any cached assembler block.

Member chats are detached (their `project_id` cleared), not deleted.
