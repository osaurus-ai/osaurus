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
│  Structured recaps of past sessions (topics, decisions,          │
│  key dates, action items), generated after inactivity.           │
├──────────────────────────────────────────────────────────────────┤
│  Layer 4: Conversation Chunks                                    │
│  Raw conversation turns indexed for query-matched retrieval.     │
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

Structured recaps of past conversation sessions. Summaries are generated automatically using a debounced approach:

- A timer starts after the last conversation turn (default: 60 seconds)
- If no new messages arrive within the debounce window, a summary is generated
- Session changes (switching to a different conversation) also trigger summary generation
- On startup, any orphaned pending signals from a previous session are recovered and processed

Each summary uses a structured format capturing:

- **Topics** discussed
- **Decisions** made
- **Key dates** or deadlines mentioned
- **Action items** or commitments
- A brief **overall summary**

### Layer 4: Conversation Chunks

Raw conversation turns stored individually and indexed for query-matched retrieval. Each chunk records:

- The conversation ID and chunk index
- The role (user or assistant) and full content
- Token count and timestamp
- The agent ID and optional conversation title

Chunks are not dumped into context wholesale. At query time, only semantically relevant chunks are retrieved via hybrid search (BM25 + vector), reranked with MMR, and included within a token budget. Adjacent turns are loaded via window expansion to preserve conversational flow. This layer acts as a lossless fallback for details the extraction pipeline may have missed.

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
| Conversations | Conversation chunks (Layer 4) | All time (query-aware retrieval) |
| Summaries | Conversation summaries (Layer 3) | Retention window (default: 180 days) |
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

Before each AI interaction, the `MemoryContextAssembler` builds a memory block that is injected into the system prompt. The block always begins with the current date so the model can reason about time relative to stored memories.

Context is assembled in priority order with per-section token budgets:

| Priority | Section | Default Budget |
|----------|---------|---------------|
| 0 | Current Date | Always included (temporal anchor) |
| 1 | User Overrides | Always included (no budget limit) |
| 2 | User Profile | 2,000 tokens |
| 3 | Working Memory | 3,000 tokens |
| 4 | Conversation Summaries | 3,000 tokens |
| 5 | Key Relationships | 300 tokens |

When a user query is provided, an additional **query-aware retrieval** pass runs in parallel, searching entries, summaries, and conversation chunks for semantically relevant results. These are deduplicated against the base context and appended as "Relevant Memories", "Relevant Summaries", and "Relevant Conversation Excerpts" sections with their own budgets:

| Section | Default Budget |
|---------|---------------|
| Relevant Conversation Excerpts | 3,000 tokens |
| Relevant Memories | 3,000 tokens |
| Relevant Summaries | 3,000 tokens |

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
| `workingMemoryBudgetTokens` | 3,000 | 50 -- 10,000 | Token budget for working memory in context |
| `summaryBudgetTokens` | 3,000 | 50 -- 10,000 | Token budget for summaries in context |
| `chunkBudgetTokens` | 3,000 | 50 -- 20,000 | Token budget for conversation chunk excerpts in context |
| `graphBudgetTokens` | 300 | 50 -- 5,000 | Token budget for knowledge graph in context |

### Profile

| Setting | Default | Range | Description |
|---------|---------|-------|-------------|
| `profileRegenerateThreshold` | 10 | 1 -- 100 | New contributions before profile regeneration |

### Summaries

| Setting | Default | Range | Description |
|---------|---------|-------|-------------|
| `summaryDebounceSeconds` | 60 | 10 -- 3,600 | Inactivity period before summary generation |
| `summaryRetentionDays` | 180 | 0 -- 3,650 | How long summaries are retained (0 = unlimited) |

### Search

| Setting | Default | Range | Description |
|---------|---------|-------|-------------|
| `recallTopK` | 30 | 1 -- 100 | Number of results for recall searches |
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

**Location:** `~/.osaurus/memory/memory.sqlite`

**Configuration:** `~/.osaurus/config/memory.json`

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

---

## API Integration

Osaurus exposes its memory system through the HTTP API, enabling any OpenAI-compatible client to benefit from persistent, personalized context.

### Memory Context Injection — `X-Osaurus-Agent-Id`

Add the `X-Osaurus-Agent-Id` header to any `POST /chat/completions` request. Osaurus will automatically assemble relevant memory (user profile, working memory, conversation summaries, knowledge graph) and prepend it to the system prompt before the request reaches the model.

