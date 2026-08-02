---
title: Memory and Knowledge
summary: What Osaurus remembers across chats, and curated document libraries agents can search.
order: 100
---

# Memory and Knowledge

Memory is what Osaurus learns from your conversations. Knowledge is what you teach it from your own documents. Both stay on your Mac.

## Memory

- On by default; view and manage in Management (⌘⇧M) → Memory.
- Osaurus distills sessions into compact memory (identity, pinned facts, episode digests) and injects only a small relevant slice into each turn (~800 tokens or nothing) — never a full transcript dump.
- Memory is global across chats. Distillation runs after ~60 seconds of idle or when you leave a session, using the core model (default: Apple's on-device `foundation` on macOS 26+; change it in Settings → General).
- Your Overrides (Memory → Your Overrides → Add): facts that are always included in context.
- Memory Console: inspect, search, forget individual items, run consolidation, or clear everything (irreversible).
- Per-agent Memory Recall (a `search_memory` tool) is a separate opt-in: agent → Abilities → Overview → Memory Recall.
- Settings you can change (also via the assistant): enabled, memory budget tokens, retention days. Config: `~/.osaurus/config/memory.json`; data: `~/.osaurus/memory/memory.sqlite`.
- Note: the raw `POST /v1/chat/completions` API does not inject memory; in-app chat and `POST /agents/{id}/run` do.

## Knowledge

- A human-curated library of your docs (SOPs, guides, standards) that agents search and read on demand — different from memory, which is learned from conversation.
- Setup: Management → Knowledge → Add Collection → pick any folder of `.md`/`.markdown`/`.mdx` files. Files are indexed in place, never moved; edits are picked up within seconds.
- Grant per agent: agent → Abilities → Overview → Knowledge → enable and check collections. The default agent cannot use knowledge.
- Granted agents get `search_knowledge`, `read_knowledge`, `list_knowledge` — read-only; no tool ever writes to your folder.
- Optional Curator mode lets an agent propose document updates as diffs that you Approve or Dismiss in the Knowledge tab; only Approve writes to disk.
- Limits: 2 MB per file, 5,000 files per collection. Deleting a collection removes only Osaurus's index — your folder is untouched.
