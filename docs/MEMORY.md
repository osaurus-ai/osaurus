# Memory

Osaurus includes a persistent memory system that learns from your conversations and provides personalized context to every AI interaction. Memory runs entirely in the background -- it extracts knowledge automatically, deduplicates entries, detects contradictions, and injects relevant context into each new conversation.

---

## Getting Started

1. Open the Management window (`⌘ Shift M`) → **Memory**
2. Memory is **enabled by default** -- toggle it off in the Memory settings if you prefer stateless conversations
3. Choose a **core model** for extraction (default: `anthropic/claude-haiku-4-5`) -- this model processes conversation turns to extract structured memories
4. Start chatting -- memories are extracted automatically from each conversation turn

No manual tagging, saving, or annotation is required. The system handles everything in the background without blocking your chat.

---

## 4-Layer Architecture

Memory is organized into four layers, each serving a different purpose:

```
┌──────────────────────────────────────────────────────────────────┐
│                         Memory System                            │
├──────────────────────────────────────────────────────────────────┤
│  Layer 1: User Profile                                           │
│  Auto-generated summary of who you are, rebuilt as new           │
│  contributions accumulate. Includes user overrides.              │
├──────────────────────────────────────────────────────────────────┤
│  Layer 2: Working Memory                                         │
│  Structured entries: facts, preferences, decisions,              │
│  corrections, commitments, relationships, skills.                │
├──────────────────────────────────────────────────────────────────┤
│  Layer 3: Conversation Summaries                                 │
│  Compressed recaps of past sessions, generated after             │
│  periods of inactivity (debounced).                              │
├──────────────────────────────────────────────────────────────────┤
│  Layer 4: Conversation Chunks                                    │
│  Raw conversation turns stored for detailed retrieval.           │
└──────────────────────────────────────────────────────────────────┘
│                                                                   │
│  Knowledge Graph (cross-cutting)                                  │
│  Entities and relationships extracted from all layers.            │
└───────────────────────────────────────────────────────────────────┘
```

### Layer 1: User Profile

A continuously updated summary of who you are. The profile is regenerated automatically after a configurable number of new contributions (default: 10).

- **Auto-generated** -- built from accumulated profile facts extracted during conversations
- **Version tracked** -- each regeneration increments the version number
- **User overrides** -- explicit facts you add manually that always appear in context, regardless of profile regeneration

User overrides take the highest priority in context assembly and are never overwritten by automatic extraction.

### Layer 2: Working Memory

Structured memory entries extracted from every conversation turn. Each entry has a type, confidence score, tags, and temporal validity.

| Entry Type | Description | Example |
|------------|-------------|---------|
| **Fact** | Factual information | "User works at Acme Corp as a backend engineer" |
| **Preference** | Likes, dislikes, and preferences | "Prefers Swift over Objective-C" |
| **Decision** | Decisions made during conversations | "Decided to use PostgreSQL for the new project" |
| **Correction** | Corrections to previous information | "Actually uses Python 3.12, not 3.11" |
| **Commitment** | Promises, plans, or intentions | "Plans to migrate to Kubernetes next quarter" |
| **Relationship** | Connections between people, projects, or concepts | "Alice is the tech lead on Project Nova" |
| **Skill** | Skills, expertise, or knowledge areas | "Experienced with Docker and CI/CD pipelines" |

Entries include:

- **Confidence scores** (0.0 -- 1.0) reflecting extraction certainty
- **Tags** for categorization
- **Temporal validity** (`validFrom` / `validUntil`) for time-bounded facts
- **Access tracking** (last accessed time and count) for relevance scoring
- **Supersession tracking** when newer information replaces older entries

### Layer 3: Conversation Summaries

Compressed recaps of past conversation sessions. Summaries are generated automatically using a debounced approach:

- A timer starts after the last conversation turn (default: 60 seconds)
- If no new messages arrive within the debounce window, a summary is generated
- Session changes (switching to a different conversation) also trigger summary generation
- On startup, any orphaned pending signals from a previous session are recovered and processed

### Layer 4: Conversation Chunks

Raw conversation turns stored individually for fine-grained retrieval. Each chunk records:

- The conversation ID and chunk index
- The role (user or assistant) and full content
- Token count and timestamp
- The agent ID and optional conversation title

