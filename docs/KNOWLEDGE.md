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
- [Writing Documents](#writing-documents)
- [Subagent Grant Isolation](#subagent-grant-isolation)
- [Unattended Runs](#unattended-runs)
- [Storage](#storage)
- [Configuration Reference](#configuration-reference)

---

## Getting Started

1. Open Settings… (`⌘,`) → **Knowledge**
2. **Add Collection** — point it at any folder of documents (your docs, an Obsidian vault, an exported wiki)
3. Open a custom agent → **Abilities → Knowledge** — enable the toggle and check the collections this agent may use
4. Chat. The agent gets `search_knowledge` / `read_knowledge` / `list_knowledge` and consults the library only when a task calls for it

Files are indexed in place; indexing never moves or modifies them (only an approved `write_knowledge` / `edit_knowledge` / `delete_knowledge` call changes a file). Edits to the folder are picked up within seconds (FSEvents watcher + content-hash incremental re-index).

---

## Format

A collection is a plain directory of documents. Markdown (`.md`, `.markdown`, `.mdx`, optionally with YAML frontmatter) works best; every other format with a document adapter (plain text, code, PDF, Word, Excel, PowerPoint, CSV, …) is extracted and indexed too. `.env` files and dependency/build/VCS folders (`node_modules`, `dist`, `build`, `.venv`, `DerivedData`, …) are skipped, as are `.gitignore` matches unless the collection sets include globs. For markdown, Osaurus aligns with the Open Knowledge Format (OKF) as a superset:

- frontmatter is optional; when present, `type`, `title`, `description`, and `tags` are recognized as facets
- `tags` are normalized to a lowercase CSV and drive search filtering; `type` drives listing filters
- `index.md` / `log.md` are treated as OKF reserved files (exempt from the `type` requirement)
- the **OKF** button on a collection card reports documents missing a frontmatter `type`

The markdown folder is the **source of truth**. Every index (SQLite FTS + per-collection vector buckets under `~/.osaurus/knowledge/`) is a derived, rebuildable artifact — delete it and it regenerates on the next pass.

### Document identity

Each indexed file becomes a `KnowledgeDocument` keyed by `(collection_id, rel_path)`, where `rel_path` is the path relative to the collection folder (e.g. `wordpress/plugins.md`). The title resolves in order: frontmatter `title` → first `# heading` → filename stem. A SHA-256 `content_hash` is stored so unchanged files are skipped on re-index.

---

## Architecture

Knowledge is a few cooperating actors plus two databases, all under `Packages/OsaurusCore`:

| Component | Role |
| --- | --- |
| `KnowledgeManager` | App-facing façade: collection registry, index scheduling, startup kick |
| `KnowledgeIndexService` | Parses, chunks, and writes derived rows; prunes deleted files |
| `KnowledgeSearchService` | Hybrid BM25 + vector retrieval over granted collections |
| `KnowledgeWriteService` | Applies and reverts approved document writes (path confinement, atomic write, incremental re-index) |
| `KnowledgeDatabase` | Derived index: documents, chunks, FTS5, tickets |
| `KnowledgeWriteLogDatabase` | Primary data: one row per applied write with the content it replaced, so it can be reverted |

The collection folder is written only by `KnowledgeWriteService`, after you allow a `write_knowledge` / `edit_knowledge` / `delete_knowledge` call. Indexing reads files and writes only to the derived database and vector store.

---

## Scoping and Grants

Grants are **per agent** and enforced at tool **execution time**, not just in the model-visible schema — an agent cannot reach a collection it wasn't granted, even with crafted tool arguments. The grant list, not schema stripping, is the boundary.

Each agent carries two capability fields:

- `knowledgeEnabled` — gates whether knowledge tools are exposed at all
- `knowledgeCollectionIds` — the per-agent grant list; empty means the tools stay hidden

Write access follows the grant; there is no separate writer role. The former `knowledgeCuratorEnabled` field still decodes from older agent JSON but has no UI.

At runtime `AgentManager.effectiveKnowledgeCollections(for:)` intersects the agent's granted ids with the set of currently **enabled** collections. Disabling a collection only skips it (no indexing, no search); the grant stays on the agent, and enabling the collection again brings it back. The built-in **Default agent cannot use knowledge** (custom agents only, like the other capability gates) — its baseline capabilities resolve `knowledgeEnabled: false`.

---

## Tools

| Tool | Who | Policy | Purpose |
| --- | --- | --- | --- |
| `search_knowledge` | any granted agent | `.auto` | Hybrid (BM25 + vector) search over granted collections |
| `read_knowledge` | any granted agent | `.auto` | Full or section-scoped document read (24k char cap) |
| `list_knowledge` | any granted agent | `.auto` | Browse by `type` / `tag` facets |
| `write_knowledge` | any granted agent | `.ask` | Create or replace whole markdown documents, many in one call |
| `edit_knowledge` | any granted agent | `.ask` | Change part of an existing markdown document |
| `delete_knowledge` | any granted agent | `.ask` | Remove documents |
| `flag_knowledge_stale` | any granted agent | `.auto` | Leave a note that a document looks outdated (annotation only; deduped per document) |
| `list_knowledge_tickets` | any granted agent | `.auto` | Browse those notes in the granted scope |
| `update_knowledge_ticket` | any granted agent | `.auto` | Claim (`in_progress`) or release (`open`) a note |

Retrieval and ticket tools never change a file. The three write tools change files only after the approval card is allowed.

### Retrieval tools

- **`search_knowledge`** — `query` (required), optional `collection`, `tags` (ANY-match), `top_k` (default 5, max 25). Returns ranked excerpts. Over-fetches when a tag filter is applied so filtering doesn't starve results.
- **`read_knowledge`** — `path` (required), optional `collection`, optional `section` (heading substring). Re-reads from **disk**, not the index, so the model always sees current bytes. Path is confined (no `..`, absolute, or `~` escapes). Content over 24,000 chars is truncated with a note.
- **`list_knowledge`** — optional `collection`, `type`, `tag`, `limit` (default 100, max 500), `offset` (default 0). Ordered by collection then path. The result states the total matching count; when a page is smaller than the total it ends with `[total=N, returned=M, next_offset=K …]` so the model can page with `offset: K`. `collection` accepts the display name (case-insensitive), a punctuation-insensitive form (`obsidian_vault`), an unambiguous partial name, a generic alias (`knowledge`, `default`, `all` → every granted collection), or any name at all when exactly one collection is granted; the result carries a warning naming what was actually searched.

### Write tools

- **`write_knowledge`** — `documents` (array of `{path, content}`, up to 200 per call), optional `collection`, `rationale`. Whole markdown documents; when replacing one, the model must carry its `---` frontmatter across. Content is capped at 2 MB per document so it stays indexable.
- **`edit_knowledge`** — changes part of an existing document without restating it.
- **`delete_knowledge`** — removes documents.

Only markdown paths can be written. Each call shows one approval card with the paths and a diff of every change. Once allowed, the files are written, re-indexed immediately, and the result reports what landed, so the agent can confirm with `search_knowledge`.

### Ticket tools

- **`flag_knowledge_stale`** — `path` + `reason` (required), optional `evidence`, `collection`. Opens one ticket per document (deduped); returns the existing id if a ticket is already open. For drift the agent notices but was not asked to fix; to change a document it uses the write tools.
- **`list_knowledge_tickets`** — optional `collection`, `status` (default `open`), `limit`.
- **`update_knowledge_ticket`** — `ticket_id` + `status` (`in_progress` or `open`); only `open ↔ in_progress` transitions are permitted. It is in every granted agent's schema, but its execution-time check still reads the legacy `knowledgeCuratorEnabled` flag, so it refuses for agents without it.

---

## Indexing

`KnowledgeIndexService` (an actor, `.shared`) owns all derived state.

**Parsing.** `KnowledgeDocumentParser` splits YAML frontmatter (reusing the Skill module's `splitFrontmatter` / `parseYamlBlock`) and extracts the OKF reserved fields (`type`, `title`, `description`, `tags`).

**Chunking.** Heading-aware: each ATX heading (`#`…`######`) starts a new section carrying a breadcrumb `heading_path` (e.g. `Setup > Testing`). Sections target a **soft 1,600-char** chunk and split at paragraph boundaries once they exceed a **hard 2,400-char** cap. Fenced code blocks (``` ``` ``` or `~~~`) are held atomic and never split mid-fence; a giant single paragraph is hard-wrapped only as a last resort.

**Incremental passes.** A content-hash (SHA-256) pass skips unchanged files; a prune pass removes rows for files that were deleted or renamed. Caps: **2 MB** per markdown file, **10 MB** per file in other formats (`maxAdapterFileBytes`), and **5,000 files** per collection (overflow is logged and skipped). Symlinks are skipped.

**The watcher.** `KnowledgeFolderWatcher` runs an FSEvents monitor over enabled collections with a **5-second debounce**, coalescing bursts (a bulk save, an editor sync) into a single index pass. It is internal maintenance — no LLM is in the loop. It rebuilds its watch set on the `.knowledgeCollectionsChanged` notification.

**Startup.** `KnowledgeManager.scheduleIndexAll()` kicks a full pass at launch, deferred off the launch-critical path.

---

## Search and Retrieval

`KnowledgeSearchService` (an actor, `.shared`) runs **hybrid** retrieval:

- **Lexical** — SQLite FTS5 (BM25). The query sanitizer strips everything except alphanumerics, whitespace, `-`, and `_`; quotes and prefix-matches each term (`"term"*`); and joins terms with ` OR ` to maximize recall under the non-stemming `unicode61 remove_diacritics 2` tokenizer.
- **Vector** — VecturaKit per-collection buckets, with a default similarity threshold and a fetch multiplier that over-fetches so a later tag filter still returns enough hits. Vector ids are deterministic so re-indexing is stable.

Results from both arms are merged, deduplicated, score-sorted, and capped at `top_k`. When the vector store is unavailable — or vector work isn't allowed because an MLX model is resident — search **falls back to pure FTS**, and a further `LIKE` fallback covers queries that won't tokenize.

---

## Writing Documents

The corpus changes only through an approved write:

1. Ask a granted agent to update a document. It calls `edit_knowledge` (part of a document) or `write_knowledge` (new or whole documents, many in one call), or `delete_knowledge`.
2. The approval card shows the paths and a diff of every change. Nothing is written until you allow it.
3. Once allowed, `KnowledgeWriteService` records what each file held in `knowledge_writes` **before** touching it, writes atomically (confined to the collection folder), and re-indexes.
4. The Knowledge page's **History** lists what agents wrote, grouped by run. **Revert** (or **Revert all** for a run) restores the prior content; a file that changed after the write is not reverted, so newer content is never discarded.

An agent that notices drift it was not asked to fix calls `flag_knowledge_stale` instead; the note appears in the Knowledge tab and nothing on disk changes.

### Ticket state

- `KnowledgeTicket.status` ∈ `open`, `in_progress`, `proposed`, `resolved`, `dismissed` — id is an `Int` (used directly in tool arguments). `proposed` remains from the removed proposal flow.

`propose_knowledge_update`, the proposal queue, and the curator role were removed: the proposal was already behind an approval card and then needed a second approval, and because it returned "pending" the agent could never confirm what it had done (osaurus#2439).

---

## Subagent Grant Isolation

When an agent spawns another via `spawn_agent`, the child's knowledge tools must resolve grants against the **spawned** agent, not the launcher whose execution context they inherit.

This is done with a task-local, `ChatExecutionContext.knowledgeGrantAgentIdOverride`, bound in `TextSubagentKind.run()` to the resolved child agent id. Every knowledge tool reads `ChatExecutionContext.knowledgeAgentId`, which returns the override when set and falls back to `currentAgentId` otherwise. The effect:

- an **ungranted** spawn sees nothing, even though it runs inside the launcher's context
- a **granted** spawn sees only its own collections
- sandbox routing and the exec limiter still bill the launcher

---

## Unattended Runs

`ToolRegistry.unattendedAutoApprovableToolNames` is empty. A scheduled, self-scheduled, or watcher run (`ChatExecutionContext.isUnattendedDispatch`) has no one to allow the approval card, so `write_knowledge`, `edit_knowledge`, and `delete_knowledge` are never auto-approved there, and external surfaces (loopback HTTP, MCP, plugins) can never reach them. An unattended run can search, read, and leave tickets.

---

## Storage

| Artifact | Location | Notes |
| --- | --- | --- |
| Collection registry | `~/.osaurus/knowledge/collections/<uuid>.json` | One JSON per collection; ISO8601 dates |
| Derived index | `~/.osaurus/knowledge/knowledge.sqlite` | Documents, chunks, FTS5, tickets; WAL, serial queue |
| Write log | `~/.osaurus/knowledge/write_log.sqlite` | `knowledge_writes`: prior content of every applied write, for revert. Primary data, kept separate so deleting the index never loses it; retention is bounded |
| Vector buckets | `~/.osaurus/knowledge/vectura/<collectionId>/` | VecturaKit; rebuilt on demand |

The database carries five tables: `documents` (unique on `collection_id, rel_path`), `chunks` (unique on `document_id, chunk_index`), the contentless FTS5 mirror `chunks_fts` with insert/delete/update triggers, `tickets`, and the legacy `proposals` table. Both databases follow the app's opt-in encryption posture through `OsaurusStorageOpener`: plaintext by default, SQLCipher when storage encryption is on (see [STORAGE.md](STORAGE.md)).

Deleting a collection removes its registry entry, derived index rows (including tickets), and vectors. The user-chosen source folder is never touched.

---

## Configuration Reference

| Setting | Where | Default | Effect |
| --- | --- | --- | --- |
| `knowledgeEnabled` | agent capabilities | `false` | Exposes knowledge tools to the agent |
| `knowledgeCollectionIds` | agent capabilities | `[]` | Per-agent grant list; empty hides the tools |
| Collection `isEnabled` | collection registry | `true` | Disabled collections are skipped by indexing and search; grants are kept |
| Soft / hard chunk size | indexer | 1,600 / 2,400 chars | Chunk targets; sections split at paragraph boundaries past the hard cap |
| Per-file size cap | indexer | 2 MB markdown / 10 MB other formats | Oversized files are logged and skipped |
| Per-collection file cap | indexer | 5,000 | Overflow is logged |
| Watcher debounce | folder watcher | 5 s | Coalescing window before an index pass |
| `read_knowledge` cap | tool | 24,000 chars | Returned content is truncated with a note |
| `search_knowledge` `top_k` | tool | 5 (max 25) | Result count |

Custom-agent capabilities live in `~/.osaurus/agents/<uuid>.json`; the Default agent's configuration lives in `~/.osaurus/config/default-agent.json` and carries no knowledge grants.
