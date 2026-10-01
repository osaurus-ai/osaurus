# Activity Log (Insights) — Reviewer Specification

This document is for someone who has to *trust* the Insights activity log:
a security reviewer, an auditor, a compliance lead, or a developer deciding
whether a row is evidence. It states exactly what Osaurus records, where the
bytes live, how the tamper-evident chain is built, how to re-verify an
export without Osaurus, and — just as importantly — what the log does **not**
capture.

User-facing operation (filters, Verify, Export, retention settings) is in
the in-app guide `Packages/OsaurusCore/Resources/Guide/guide-insights.md`.
The Insights UI itself is described in [DEVELOPER_TOOLS.md](DEVELOPER_TOOLS.md).

---

## 1. Scope

One **row** is one interaction Osaurus performed: a model request, a web
search, a URL fetch, an MCP call, a channel delivery, a Router call, an
inbound API request, a plugin host call, an embedding batch, a
transcription, a speech synthesis, a media generation, or a chain-of-custody
event about the log itself.

Every row carries a **locality**:

| Locality | Meaning                                                                                   |
| -------- | ----------------------------------------------------------------------------------------- |
| `local`  | No request-derived data left this Mac (local model, local MCP stdio server, local STT…). |
| `remote` | Request-derived data crossed the network (cloud provider, hosted search, Slack, Router…). |

Locality is set by the emitter when it knows; otherwise inferred from the
connection (remote inference / remote agent-run mode, Secure Channel or
direct transport) or from an egress destination (`RequestLog.inferLocality`).

---

## 2. Storage

| Item                | Location                                     | Notes                                                                                   |
| ------------------- | -------------------------------------------- | --------------------------------------------------------------------------------------- |
| Database            | `~/.osaurus/activity/activity.sqlite`        | SQLite via `OsaurusStorageOpener` → follows the user's at-rest encryption policy (SQLCipher when storage encryption is on). |
| Chain head sidecar  | `~/.osaurus/activity/activity.head`          | Plain text `"<seq>:<hash>\n"`, written atomically after every append.                   |
| Policy              | `~/.osaurus/config/activity-log.json`        | `retentionDays` (int or null = forever), `storeContent` (bool).                        |

### 2.1 Schema (`PRAGMA user_version = 1`)

```sql
CREATE TABLE activity (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,   -- chain position; never reused
  id TEXT NOT NULL UNIQUE,                 -- RequestLog.id (UUID)
  ts_ms INTEGER NOT NULL,                  -- event time, ms since 1970 (UTC)
  category TEXT NOT NULL, locality TEXT NOT NULL, source TEXT NOT NULL,
  method TEXT NOT NULL, path TEXT NOT NULL, status INTEGER NOT NULL,
  is_error INTEGER NOT NULL DEFAULT 0, duration_ms REAL NOT NULL,
  model TEXT, provider_id TEXT, destination_host TEXT, destination_label TEXT,
  transport TEXT, mode TEXT,
  agent_id TEXT, agent_name TEXT, session_id TEXT, turn_id TEXT, request_id TEXT,
  plugin_id TEXT, access_key_id TEXT, audience TEXT,
  input_tokens INTEGER, output_tokens INTEGER, tokens_per_second REAL,
  bytes_sent INTEGER, bytes_received INTEGER,
  privacy_filter_applied INTEGER NOT NULL DEFAULT 0, redacted_count INTEGER,
  finish_reason TEXT, error_message TEXT, title TEXT NOT NULL,
  payload BLOB NOT NULL,                   -- canonical JSON of the full RequestLog (see §4)
  prev_hash TEXT NOT NULL, hash TEXT NOT NULL
);
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
-- meta rows: anchor_seq, anchor_hash (see §4.3)
```

The indexed columns are a *projection* of the payload for filtering and
aggregation. **The payload is the record.** Verify and Export read the
payload; the columns are never the source of truth.

### 2.2 Write path

