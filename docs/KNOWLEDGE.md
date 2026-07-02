# Knowledge

Osaurus Knowledge gives agents a library of curated reference material — SOPs, templates, coding standards, how-to guides — that they search and read **on demand**, scoped per agent, and never modify without your approval.

The mental model: **memory** is what an agent learns about you from conversations; **knowledge** is what you teach it. Memory is agent-written and salience-decayed. Knowledge is human-governed, explicit, and versioned.

> **Not the same as Memory or Agent DB.** Memory is conversation-derived recall (see [MEMORY.md](MEMORY.md)); Agent DB is an agent's private structured store (see [AGENT_DB.md](AGENT_DB.md)). Knowledge is a shared, read-mostly corpus you curate. An agent can use any combination.

---

## Getting Started

1. Open the Management window (`⌘ Shift M`) → **Knowledge**
2. **Add Collection** — point it at any folder of markdown (your docs, an Obsidian vault, a cloned wiki), or paste a git URL to clone into Osaurus-managed storage
3. Open an agent → **Features → Knowledge** — enable the toggle and check the collections this agent may use
4. Chat. The agent gets `search_knowledge` / `read_knowledge` / `list_knowledge` and consults the library only when a task calls for it

Files are indexed in place and never moved or modified. Edits to the folder are picked up within seconds (FSEvents watcher + content-hash incremental re-index).

---

## Format

A collection is a plain directory of markdown files, optionally with YAML frontmatter. Osaurus aligns with the Open Knowledge Format (OKF) as a superset:

- frontmatter is optional; when present, `type`, `title`, `description`, and `tags` are recognized as facets
- `tags` drive search filtering; `type` drives listing filters
- `index.md` / `log.md` are treated as OKF reserved files
- the **OKF** button on a collection card reports documents missing a frontmatter `type`

The markdown folder is the source of truth. Every index (SQLite FTS + per-collection vector buckets under `~/.osaurus/knowledge/`) is a derived, rebuildable artifact and is never committed to git.

---

## Scoping

Grants are per agent and enforced at tool **execution time**, not just in the model-visible schema — an agent cannot reach a collection it wasn't granted, even with crafted tool arguments. Sub-agents spawned via `spawn_agent` resolve their own grants, not the caller's. The built-in Default agent cannot use knowledge (custom agents only, like the other capability gates).

---

## Tools

| Tool | Who | Purpose |
| --- | --- | --- |
| `search_knowledge` | any granted agent | Hybrid (BM25 + vector) search over granted collections |
| `read_knowledge` | any granted agent | Full or section-scoped document read (24k char cap) |
| `list_knowledge` | any granted agent | Browse by `type` / `tag` facets |
| `flag_knowledge_stale` | any granted agent | File a staleness ticket (annotation only; deduped per document) |
| `list_knowledge_tickets` | any granted agent | Browse tickets in the granted scope |
| `update_knowledge_ticket` | curator agents | Claim (`in_progress`) or release (`open`) a ticket |
| `propose_knowledge_update` | curator agents | Draft a full replacement document as a pending proposal (`.ask` policy, denied on external surfaces) |

No tool writes into a collection. Ever.

---

## The Curation Loop

1. Any agent that notices drift ("this guide predates WordPress 8.0") calls `flag_knowledge_stale` → a ticket appears in the Knowledge tab
2. A **curator** agent (Features → Knowledge → Curator) works the queue: lists tickets, claims one, researches, and calls `propose_knowledge_update`
3. The proposal waits in the Knowledge tab. Review shows a line diff against the current document; you can edit the content before accepting
4. **Approve** writes the file, re-indexes, resolves the ticket — and in a git-backed collection, commits and pushes
5. **Dismiss** reopens the linked ticket so the drift report isn't lost

Put the curator on a Schedule (see Schedules) and the loop runs in the background — approvals still wait for you. The Knowledge sidebar item highlights while proposals are pending.

---

## Git Sync

- **Add from URL** clones into `~/.osaurus/knowledge/<id>/content/` and remembers the remote
- Pointing a collection at a folder that is already a git repo also enables sync (a `git` chip shows on the card)
- **Sync** = pull (`--ff-only`) then push. Diverged history or a rejected push stops safely and tells you to resolve with your own git tooling — Osaurus never merges for you
- Credentials are your own: the system `git` runs with your credential helper / SSH agent (`GIT_TERMINAL_PROMPT=0`, SSH `BatchMode` — missing credentials fail fast instead of hanging)
- Approved proposals in a git collection are committed (`update <path> via knowledge curation`) and pushed best-effort

---

## Storage

| Artifact | Location | Notes |
| --- | --- | --- |
| Collection registry | `~/.osaurus/knowledge/collections/*.json` | One JSON per collection |
| Derived index | `~/.osaurus/knowledge/knowledge.sqlite` | Documents, chunks, FTS5, tickets, proposals; SQLCipher posture applies |
| Vector buckets | `~/.osaurus/knowledge/vectura/<collectionId>/` | Plaintext, rebuilt on demand |
| Cloned content | `~/.osaurus/knowledge/<collectionId>/content/` | Only for add-from-URL collections |

Deleting a collection removes its registry entry, derived index rows (including tickets/proposals), vectors, and — for cloned collections — the managed content directory. User-chosen folders are never touched.
