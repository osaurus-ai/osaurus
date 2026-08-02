---
title: Knowledge Collections
summary: Curated folders of documents that agents search and read on demand — human-governed, never modified without approval.
order: 105
---

# Knowledge Collections

Knowledge is what you teach your agents: a library of your own documents (SOPs, templates, standards, how-tos) that granted agents search and read on demand. Memory is what an agent learns from conversations; knowledge is explicit, versioned, and human-governed.

## Setup

1. Management (⌘⇧M) → Knowledge → **Add Collection** — point it at any folder of documents: your docs, an Obsidian vault, an exported wiki. Markdown works best, but plain text, code, PDF, Word, Excel, PowerPoint, and CSV files are indexed too.
2. Open a custom agent → Abilities → Overview → **Knowledge** — enable the toggle and check the collections that agent may use.
3. Chat. The agent gets `search_knowledge` / `read_knowledge` / `list_knowledge` and consults the library only when a task calls for it.

Files are indexed in place and never moved or modified; edits to the folder are picked up within seconds. Optional YAML frontmatter (`type`, `title`, `description`, `tags`) improves search filtering.

## Grants and safety

- Grants are per agent and enforced at execution time — an agent cannot reach a collection it wasn't granted. The Default assistant cannot use knowledge (custom agents only).
- Disabling a collection removes it from every agent that referenced it.
- Retrieval is read-only. **No tool ever writes into your folder.**
- Search is hybrid: full-text (BM25) plus semantic vectors, merged and ranked. Reads come from disk, so the agent always sees current file contents.

## The curation loop (optional)

- Any granted agent that notices stale content can file a ticket (`flag_knowledge_stale`); tickets appear in the Knowledge tab.
- An agent with the **Curator** toggle can work the queue and draft a replacement document as a proposal — which waits, inert, for you.
- You review a line diff in the Knowledge tab and **Approve** (writes the file, re-indexes, resolves the ticket) or **Dismiss** (reopens the ticket). Approval is the only code path that writes into your folder.
- Put a curator on a schedule and the loop runs in the background — approvals still wait for you.

## Limits and storage

- 2 MB per file, 5,000 files per collection; symlinks are skipped.
- The index lives under `~/.osaurus/knowledge/` and is a derived artifact — deleting a collection removes only Osaurus's index, never your folder.
