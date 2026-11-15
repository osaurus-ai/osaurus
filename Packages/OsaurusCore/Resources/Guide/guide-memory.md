---
title: Memory and Knowledge
summary: What Osaurus remembers across chats, and curated document libraries agents can search.
order: 100
---

# Memory and Knowledge

Memory is what Osaurus learns from your conversations. Knowledge is what you teach it from your own documents. Both stay on your Mac.

## Memory

- On by default; view and manage in Settings… (⌘,) → Memory.
- Osaurus distills sessions into compact memory (identity, pinned facts, episode digests) and injects only a small relevant slice into each turn (~800 tokens or nothing) — never a full transcript dump.
- Memory is kept per agent and per project (Memory → Agents & Projects), alongside your Profile. Distillation runs after ~60 seconds of idle or when you leave a session, using the core model (default: Apple's on-device `foundation` on macOS 26+; change it in Settings → Models → Model Defaults → Core Model).
- Your Overrides (Memory → Profile → Your Overrides → Add): facts that are always included in context.
- Memory → **Memories**: inspect, search, and forget individual items. Consolidation (**Run Now**) and **Clear All Memory** (irreversible) are in Memory → **Settings**.
- Per-agent Memory Recall (a `search_memory` tool) is a separate opt-in: agent → Abilities → Memory Recall.
- Settings you can change (also via the assistant): enabled, memory budget tokens, retention days. Config: `~/.osaurus/config/memory.json`; data: `~/.osaurus/memory/memory.sqlite`.
- Note: the raw `POST /v1/chat/completions` API does not inject memory; in-app chat and `POST /agents/{id}/run` do.
- Memory is NOT the server prompt/KV cache. The on-disk prompt cache (persists prompt prefixes across restarts) is a Server toggle in Settings → Server → Server Settings → Cache; it is not part of the declarative configuration document.

## Knowledge

- A human-curated library of your docs (SOPs, guides, standards) that agents search and read on demand — different from memory, which is learned from conversation.
- Setup: Settings… (⌘,) → Knowledge → Add Collection → pick any folder of documents. Markdown works best, but plain text, code, PDF, Word, Excel, PowerPoint, and CSV files are indexed too. Files are indexed in place, never moved; edits are picked up within seconds.
- Grant per agent: agent → Abilities → Knowledge → enable and check collections. The default agent cannot use knowledge.
- Granted agents get `search_knowledge`, `read_knowledge`, `list_knowledge` to read, and `write_knowledge`, `edit_knowledge`, `delete_knowledge` to change documents. Every write shows an approval card with the paths and a diff first; nothing is written until you allow it.
- Limits: 2 MB per Markdown file, 10 MB per file in other formats, 5,000 files per collection. Deleting a collection removes only Osaurus's index — your folder is untouched.