The header value is an arbitrary string that identifies the agent or user session whose memory should be retrieved. When the header is absent or empty, the request is processed normally without memory injection.

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://127.0.0.1:1337/v1",
    api_key="osaurus",
    default_headers={"X-Osaurus-Agent-Id": "my-agent"},
)

response = client.chat.completions.create(
    model="your-model-name",
    messages=[{"role": "user", "content": "What did we talk about last time?"}],
)
```

### Memory Ingestion — `POST /memory/ingest`

Bulk-ingest conversation turns so the memory system can learn from them. This is useful for seeding memory from existing chat logs, migrating from another system, or running benchmarks.

```bash
curl http://127.0.0.1:1337/memory/ingest \
  -H "Content-Type: application/json" \
  -d '{
    "agent_id": "my-agent",
    "conversation_id": "session-1",
    "turns": [
      {"user": "Hi, my name is Alice", "assistant": "Hello Alice! Nice to meet you."},
      {"user": "I work at Acme Corp", "assistant": "Got it, you work at Acme Corp."}
    ]
  }'
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `agent_id` | string | Identifier for the agent whose memory is being populated |
| `conversation_id` | string | Identifier for the conversation session |
| `turns` | array | Array of turn objects, each with `user` and `assistant` fields |

Memory extraction runs asynchronously in the background — ingested turns are processed without blocking the API response.

### List Agents — `GET /agents`

Returns all configured agents with their memory entry counts. Use this to discover valid agent IDs for the `X-Osaurus-Agent-Id` header.

```bash
curl http://127.0.0.1:1337/agents
```

See the [API Guide](OpenAI_API_GUIDE.md#memory-api) for additional examples and reference.

---

## Benchmark: LoCoMo (Long-term Conversational Memory)

We evaluate memory quality using the [LoCoMo benchmark](https://arxiv.org/abs/2401.15665) (ACL 2024) via [EasyLocomo](https://github.com/playeriv65/EasyLocomo). LoCoMo tests how well systems recall facts, events, and relationships from multi-session conversations spanning weeks to months.

Our goal is to achieve state-of-the-art on this benchmark. Osaurus uses Apple Foundation Models as the base memory extraction model, making the cost of memory effectively zero for on-device use.

### LoCoMo Leaderboard

| System | F1 Score |
|--------|----------|
| MemU | 92.09% |
| CORE | 88.24% |
| Human baseline | ~88% |
| Memobase | 85% (temporal) |
| Mem0 | 66.9% |
| **Osaurus (Gemini 2.5 Flash)** | **57.08%** |
| OpenAI Memory | 52.9% |
| GPT-3.5-turbo-16K (no memory) | 37.8% |
| GPT-4-turbo (no memory) | ~32% |

### Osaurus Breakdown by Category

| Category | Count | F1 Score |
|----------|-------|----------|
| Open-domain | 841 | 61.44% |
| Adversarial | 446 | 90.36% |
| Multi-hop | 282 | 41.94% |
| Temporal | 321 | 23.16% |
| Single-hop | 96 | 22.10% |
| **Overall** | **1,986** | **57.08%** |

### Running the Benchmark

```bash
# 1. Set up EasyLocomo (clones repo, applies patch, creates venv)
make bench-setup

# 2. Configure .env in benchmarks/EasyLocomo/
echo 'OPENAI_API_KEY=osaurus' > benchmarks/EasyLocomo/.env
echo 'OPENAI_API_BASE=http://localhost:1337/v1' >> benchmarks/EasyLocomo/.env

# 3. Ingest LoCoMo data (full extraction — takes several hours, only needed once)
make bench-ingest

# 4. Fast chunk re-ingestion (no LLM calls — use after code changes)
make bench-ingest-chunks

# 5. Run evaluation
make bench-run
```

You may want to temporarily increase token budgets in the memory configuration file (`~/.osaurus/config/memory.json`) before running benchmarks. The default production budgets are tuned for everyday use, not maximal recall.

### Memory-Augmented Evaluation

Osaurus uses a no-context evaluation mode where the LLM receives no conversation transcript — only the memory context assembled by the retrieval system. The `X-Osaurus-Agent-Id` header routes each question to the correct agent's memory store. This tests pure memory retrieval quality rather than full-context recall.

---

### Clearing Memory

The Memory view includes a danger zone for clearing all memory data. This removes all entries, summaries, chunks, profile data, and knowledge graph entities. The action is irreversible.

### Syncing

Click **Sync Now** to force-process any pending conversation signals immediately, rather than waiting for the debounce timer.
