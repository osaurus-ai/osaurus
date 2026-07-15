# Knowledge

Osaurus Knowledge gives agents a library of curated reference material — SOPs, templates, coding standards, how-to guides — that they search and read **on demand**, scoped per agent, and never modify without your approval.

The mental model: **memory** is what an agent learns about you from conversations; **knowledge** is what you teach it. Memory is agent-written and salience-decayed. Knowledge is human-governed, explicit, and versioned.

> **Not the same as Memory or Agent DB.** Memory is conversation-derived recall (see [MEMORY.md](MEMORY.md)); Agent DB is an agent's private structured store (see [AGENT_DB.md](AGENT_DB.md)). Knowledge is a shared, read-mostly corpus you curate. An agent can use any combination.

---

## Table of Contents

- [Getting Started](#getting-started)
- [Format](#format)
- [Architecture](#architecture)
- [Scoping and Grants](#scoping-and-grants)
- [Tools](#tools)
- [Indexing](#indexing)
- [Search and Retrieval](#search-and-retrieval)
- [The Curation Loop](#the-curation-loop)
- [Subagent Grant Isolation](#subagent-grant-isolation)
- [Unattended Curation](#unattended-curation)
- [Storage](#storage)
- [Configuration Reference](#configuration-reference)

---

## Getting Started

1. Open the Management window (`⌘ Shift M`) → **Knowledge**
2. **Add Collection** — point it at any folder of markdown (your docs, an Obsidian vault, an exported wiki)
3. Open an agent → **Features → Knowledge** — enable the toggle and check the collections this agent may use
4. Chat. The agent gets `search_knowledge` / `read_knowledge` / `list_knowledge` and consults the library only when a task calls for it

Files are indexed in place and never moved or modified. Edits to the folder are picked up within seconds (FSEvents watcher + content-hash incremental re-index).

---

## Format

A collection is a plain directory of markdown files (`.md`, `.markdown`, `.mdx`), optionally with YAML frontmatter. Osaurus aligns with the Open Knowledge Format (OKF) as a superset:

- frontmatter is optional; when present, `type`, `title`, `description`, and `tags` are recognized as facets
- `tags` are normalized to a lowercase CSV and drive search filtering; `type` drives listing filters
- `index.md` / `log.md` are treated as OKF reserved files (exempt from the `type` requirement)
- the **OKF** button on a collection card reports documents missing a frontmatter `type`

The markdown folder is the **source of truth**. Every index (SQLite FTS + per-collection vector buckets under `~/.osaurus/knowledge/`) is a derived, rebuildable artifact — delete it and it regenerates on the next pass.

### Document identity

Each indexed file becomes a `KnowledgeDocument` keyed by `(collection_id, rel_path)`, where `rel_path` is the path relative to the collection folder (e.g. `wordpress/plugins.md`). The title resolves in order: frontmatter `title` → first `# heading` → filename stem. A SHA-256 `content_hash` is stored so unchanged files are skipped on re-index.

---

## Architecture

Knowledge is four cooperating actors plus one database, all under `Packages/OsaurusCore`:

| Component | Role |
| --- | --- |
| `KnowledgeManager` | App-facing façade: collection registry, index scheduling, startup kick |
| `KnowledgeIndexService` | Parses, chunks, and writes derived rows; prunes deleted files |
| `KnowledgeSearchService` | Hybrid BM25 + vector retrieval over granted collections |
| `KnowledgeCurationService` | The **single writer** to collection folders; applies approved proposals |
| `KnowledgeDatabase` | SQLCipher-encrypted SQLite: documents, chunks, FTS5, tickets, proposals |

The markdown folder is only ever **written** by `KnowledgeCurationService.approve()` — no tool, no indexer, and no watcher touches file contents. Indexing reads files and writes only to the derived database and vector store.

---

## Scoping and Grants

Grants are **per agent** and enforced at tool **execution time**, not just in the model-visible schema — an agent cannot reach a collection it wasn't granted, even with crafted tool arguments. The grant list, not schema stripping, is the boundary.

Each agent carries three capability fields:

- `knowledgeEnabled` — gates whether knowledge tools are exposed at all
- `knowledgeCollectionIds` — the per-agent grant list; empty means the tools stay hidden
- `knowledgeCuratorEnabled` — a child toggle that additionally exposes the curator tools

At runtime `AgentManager.effectiveKnowledgeCollections(for:)` intersects the agent's granted ids with the set of currently **enabled** collections, so a disabled collection disappears from every agent that referenced it. The built-in **Default agent cannot use knowledge** (custom agents only, like the other capability gates) — its baseline capabilities resolve `knowledgeEnabled: false`.

---

## Tools

| Tool | Who | Policy | Purpose |
| --- | --- | --- | --- |
| `search_knowledge` | any granted agent | `.auto` | Hybrid (BM25 + vector) search over granted collections |
| `read_knowledge` | any granted agent | `.auto` | Full or section-scoped document read (24k char cap) |
| `list_knowledge` | any granted agent | `.auto` | Browse by `type` / `tag` facets |
| `flag_knowledge_stale` | any granted agent | `.auto` | File a staleness ticket (annotation only; deduped per document) |
| `list_knowledge_tickets` | any granted agent | `.auto` | Browse tickets in the granted scope |
| `update_knowledge_ticket` | curator agents | `.auto` | Claim (`in_progress`) or release (`open`) a ticket |
| `propose_knowledge_update` | curator agents | `.ask` | Draft a full replacement document as a pending proposal |

**No tool writes into a collection. Ever.** Retrieval tools are read-only; curation tools only produce tickets and inert proposals.

### Retrieval tools

- **`search_knowledge`** — `query` (required), optional `collection`, `tags` (ANY-match), `top_k` (default 5, max 25). Returns ranked excerpts. Over-fetches when a tag filter is applied so filtering doesn't starve results.
- **`read_knowledge`** — `path` (required), optional `collection`, optional `section` (heading substring). Re-reads from **disk**, not the index, so the model always sees current bytes. Path is confined (no `..`, absolute, or `~` escapes). Content over 24,000 chars is truncated with a note.
- **`list_knowledge`** — optional `collection`, `type`, `tag`, `limit` (default 50, max 200). Ordered by collection then path.

### Curation tools

- **`flag_knowledge_stale`** — `path` + `reason` (required), optional `evidence`, `collection`. Opens one ticket per document (deduped); returns the existing id if a ticket is already open. Available to **any** granted agent.
- **`list_knowledge_tickets`** — optional `collection`, `status` (default `open`), `limit`.
- **`update_knowledge_ticket`** — `ticket_id` + `status` (`in_progress` or `open`). Curator-only; only `open ↔ in_progress` transitions are permitted. The curator gate is checked at execution time via `effectiveCapabilities(for:).knowledgeCuratorEnabled`.
- **`propose_knowledge_update`** — `path`, `new_content`, `rationale` (required), optional `ticket_id`, `collection`. Curator-only, `.ask` policy. See [The Curation Loop](#the-curation-loop) for its safeguards.

---

## Indexing

`KnowledgeIndexService` (an actor, `.shared`) owns all derived state.

**Parsing.** `KnowledgeDocumentParser` splits YAML frontmatter (reusing the Skill module's `splitFrontmatter` / `parseYamlBlock`) and extracts the OKF reserved fields (`type`, `title`, `description`, `tags`).

**Chunking.** Heading-aware: each ATX heading (`#`…`######`) starts a new section carrying a breadcrumb `heading_path` (e.g. `Setup > Testing`). Sections target a **soft 1,600-char** chunk and split at paragraph boundaries once they exceed a **hard 2,400-char** cap. Fenced code blocks (``` ``` ``` or `~~~`) are held atomic and never split mid-fence; a giant single paragraph is hard-wrapped only as a last resort.

**Incremental passes.** A content-hash (SHA-256) pass skips unchanged files; a prune pass removes rows for files that were deleted or renamed. Per-collection caps: **2 MB** per file and **5,000 files** per collection (overflow is logged and skipped). Symlinks are skipped.

**The watcher.** `KnowledgeFolderWatcher` runs an FSEvents monitor over enabled collections with a **5-second debounce**, coalescing bursts (a bulk save, an editor sync) into a single index pass. It is internal maintenance — no LLM is in the loop. It rebuilds its watch set on the `.knowledgeCollectionsChanged` notification.

**Startup.** `KnowledgeManager.scheduleIndexAll()` kicks a full pass at launch, deferred off the launch-critical path.

---

## Search and Retrieval

`KnowledgeSearchService` (an actor, `.shared`) runs **hybrid** retrieval:

- **Lexical** — SQLite FTS5 (BM25). The query sanitizer strips everything except alphanumerics, whitespace, `-`, and `_`; quotes and prefix-matches each term (`"term"*`); and joins terms with ` OR ` to maximize recall under the non-stemming `unicode61 remove_diacritics 2` tokenizer.
- **Vector** — VecturaKit per-collection buckets, with a default similarity threshold and a fetch multiplier that over-fetches so a later tag filter still returns enough hits. Vector ids are deterministic so re-indexing is stable.

Results from both arms are merged, deduplicated, score-sorted, and capped at `top_k`. When the vector store is unavailable — or vector work isn't allowed because an MLX model is resident — search **falls back to pure FTS**, and a further `LIKE` fallback covers queries that won't tokenize.

---

## The Curation Loop

The corpus only changes through a human-governed flag → ticket → proposal → approval → disk pipeline.

1. Any agent that notices drift ("this guide predates WordPress 8.0") calls `flag_knowledge_stale` → a ticket appears in the Knowledge tab (`status: open`)
2. A **curator** agent (Features → Knowledge → Curator) works the queue: lists tickets, claims one (`update_knowledge_ticket` → `in_progress`), researches, and calls `propose_knowledge_update`
3. The proposal waits in the Knowledge tab (`status: pending`). Review shows a line diff against the current document; you can edit the content before accepting
4. **Approve** writes the file, re-indexes, and resolves the linked ticket
5. **Dismiss** reopens the linked ticket so the drift report isn't lost

### Ticket and proposal state

- `KnowledgeTicket.status` ∈ `open`, `in_progress`, `proposed`, `resolved`, `dismissed` — id is an `Int` (used directly in tool arguments)
- `KnowledgeProposal.status` ∈ `pending`, `approved`, `dismissed` — `ticketId` is an optional `Int`

### Safeguards in `propose_knowledge_update`

- **Auto-link by path.** If `ticket_id` is omitted, an open ticket for the same `path` is linked automatically, so approving the proposal resolves the ticket.
- **Frontmatter preservation.** If the draft carries no frontmatter but the existing document does, the original block is re-attached so an approval can never silently strip OKF metadata.
- **Read-preamble stripping.** A leading `[Collection] path` framing line (copied from a `read_knowledge` result) is stripped from the drafted content.
- **Inert until approved.** The proposal is stored as data; nothing reaches disk until a human approves the diff.

### The single writer

`KnowledgeCurationService.approve()` is the **only** code path that writes into a collection folder. It re-validates the proposal is `pending`, re-checks path confinement, writes atomically, flips the proposal to `approved`, resolves any linked ticket to `resolved`, posts `.knowledgeCurationChanged` (so the UI drops the card immediately), and then re-indexes. A reviewer's edited version (`overrideContent`) wins over the curator's draft. Dismissing a proposal that was the sole answer to a `proposed` ticket reopens that ticket to `open`.

Put the curator on a Schedule (see [SCHEDULES.md](SCHEDULES.md)) and the loop runs in the background — approvals still wait for you. The Knowledge sidebar item highlights while proposals are pending.

---

## Subagent Grant Isolation

When an agent spawns another via `spawn_agent`, the child's knowledge tools must resolve grants against the **spawned** agent, not the launcher whose execution context they inherit.

This is done with a task-local, `ChatExecutionContext.knowledgeGrantAgentIdOverride`, bound in `TextSubagentKind.run()` to the resolved child agent id. Every knowledge tool reads `ChatExecutionContext.knowledgeAgentId`, which returns the override when set and falls back to `currentAgentId` otherwise. The effect:

- an **ungranted** spawn sees nothing, even though it runs inside the launcher's context
- a **granted** spawn sees only its own collections
- sandbox routing and the exec limiter still bill the launcher

`spawn_model` runs have no agent and therefore no knowledge tools; the override stays `nil`.

---

## Unattended Curation

Scheduled curator runs need to draft proposals with no human present, which means the `.ask` policy on `propose_knowledge_update` has to be auto-approvable in exactly that case and no other.

The gate is a task-local, `ChatExecutionContext.isUnattendedDispatch`, set in `BackgroundTaskManager` as:

```swift
let unattended = !externalSurface
    && (request.source == .schedule
        || request.source == .selfSchedule
        || request.source == .watcher)
```

`propose_knowledge_update` is the **only** `.ask` tool listed in `unattendedAutoApprovableToolNames`. So:

- an unattended schedule / self-schedule / watcher run may auto-queue a proposal
- external surfaces (loopback HTTP, MCP, plugins) are always `isExternalSurface == true`, so they never satisfy the condition and can never reach the auto-approval
- the proposal is still **inert** — a human must diff-review and approve it in the Knowledge tab before anything is written

An unattended run can therefore draft, but never mutate, the corpus.

---

## Storage

| Artifact | Location | Notes |
| --- | --- | --- |
| Collection registry | `~/.osaurus/knowledge/collections/<uuid>.json` | One JSON per collection; ISO8601 dates |
| Derived index | `~/.osaurus/knowledge/knowledge.sqlite` | Documents, chunks, FTS5, tickets, proposals; SQLCipher, WAL, serial queue |
| Vector buckets | `~/.osaurus/knowledge/vectura/<collectionId>/` | VecturaKit; rebuilt on demand |

The database carries five tables: `documents` (unique on `collection_id, rel_path`), `chunks` (unique on `document_id, chunk_index`), the contentless FTS5 mirror `chunks_fts` with insert/delete/update triggers, `tickets`, and `proposals`. Encryption follows the app's `OsaurusStorageOpener` posture (see [STORAGE.md](STORAGE.md)).

Deleting a collection removes its registry entry, derived index rows (including tickets/proposals), and vectors. The user-chosen source folder is never touched.

---

## Configuration Reference

| Setting | Where | Default | Effect |
| --- | --- | --- | --- |
| `knowledgeEnabled` | agent capabilities | `false` | Exposes knowledge tools to the agent |
| `knowledgeCollectionIds` | agent capabilities | `[]` | Per-agent grant list; empty hides the tools |
| `knowledgeCuratorEnabled` | agent capabilities | `false` | Additionally exposes the curator tools (`update_knowledge_ticket`, `propose_knowledge_update`) |
| Collection `isEnabled` | collection registry | `true` | Disabled collections are excluded from indexing, search, and every grant |
| Soft / hard chunk size | indexer | 1,600 / 2,400 chars | Chunk targets; sections split at paragraph boundaries past the hard cap |
| Per-file size cap | indexer | 2 MB | Oversized files are logged and skipped |
| Per-collection file cap | indexer | 5,000 | Overflow is logged |
| Watcher debounce | folder watcher | 5 s | Coalescing window before an index pass |
| `read_knowledge` cap | tool | 24,000 chars | Returned content is truncated with a note |
| `search_knowledge` `top_k` | tool | 5 (max 25) | Result count |

Custom-agent capabilities live in `~/.osaurus/agents/<uuid>.json`; the Default agent's configuration lives in `~/.osaurus/chat.json` and carries no knowledge grants.