Rows are appended **write-behind**: the emitter inserts the row into the
in-memory hot cache synchronously and the chained SQLite append runs on a
utility-priority task. Consequences:

- The Insights list can show a row a few milliseconds before it is on disk.
- A hard crash can lose the last few rows that had not yet been appended;
  it cannot corrupt the chain (appends are single-row transactions and the
  head is written after the insert).
- Row order on disk is append order (`seq`), which can differ from `ts_ms`
  order under concurrency. Verify and Export order by `seq`.

---

## 3. Record model

The payload is `RequestLog` (`Packages/OsaurusCore/Models/Chat/RequestLog.swift`)
encoded as JSON. Field names are the Swift property names (camelCase).
Optional fields are **omitted** when nil.

| Field                               | Type                       | Meaning                                                                                                  |
| ----------------------------------- | -------------------------- | -------------------------------------------------------------------------------------------------------- |
| `id`                                | UUID string                | Row identity.                                                                                            |
| `timestamp`                         | number (ms since 1970)     | When the interaction finished.                                                                           |
| `seq`, `prevHash`, `hash`           | int, hex, hex              | Chain fields (§4). `hash` is absent from the hashed payload.                                             |
| `source`                            | `RequestSource` raw value  | Who drove it: `Chat UI`, `Agent`, `HTTP API`, `Plugin`, `P2P`, `Scheduled`, `Channel`, `Schedule`, `Watcher`, `Self-scheduled`, `Tool`, `System`. |
| `category`                          | `ActivityCategory`         | See §3.1.                                                                                                |
| `locality`                          | `local` / `remote`         | See §1.                                                                                                  |
| `method`, `path`, `statusCode`      | string, string, int        | HTTP-shaped descriptor. Non-HTTP work uses synthetic paths (`/internal/...`, `/search/...`, `/mcp/...`, `/channels/...`, `/activity/...`). |
| `durationMs`                        | number                     | Wall time.                                                                                               |
| `requestBody`, `responseBody`       | string?                    | Prompt / result bodies (clipped and credential-redacted, §5). Absent when the emitter has none; replaced by the withheld marker when content storage is off. |
| `wireRequestBody`, `wireResponseBody` | string?                  | Bytes actually sent / received for remote inference, captured post-Privacy-Filter by `WireTransportProbe`. |
| `model`, `inputTokens`, `outputTokens`, `tokensPerSecond`, `temperature`, `maxTokens`, `finishReason`, `errorMessage` | | Inference facts. |
| `toolCalls[]`                       | `{id, name, arguments, result, durationMs, isError}` | Tool calls made during the turn. Arguments / results are redacted for secret-carrying tools and channel tools. |
| `connection`                        | `RequestConnectionInfo?`   | `providerId`, `remoteEndpoint`, `transport` (`local`/`direct`/`secureChannel`), `mode` (`local`/`remoteInference`/`remoteAgentRun`), `accessKeyId`, `audience`. |
| `egress`                            | `EgressInfo?`              | `destinationLabel`, `destinationHost`, `bytesSent`, `bytesReceived`, `dataClasses[]`, `privacyFilterApplied`, `redactedSpanCount`, `details{}`. |
| `agentId`, `agentName`, `sessionId`, `turnId`, `requestId` | | Attribution. `turnId` links a row to the chat assistant turn (delegated subagent and helper-loop rows inherit the parent turn). |
| `pluginId`, `userAgent`, `clientIP` |                            | Inbound / plugin attribution.                                                                            |

`egress.details` is a flat `String → String` map. The store bounds it to
**32 keys**, key length **64**, value length **2 048** characters
(`ActivityLogStore.boundedDetails`). Emitters use it for category-specific
facts (query, result count, audio seconds, media size…). Keys named
`query`, `urls`, `arguments`, `result_preview`, `message` are treated as
*content* and are withheld when content storage is off.

### 3.1 Categories and emitters

