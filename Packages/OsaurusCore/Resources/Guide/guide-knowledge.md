---
title: Knowledge Collections
summary: Curated folders of documents that agents search and read on demand — human-governed, never modified without approval.
order: 105
---

# Knowledge Collections

Knowledge is what you teach your agents: a library of your own documents (SOPs, templates, standards, how-tos) that granted agents search and read on demand. Memory is what an agent learns from conversations; knowledge is explicit, versioned, and human-governed.

## Setup

1. Settings… (⌘,) → Knowledge → **Add Collection** — point it at any folder of documents: your docs, an Obsidian vault, an exported wiki. Markdown works best, but plain text, code, PDF, Word, Excel, PowerPoint, and CSV files are indexed too.
2. Open a custom agent → Abilities → **Knowledge** — enable the toggle and check the collections that agent may use.
3. Chat. The agent gets `search_knowledge` / `read_knowledge` / `list_knowledge` and consults the library only when a task calls for it.

Files are indexed in place and never moved or modified; edits to the folder are picked up within seconds. Optional YAML frontmatter (`type`, `title`, `description`, `tags`) improves search filtering.

## Grants and safety

- Grants are per agent and enforced at execution time — an agent cannot reach a collection it wasn't granted. The Default assistant cannot use knowledge (custom agents only).
- Disabling a collection skips it (no indexing, no search) without removing it from the agents that were granted it; enabling it again brings it back for them.
- Retrieval is read-only. Writing is separate: `write_knowledge`, `edit_knowledge` and `delete_knowledge` change documents in a granted collection, and each call shows an approval card with the paths and a diff of every change. Nothing is written until you allow it.
- Search is hybrid: full-text (BM25) plus semantic vectors, merged and ranked. Reads come from disk, so the agent always sees current file contents.

## Updating documents

- Ask a granted agent to update a document and it calls `edit_knowledge` (part of a document) or `write_knowledge` (new or whole documents, many in one call). You review the diff on the approval card; once allowed, the files are saved and re-indexed at once.
- An agent that notices stale content it was not asked to fix can leave a note (`flag_knowledge_stale`); notes appear in the Knowledge tab and change nothing on disk.
- Once agents have written to a collection, the Knowledge page has **History**.

## Limits and storage

- 2 MB per Markdown file, 10 MB per file in other formats, 5,000 files per collection; symlinks are skipped.
- The index lives under `~/.osaurus/knowledge/` and is a derived artifact — deleting a collection removes only Osaurus's index, never your folder.