This layer enables detailed search across past conversations when summaries are too coarse.

---

## Knowledge Graph

The memory system builds a knowledge graph from extracted entities and relationships.

**Entity types:** person, company, place, project, tool, concept, event

**Relationships** connect entities with:

- A descriptive relation string (e.g., "works at", "manages", "depends on")
- A confidence score
- Temporal validity (optional `validFrom` / `validUntil`)

**Graph search** supports:

- Search by entity name to find all connected relationships
- Search by relation type to discover entities with a specific connection
- Depth-limited traversal (default depth: 2) to explore the neighborhood of an entity

---

## Search & Retrieval

Memory search uses a hybrid approach combining text and semantic matching.

### Hybrid Search

When VecturaKit is available (embedding model downloaded):

1. **BM25** scores documents by keyword relevance
2. **Vector embeddings** score documents by semantic similarity
3. Scores are combined for a unified ranking

When VecturaKit is unavailable, the system falls back to **SQLite LIKE queries** for basic text matching.

### MMR Reranking

To avoid returning many near-identical results, search results are reranked using Maximal Marginal Relevance (MMR):

1. Over-fetch results (default: 2x the requested `topK`)
2. Iteratively select results that balance **relevance** (search score) with **diversity** (Jaccard distance from already-selected results)
3. The `lambda` parameter controls the tradeoff: 1.0 = pure relevance, 0.0 = pure diversity (default: 0.7)

### Search Scopes

| Scope | What it searches | Time window |
|-------|-----------------|-------------|
| Memory entries | Working memory (Layer 2) | All time |
| Conversations | Conversation chunks (Layer 4) | Last N days (default: 30) |
| Summaries | Conversation summaries (Layer 3) | Last N days (default: 30) |
| Graph | Knowledge graph entities and relationships | All time |

---

## Verification Pipeline

Before a new memory entry is stored, it passes through a 3-layer verification pipeline. This pipeline is entirely deterministic (no LLM calls) and prevents redundant or conflicting entries.

### Layer 1: Jaccard Deduplication

Compares the new entry's words against existing entries using Jaccard similarity (word overlap). If the similarity exceeds the threshold (default: 0.6), the entry is skipped as a near-duplicate.

### Layer 2: Contradiction Detection

For entries of the same type, if the Jaccard similarity is moderate (above 0.3 but below the dedup threshold), the new entry is flagged as a potential contradiction. The newer entry supersedes the older one.

### Layer 3: Semantic Deduplication

Uses vector search to find semantically similar entries. If the similarity score exceeds the threshold (default: 0.85), the entry is skipped as a semantic duplicate even if the wording differs.

---

## Context Assembly

Before each AI interaction, the `MemoryContextAssembler` builds a memory block that is injected into the system prompt. Context is assembled in priority order with per-section token budgets:

| Priority | Section | Default Budget |
|----------|---------|---------------|
| 1 | User Overrides | Always included (no budget limit) |
| 2 | User Profile | 2,000 tokens |
| 3 | Working Memory | 500 tokens |
| 4 | Conversation Summaries | 1,000 tokens |
| 5 | Key Relationships | 300 tokens |

- Results are **cached for 10 seconds** per agent to avoid redundant database queries
- Cache is invalidated when memory content changes
- If total memory context exceeds available space, lower-priority sections are truncated first

---

## Configuration Reference

All settings are configurable via the Memory tab in the Management window. The configuration file is stored as JSON and validated on load.

### Core Model

| Setting | Default | Description |
|---------|---------|-------------|
| `coreModelProvider` | `anthropic` | Provider for the extraction model |
| `coreModelName` | `claude-haiku-4-5` | Model used for memory extraction and summarization |
| `embeddingBackend` | `mlx` | Embedding backend (`mlx` or `none`) |
| `embeddingModel` | `nomic-embed-text-v1.5` | Model used for vector embeddings |

### Token Budgets

| Setting | Default | Range | Description |
|---------|---------|-------|-------------|
| `profileMaxTokens` | 2,000 | 100 -- 50,000 | Max tokens for user profile |
| `workingMemoryBudgetTokens` | 500 | 50 -- 10,000 | Token budget for working memory in context |
| `summaryBudgetTokens` | 1,000 | 50 -- 10,000 | Token budget for summaries in context |
| `graphBudgetTokens` | 300 | 50 -- 5,000 | Token budget for knowledge graph in context |