| Category (`rawValue`)  | Rows                                                                                                                                              | Locality                | Emitter                                                                                      |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------- | -------------------------------------------------------------------------------------------- |
| `inference`            | Every chat / agent model request, incl. hidden one-shots (`/internal/chat_title`, `/internal/follow_up_suggestions`, `/internal/memory_distillation`, `/internal/agent_description`, `/internal/transcription_cleanup`). | local or remote         | `ChatEngine`, `HTTPHandler` (API callers), `CoreModelService`, `TranscriptionCleanupService` (MLX fallback, `details.fallback = mlx`). |
| `compaction`           | Context-compaction summary generations (`/internal/compaction`).                                                                                  | local or remote         | `ContextCompactionService`                                                                   |
| `web_search`           | `/search/<category>`; query, providers tried, result count.                                                                                      | remote                  | `SearchProviderManager`                                                                      |
| `url_extract`          | `/contents`; URLs fetched for readability / `search_and_extract`.                                                                                 | remote                  | `SearchReadability`, Router contents                                                         |
| `mcp_tool_call`        | `/mcp/<provider>/<tool>`; arguments, result preview, transport.                                                                                   | local (stdio) / remote  | `MCPProviderManager`                                                                         |
| `channel_delivery`     | `/channels/<connection>/<room>`; method `PUBLISH` (proactive post) or `REPLY` (auto-reply to an inbound message). Metadata only, plus `attachments` data class when files were sent. | remote (iMessage: local) | `ChannelActivityLogger` ← `AgentChannelPublishService`, `AgentChannelInboundRelay`           |
| `router_control`       | Osaurus Router control plane (`/workspaces/...`, `/id/...`, `/v1/media/...`, `/health`).                                                          | remote                  | `OsaurusRouterAPIClient`                                                                     |
| `inbound_api`          | Any inbound HTTP request not classified above (incl. paired-peer requests, which are also egress: the response goes back over the Secure Channel). | local / remote (P2P)    | `HTTPHandler`                                                                                |
| `plugin_call`          | Plugin host API calls.                                                                                                                            | local                   | Plugin host                                                                                  |
| `plugin_log`           | Plugin log lines (hidden by default; **More → Show plugin console logs**).                                                                        | local                   | Plugin host                                                                                  |
| `embedding`            | One row per embedding batch (`/internal/embeddings`, or `/v1/embeddings` / `/api/embed` for API callers). Metadata only: `texts`, `chars`, `dims`, `purpose` (`memory_search`, `memory_index`, `tool_search`, `tool_index`, `skill_search`, `skill_index`, `knowledge_search`, `knowledge_index`, `method_search`, `method_index`, `plugin_embed`; absent for `/v1/embeddings`). | local                   | `MetalSafeEmbedder` (all local embedding funnels through it), `HTTPHandler`                  |
| `audio_transcription`  | Speech-to-text: `/internal/audio_transcription` (`mode` = `live` dictation session or `file`) or `/v1/audio/transcriptions`. Transcript in `responseBody`; `audio_seconds`, `audio_bytes`, `audio_format`, `transcript_chars`. | local                   | `SpeechService`, `HTTPHandler`                                                               |
| `speech_synthesis`     | Text-to-speech: `/internal/speech_synthesis` (local Pocket TTS) or `/v1/audio/speech` (OpenAI-compatible remote TTS). Spoken text in `requestBody`; `voice`, `chars`, `audio_seconds`, `provider`, `trigger` (`read_aloud`, `speak_tool`), `cancelled`. | local or remote         | `TTSService`                                                                                 |
| `media_generation`     | Image / video jobs: `/internal/image_generate` (local MLX), `/v1/images/<op>` / `/v1/videos/<op>` (Venice), `/images/*`, `/videos/*` (API callers). Prompt in `requestBody`; `media_kind`, `operation` (`generate`, `edit`, `upscale`, `quote`), `count`, `size`, `steps`, `provider`/`backend`, `job_id`. Osaurus Cloud media is recorded by its `router_control` row instead. | local or remote         | `NativeImageJobCoordinator`, `MediaGenerationCoordinator`, `HTTPHandler`                     |
| `system`               | Chain-of-custody events (§6). Hidden from the default chip row; **More → Category: System**.                                                      | local                   | `ActivityLogStore`, `InsightsService`, `ActivityExportCoordinator`                           |

**Double-write guard.** When an API caller hits `/v1/embeddings`,
`/v1/audio/transcriptions`, `/v1/images/*` or `/v1/videos/*`, the HTTP
handler writes the row (with the real request/response) and binds
`ChatExecutionContext.currentRequestSource = .httpAPI` for the request task;
the in-process emitters on that path (`MetalSafeEmbedder`, `SpeechService`,
media coordinators) see the binding and stay silent. Chat completions over
HTTP behave the same way (`ChatEngine` skips when the source is HTTP API or
P2P; the handler logs).

**Attribution.** `source` is the producer as shown to the user. Delegated
subagents, Computer Use and AppleScript helper loops are chat-owned for model
residency but are shown as `Agent`. Helper loops that have no turn of their
own inherit the dispatching turn's `turnId`. A `spawn_agent` /
`spawn_batch` helper runs as its own persisted chat session (`.delegation`),
so its rows carry the helper's `sessionId`/`turnId` and record the
orchestrator's turn in `egress.details.parent_turn_id` ("Delegated from
turn" in the detail pane); either way a reviewer can walk parent turn →
every helper step.

---

## 4. Tamper-evident chain

### 4.1 Hash recipe

```
payload  = canonicalJSON(record with seq and prevHash set, hash key absent)
hash     = hex( SHA-256( UTF-8(prevHash) || "\n" || payload ) )
```

`canonicalJSON` is Swift `JSONEncoder` with `.sortedKeys` and
`.withoutEscapingSlashes`, dates as milliseconds since 1970, nil fields
omitted, no whitespace. The genesis `prevHash` is 64 ASCII zeros.