### Profile

| Setting | Default | Range | Description |
|---------|---------|-------|-------------|
| `profileRegenerateThreshold` | 10 | 1 -- 100 | New contributions before profile regeneration |

### Summaries

| Setting | Default | Range | Description |
|---------|---------|-------|-------------|
| `summaryDebounceSeconds` | 60 | 10 -- 3,600 | Inactivity period before summary generation |
| `summaryRetentionDays` | 7 | 1 -- 365 | How long summaries are retained |

### Search

| Setting | Default | Range | Description |
|---------|---------|-------|-------------|
| `recallTopK` | 10 | 1 -- 100 | Number of results for recall searches |
| `temporalDecayHalfLifeDays` | 30 | 1 -- 365 | Half-life for temporal decay in ranking |
| `mmrLambda` | 0.7 | 0.0 -- 1.0 | Relevance vs. diversity tradeoff |
| `mmrFetchMultiplier` | 2.0 | 1.0 -- 10.0 | Over-fetch multiplier before MMR reranking |

### Verification

| Setting | Default | Range | Description |
|---------|---------|-------|-------------|
| `verificationEnabled` | true | true/false | Enable the 3-layer verification pipeline |
| `verificationJaccardDedupThreshold` | 0.6 | 0.0 -- 1.0 | Jaccard threshold for near-duplicate detection |
| `verificationSemanticDedupThreshold` | 0.85 | 0.0 -- 1.0 | Vector similarity threshold for semantic dedup |

### Limits

| Setting | Default | Range | Description |
|---------|---------|-------|-------------|
| `maxEntriesPerAgent` | 500 | 0 -- 10,000 | Max active entries per agent (0 = unlimited) |
| `enabled` | true | true/false | Master toggle for the memory system |

---

## Architecture Details

### Actor-Based Concurrency

`MemoryService` and `MemorySearchService` are Swift actors, ensuring all state mutations are serialized and thread-safe. Background extraction never blocks the chat UI -- conversation turns are recorded and processed asynchronously.

### Circuit Breaker

To prevent hammering a failing model service, the memory system implements a circuit breaker:

- **Closed** (normal): requests proceed normally
- **Open** (tripped): after 5 consecutive failures, all requests are short-circuited for 60 seconds
- **Half-open**: after cooldown, one request is allowed through to test recovery

### Retry Logic

Failed extraction and summarization calls use exponential backoff:

- Delays: 1s, 2s, 4s
- Max retries: 3
- Timeout: 60 seconds per attempt
- Only retryable errors (network, transient) trigger retries

### Embedding & Vector Search

- Uses **VecturaKit** for hybrid BM25 + vector search
- Embeddings generated by **SwiftEmbedder** (default model: `nomic-embed-text-v1.5`)
- Deterministic UUIDs for indexed documents using SHA-256 hashing
- Graceful fallback to SQLite text search when the embedding model is unavailable

---

## Storage

All memory data is stored in a local SQLite database with WAL (Write-Ahead Logging) mode for concurrent read performance.

**Location:** `~/.osaurus/memory/memory.db`

**Configuration:** `~/.osaurus/memory/memory-config.json`

The database schema is versioned with automatic migrations. Indexes are maintained on agent ID, status, temporal fields, and conversation IDs for efficient queries.

---

## Managing Memory

### Viewing Memory

Open the Management window (`⌘ Shift M`) → **Memory** to see:

- Your generated **user profile** with version history
- **User overrides** you've added manually
- **Per-agent statistics** showing memory entry counts
- **Processing statistics** (total calls, success rate, average duration)
- **Database size**

### Adding User Overrides

User overrides are explicit facts that always appear in context. Use these for information the AI should never forget:

1. Go to **Memory** → **User Overrides**
2. Click **Add Override**
3. Enter a fact (e.g., "I prefer tabs over spaces" or "My company uses a monorepo")

### Clearing Memory

The Memory view includes a danger zone for clearing all memory data. This removes all entries, summaries, chunks, profile data, and knowledge graph entities. The action is irreversible.

### Syncing

Click **Sync Now** to force-process any pending conversation signals immediately, rather than waiting for the debounce timer.