Each row stores `prev_hash` (the previous row's `hash`) and its own `hash`;
`seq` increases by exactly one. The sidecar `activity.head` holds the
latest `(seq, hash)`.

### 4.2 Verify

`ActivityLogStore.verify()` walks every row in `seq` order from the anchor
(§4.3) and reports:

| Problem            | Meaning                                                                        |
| ------------------ | ------------------------------------------------------------------------------ |
| `anchorMismatch`   | First row's `seq` is not `anchor_seq + 1`.                                      |
| `sequenceGap`      | A `seq` was skipped — rows were deleted from the middle.                        |
| `brokenLink`       | `prev_hash` does not equal the previous row's `hash`.                           |
| `hashMismatch`     | Recomputing the row's hash from its payload gives a different value — edited.   |
| `malformedRow`     | Payload does not decode.                                                        |
| `headMismatch`     | Sidecar head disagrees with the database tail — rows removed from the end (or the head file was tampered with). |

A log that passes Verify has not been modified since it was written, *within
the threat model in §8*.

### 4.3 Anchor, retention and clear

Retention pruning and Clear remove rows from the **front** of the chain.
They cannot simply delete, or Verify would fail forever. Instead:

- `meta.anchor_seq` / `meta.anchor_hash` record the `seq` and `hash` of the
  last removed row (initially `0` / genesis). Verify starts from the anchor
  and expects the first surviving row to link to `anchor_hash`.
- Prune deletes the contiguous prefix of rows older than the cutoff and
  advances the anchor to the row just before the first survivor. The
  prune is then recorded as a `system` row (§6).
- Clear deletes every row, advances the anchor to the old tail, and appends
  a `cleared` row — so a cleared log still verifies and the clearing is on
  the record.

Nothing ever rewrites a surviving row.

### 4.4 Head/database disagreement on open

If `activity.head` disagrees with the database tail when the store opens
(crash between insert and head write, restored backup, or tampering),
Osaurus does **not** silently realign. It appends a `recovered` system row
recording `expected_seq` / `expected_hash` (from the head) and
`found_seq` / `found_hash` (from the database), and the chain continues from
the database. The append rewrites the head, so later Verifies pass, but the
discrepancy stays in the chain.

---

## 5. Content limits and redaction

| Rule                                 | Value / behaviour                                                                                                                     |
| ------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------- |
| Body clip                            | `requestBody`, `responseBody`, wire bodies: **262 144 characters** (256 K); longer bodies end with `…[truncated, original N]`.        |
| Detail clip                          | `egress.details`: max **32 keys**, key ≤ 64 chars, value ≤ **2 048** chars.                                                            |
| Credential redaction                 | Applied to every body before it enters the hot cache or the store (`InsightsService.redactCredentials`): Bearer tokens → `Bearer <redacted>`; `sk-…` keys; JWT-shaped values; `attestation` / `wallet_signature` / `caller_attestation` fields; `x-api-key`, `x-goog-api-key`, `api-key`, `authorization` header-style values. |
| Secret tools                         | Arguments of secret-setting tools and all Agent Channel tool arguments / results are replaced with a redaction marker in `toolCalls`. |
| Store Prompts and Responses = off    | New rows persist with bodies, wire bodies, tool arguments / results and content detail keys replaced by `[content withheld — metadata only]`. Metadata, sizes, destinations, model, tokens and tool names are kept. Rows already written are not rewritten. |
| Export without content               | Same marker applied at export time to every row in the file; the manifest says `includesContent: false`.                              |
| Channel deliveries                   | Never store the message text — only destination, room, size, outcome.                                                                 |
| Embeddings                           | Never store the embedded texts — counts and sizes only.                                                                               |

Redaction happens **before** hashing, so what is hashed is what is stored.

---

## 6. Chain-of-custody (`system`) rows

Every operation performed *on* the log is itself a chained row:
`source = System`, `category = system`, `method = SYSTEM`,
`path = /activity/<event>`, `egress.details.event = <event>`.

| `event`            | When                                                  | Details                                                                                                     |
| ------------------ | ----------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `cleared`          | User pressed **Clear**                                | `reason` (`cleared_by_user`), `removed_rows`                                                                |
| `pruned`           | Retention removed rows (startup, every 6 h, on settings change) | `removed_rows`, `cutoff` (ISO-8601 UTC), `anchor_seq` (new anchor)                                 |
| `verified`         | User pressed **Verify**                               | `records`, `problems`, `ok`, `head_seq`, `head_hash`, `problem_summary` (when problems > 0)                 |
| `exported`         | An export file was written                            | `format` (`jsonl`/`csv`/`markdown`), `records`, `include_content`, `filter` (description), `file_name` (leaf only), `head_seq`, `head_hash` (head *before* this row — matches the file's manifest) |
| `settings_changed` | Privacy › Activity Log policy actually changed        | `retention_days` (number or `forever`), `store_content`, `previous_retention_days`, `previous_store_content` |
| `recovered`        | Head/database disagreement at open (§4.4)             | `expected_seq`, `expected_hash`, `found_seq`, `found_hash`                                                  |

`verify()` itself is side-effect free; the UI action records the result.
Tests and exports that call `verify()` directly do not add rows.

---

## 7. Export format and offline verification

### 7.1 JSONL

Line 1 is the manifest; every following line is one record in canonical JSON
(the same encoder as the chain, with the `hash` key included):

```json
{"manifest":{"kind":"osaurus.activity-log","version":1,"exportedAt":"…","appVersion":"…",
  "recordCount":N,"includesContent":true,"filterDescription":"all records",
  "firstSeq":1,"lastSeq":N,"lastHash":"…","chainIntact":true,"chainProblems":[],
  "localCount":…,"remoteCount":…,"bytesSent":…,
  "hashRecipe":"hash = hex(SHA-256(UTF-8(prevHash + \"\n\" + canonicalJSON(record without its hash key)))); …"}}
{"agentName":…,"category":"inference",…,"hash":"…",…,"prevHash":"…",…,"seq":1,…}
```

`chainIntact` / `chainProblems` / `lastHash` describe the **whole store** at
export time, not just the exported subset.

### 7.2 Re-verifying without Osaurus

Because records are written with sorted keys and no whitespace, the hashed
payload is the record line with its `,"hash":"…"` member removed — no
re-serialisation (and no JSON-library canonicalisation differences) needed.

```python
#!/usr/bin/env python3
"""Verify an Osaurus activity-log JSONL export offline.
Usage: verify_activity.py export.jsonl"""
import hashlib, json, re, sys

GENESIS = "0" * 64
path = sys.argv[1]
lines = open(path, "rb").read().split(b"\n")
manifest = json.loads(lines[0])["manifest"]
prev = None
problems = []
count = 0
for raw in lines[1:]:
    if not raw.strip():
        continue
    rec = json.loads(raw)
    seq, claimed, prev_hash = rec["seq"], rec["hash"], rec["prevHash"]
    # Strip the hash member byte-for-byte; keys are sorted so it is never first.
    payload = re.sub(rb',"hash":"[0-9a-f]{64}"', b"", raw, count=1)
    recomputed = hashlib.sha256(prev_hash.encode() + b"\n" + payload).hexdigest()
    if recomputed != claimed:
        problems.append(f"seq {seq}: hash mismatch (row edited)")
    if prev is not None:
        if seq != prev["seq"] + 1:
            problems.append(f"seq {seq}: gap after {prev['seq']}")
        if prev_hash != prev["hash"]:
            problems.append(f"seq {seq}: prevHash does not link to seq {prev['seq']}")
    prev = rec
    count += 1

ok = not problems and count == manifest["recordCount"]
print(f"records={count} manifest.recordCount={manifest['recordCount']} "
      f"lastHash={'match' if prev and prev['hash'] == manifest.get('lastHash') else 'differs (filtered export)'}")
for p in problems:
    print("PROBLEM", p)
sys.exit(0 if ok else 1)
```

Notes for reviewers:

- A **filtered** export is a subset: expect `seq` gaps between kept rows
  (the script reports them) and `lastHash` ≠ the last exported row. Each
  row's own hash still recomputes, and each row's `prevHash` is the hash of
  the row that preceded it in the *store*, which proves the row was part of
  the store's chain at that position.
- A **full** export (`filterDescription: "all records"`) should have no gaps,
  every link intact, and the last row's `hash` equal to `lastHash`.
- Content-withheld exports still verify: the marker was written into the
  row *before* hashing when the policy was off at write time, or the row was
  withheld only in the file (in which case recomputation **will not** match —
  the manifest's `includesContent: false` tells you which case you are in;
  compare against the store or request a with-content export for hash proof).

### 7.3 CSV and Markdown

CSV columns:
`seq, timestamp, category, locality, destination, destination_host, title, source, method, path, status, error, duration_ms, model, agent, input_tokens, output_tokens, bytes_sent, bytes_received, privacy_filter, redacted_spans, data_classes, tool_calls, finish_reason, request_id, turn_id, hash`.
No bodies. Markdown repeats the manifest facts as a header and lists rows
grouped by day. Neither is hash-verifiable on its own; use JSONL for proof.

---

## 8. Threat model

The log is **tamper-evident, not tamper-proof**.

- **Detects:** edits to any stored row, deletion from the middle or the end,
  reordering, and a head file that no longer matches the database — provided
  the attacker did not also recompute every downstream hash *and* rewrite the
  head.
- **Does not defend against:** an attacker with write access to
  `~/.osaurus/activity/` who rewrites the whole chain from the point of
  tampering forward and updates `activity.head` (and `meta.anchor_*`). The
  database is owned by the same user account that runs Osaurus; there is no
  remote anchoring, notarisation, or external timestamping. If you need
  non-repudiation, export regularly and store the manifest `lastHash`
  somewhere the local user cannot change.
- **Clear and prune are legitimate** chain operations. They are visible as
  `system` rows and via the moved anchor; they are not evidence of
  tampering, but a reviewer should treat a `cleared` row the way they would
  treat a log rotation they did not schedule.
- **Content capture is a policy, not a guarantee.** When *Store Prompts and
  Responses* is off, bodies are gone before they reach disk; nothing can
  recover them later. When it is on, bodies are clipped (§5), so a very
  large prompt is only partially on record.
- **Write-behind:** a crash can lose the tail (§2.2). Verify will not flag
  this (nothing inconsistent was written); the gap is simply missing
  evidence.

---

## 9. What is **not** captured

The following cross the network or run a model but do **not** produce an
activity row today. They are listed so a reviewer does not infer "no row =
nothing happened".

Network traffic without rows:

- Remote provider `/models` discovery and **Test connection** probes.
- Provider and MCP OAuth flows (token exchange, refresh).
- MCP server capability probes / tool-list refreshes (only tool *calls* are
  logged).
- Browser Use page loads inside the managed browser (the model steps are
  logged as `inference`; the HTTP the page itself makes is not).
- Agent Channel polling, gateway websockets and inbound message receipt
  (deliveries *out* are logged; reads are not).
- Workspace / Secure Channel handshake, liveness and relay keep-alives.
- Themes API fetches.
- GitHub skill / plugin imports and plugin registry downloads.
- Sandbox package downloads (`pip`, `npm`, `go`) inside the Linux VM.
- Anonymous telemetry, crash reports, app updates (Sparkle) and model
  downloads — separate consent switches under Privacy → Data Collection.

Local work without rows:

- Privacy Filter model inference (the *result* — redacted span count — is
  on the inference row; the filter model run is not its own row).
- Wake-phrase / VAD detection before a dictation session starts.
- Memory distillation *scheduling* (the generation itself is an
  `/internal/memory_distillation` inference row).
- Tool execution that stays on this Mac (file reads, shell, AppleScript,
  Computer Use actions) — the model turns that chose them are logged with
  `toolCalls`; the side effects are not separately logged here (see the
  agent run / file-history surfaces).

---

## 10. Source map

| Concern                                  | File                                                                                   |
| ---------------------------------------- | -------------------------------------------------------------------------------------- |
| Record model, categories, titles         | `Packages/OsaurusCore/Models/Chat/RequestLog.swift`                                    |
| Filters, verification result             | `Packages/OsaurusCore/Models/Insights/ActivityFilter.swift`                            |
| Retention / content policy               | `Packages/OsaurusCore/Models/Insights/ActivityLogSettings.swift`                       |
| Chained store, Verify, prune, clear, custody rows | `Packages/OsaurusCore/Storage/ActivityLogStore.swift`                        |
| Hot cache, emitters' entry points, redaction, write-behind | `Packages/OsaurusCore/Managers/InsightsService.swift`                |
| Media / speech / embedding emitters      | `Packages/OsaurusCore/Services/Insights/MediaActivityLogger.swift`                    |
| Channel delivery emitter                 | `Packages/OsaurusCore/Services/Insights/ChannelActivityLogger.swift`                  |
| Search / MCP emitters                    | `Packages/OsaurusCore/Services/Insights/SearchActivityLogger.swift`, `MCPActivityLogger.swift` |
| Export rendering and manifest            | `Packages/OsaurusCore/Services/Insights/ActivityExportService.swift`                  |
| Export save-panel flow (+ `exported` row) | `Packages/OsaurusCore/Services/Insights/ActivityExportCoordinator.swift`             |
| Wire capture for remote inference        | `Packages/OsaurusCore/Services/Provider/WireTransportProbe.swift`                     |
| UI                                       | `Packages/OsaurusCore/Views/Insights/InsightsView.swift`, `InsightsDetailPane.swift`  |
| Tests                                    | `Packages/OsaurusCore/Tests/Insights/*`                                                |
