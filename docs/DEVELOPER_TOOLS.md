# Developer Tools

Osaurus includes built-in developer tools for debugging, monitoring, and testing your integration. Access them via Settings… (`⌘ ,`).

---

## Insights

**Insights** is the activity log: one row for every interaction Osaurus
performs — local model requests, cloud provider calls, web searches, URL
fetches, MCP tool calls, channel deliveries, Router calls, inbound API
requests, plugin host calls, embeddings, transcriptions, speech synthesis,
media generation — plus chain-of-custody events about the log itself. Each
row is marked **Local** (data stayed on this Mac) or **Cloud** (data left
this Mac), persisted to `~/.osaurus/activity/activity.sqlite`, and chained
with SHA-256 so edits and deletions are detectable.

The reviewer-grade specification (schema, hash recipe, limits, redaction,
threat model, what is *not* captured, offline verification script) is
[ACTIVITY_LOG.md](ACTIVITY_LOG.md). This section covers the developer
workflow.

### Accessing Insights

1. Open Settings… (`⌘ ,`) → **Insights** (also reachable from Privacy →
   Activity Log → *Review Activity in Insights*, and from the per-message
   Insights button in Chat, which focuses that turn's row).
2. Or deep-link: `open "osaurus://settings?tab=insights"`.

### The list

| Column          | Meaning                                                                                     |
| --------------- | ------------------------------------------------------------------------------------------- |
| **Time**        | When the interaction finished. Rows are grouped by day; the day header stays pinned while scrolling. A red dot before the time marks a failed row (orange for a 4xx that was not an error). |
| **Event**       | Category glyph, then the plain-language title (model + tokens, query, destination, media size…) over a secondary line: category · plugin · agent · destination (Cloud rows only) · tools sent. A hand glyph marks rows the Privacy Filter rewrote. |
| **Source**      | Chat UI, Agent, HTTP API, Plugin, P2P, Channel, Schedule, Watcher, Self-scheduled, Tool, System. Hidden while the inspector is open. |
| **Duration**    | Wall time. Token counts and bytes live in the detail.                                      |

Status is deliberately not a column: an `ok` row carries no badge. Failed
rows are the only ones that are tinted.

The glance strip above the list shows **Events**, **Left this Mac** (Cloud
rows and their share), **Failed** and **Privacy-filtered** for the current
filter. The last three are one-tap filters. Beneath it a local/cloud bar and
a **destinations** disclosure list every host that received data (requests,
bytes); clicking a host filters by it.

### Filtering

| Filter              | Where                   | Notes                                                                                          |
| ------------------- | ----------------------- | ---------------------------------------------------------------------------------------------- |
| Text                | Search field            | Path, model, title, destination, agent.                                                        |
| Time range          | Toolbar segmented control | Today, 7 days, 30 days, All time.                                                            |
| Scope               | Scope tab row           | **All**, **Models** (inference, compaction, embedding), **Web** (search, URL fetch), **Tools** (MCP, plugin call, plugin log), **Channels**, **API** (inbound API, Router), **Audio & Media** (transcription, speech, media), **System**. Writes `filter.categories`; an ad-hoc category set from a deep link shows as a token instead. |
| Local / Cloud       | **Filter** popover, or the **Left this Mac** tile |                                                                                  |
| Status              | **Filter** popover, or the **Failed** tile | Any, Succeeded, Failed.                                                                 |
| Source (multi)      | **Filter** popover      |                                                                                                |
| Destination, Model  | **Filter** popover      | Menus of the hosts / models present in the log.                                                |
| Privacy Filter      | **Filter** popover, or the **Privacy-filtered** tile | Any, only filtered, only unfiltered.                                       |
| Plugin console logs | **Filter** popover      | Hidden by default.                                                                             |

Every active criterion (other than the visible search and time range)
appears as a removable token under the toolbar; the **Filter** button badge
counts them and **Clear all** resets everything. Filters apply to the list,
the glance strip and **Export**.

### Detail

Click a row. When the content area is at least 1040 pt wide the detail opens
as a side inspector next to the list (rows can be clicked through; ↑/↓ move
the selection; Escape or × closes). Narrower windows push the detail
full-width with a **Back** button.

- **Overview** — a facts grid (model, tokens, tok/s, finish, bytes sent /
  received, destination, whether content was stored), one plain-language
  sentence, the category section (search providers and result count, MCP
  transport and arguments, channel outcome, embedding counts, audio seconds,
  voice and trigger, media size / steps / job, or the chain-of-custody facts
  for System rows), then collapsible groups each summarised in one line while
  closed: **Where it went** (open by default for Cloud rows: destination,
  host, endpoint, transport, data classes, privacy-filter result), **Who
  drove this** (source, agent, session, turn, delegated-from turn, request
  id, access key), **Generation settings** (temperature, max tokens, finish
  reason, connection, tool calls) and **Integrity** (`seq`, hash, previous
  hash). Long identifiers are shortened to `XXXXXXXX…XXXX`; click to copy,
  hover for the full value. An error, when present, is shown first.
- **Prompt** — the parsed chat messages and tool definitions (chat-shaped
  rows only).
- **Raw** — the request and response bodies (formatted JSON when possible)
  behind a Request / Response toggle. For remote inference the **Server /
  Local** sub-toggle shows the exact bytes captured by `WireTransportProbe`
  (post-Privacy-Filter on the way out, pre-unscrub on the way in) next to
  what the local caller sent. **Copy** in the header lists every captured
  body.
- Rows written while *Store Prompts and Responses* was off show
  `[content withheld — metadata only]` instead of bodies.

### Verify and Export

**Export** is the header's primary action; **Verify Integrity** and **Clear
Activity Log…** live in the **⋯** menu beside it.

- **Verify Integrity** walks the whole chain and reports record count, head
  hash and any broken link / gap / edit / head mismatch in a banner above
  the glance strip. The check is itself recorded as a System row.
- **Export** writes the current filter (or everything) as JSONL (manifest
  line + one canonical record per line — re-verifiable offline, see
  [ACTIVITY_LOG.md §7](ACTIVITY_LOG.md#7-export-format-and-offline-verification)),
  CSV, or Markdown; with or without message content. The export is recorded
  as a System row (format, record count, file name, head hash).
- **Clear Activity Log…** removes every row, moves the chain anchor and
  writes a `cleared` System row, so the log still verifies and the clearing
  is visible.

### Settings

Privacy → **Activity Log**: *Keep Activity History* (7 / 30 / 90 days,
1 year, forever; default 30 days) and *Store Prompts and Responses*
(default on). Changing either writes a `settings_changed` System row.

### Use cases

- **"Did this leave my Mac?"** — click the **Left this Mac** tile; the
  destinations disclosure under the glance strip lists every host and the
  bytes sent.
- **Debugging an API integration** — Filter → source **HTTP API** (or the
  **API** scope), open the row, switch to **Raw** and compare Request /
  Response.
- **Verifying the Privacy Filter** — open a Cloud inference row → Request →
  **Server Request**; placeholders should appear where PII was.
- **Tracing a delegated run** — the parent turn and every subagent / helper
  step share one `turnId`; search by the agent name.
- **Hidden model work** — rows with `/internal/...` paths are one-shots
  (chat titles, follow-ups, memory distillation, compaction, transcription
  cleanup, embeddings).

### Not captured

Provider `/models` and test-connection probes, OAuth flows, MCP capability
probes, Browser Use page traffic, channel polling / inbound receipt,
workspace handshake and keep-alives, theme fetches, skill / plugin / sandbox
downloads, telemetry, crash reports, updates and model downloads do not
produce rows. The full list and rationale: [ACTIVITY_LOG.md §9](ACTIVITY_LOG.md#9-what-is-not-captured).

---

## Server Explorer

The **Server** tab provides an interactive API reference and testing interface.

### Accessing Server Explorer

1. Open Settings… (`⌘ ,`)
2. Click **Server** in the sidebar

### Features

#### Server Status

View current server state:

| Info           | Description                      |
| -------------- | -------------------------------- |
| **Server URL** | Base URL for API requests        |
| **Status**     | Running, Stopped, Starting, etc. |

Copy the server URL with one click for use in your applications.

#### API Endpoint Catalog

Browse all available endpoints, organized by category:

| Category  | Endpoints                                              |
| --------- | ------------------------------------------------------ |
| **Core**  | `/`, `/health`, `/models`, `/tags`                     |
| **Chat**  | `/chat/completions`, `/chat`, `/messages`, `/responses` |
| **Audio** | `/audio/transcriptions`                                |
| **MCP**   | `/mcp/health`, `/mcp/tools`, `/mcp/call`               |

The MCP endpoints are Osaurus's local HTTP MCP surface. Command-based stdio clients should launch `osaurus mcp`, which proxies to these endpoints.

Each endpoint shows:

- HTTP method (GET/POST)
- Path
- Compatibility badge (OpenAI, Ollama, Anthropic, Open Responses, MCP)
- Description

#### Interactive Testing

Test any endpoint directly:

1. Click an endpoint row to expand it
2. For POST requests, edit the JSON payload
3. Click **Send Request**
4. View the formatted response

**Request Panel (left):**

- Editable JSON payload for POST requests
- Request preview for GET requests
- Reset button to restore default payload
- Send Request button

**Response Panel (right):**

- Formatted response body
- Status code badge
- Response duration
- Copy button
- Clear button

#### Documentation Link

Quick access to the full documentation at docs.osaurus.ai.

### Use Cases

- **API exploration** — Discover available endpoints
- **Quick testing** — Test endpoints without external tools
- **Payload experimentation** — Try different request formats
- **Response inspection** — See formatted API responses

---

## Workflow Examples

### Debugging a Chat Integration

1. Open **Insights**
2. Send a request from your application
3. Find the request in the log (filter by path if needed)
4. Expand to see request/response details
5. Check for errors in the response
6. If using tools, inspect tool call details

### Testing Tool Calling

1. Open **Server Explorer**
2. Expand `/chat/completions`
3. Modify the payload to include tools:

```json
{
  "model": "foundation",
  "messages": [{ "role": "user", "content": "What time is it?" }],
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "current_time",
        "description": "Get the current time"
      }
    }
  ]
}
```

4. Click **Send Request**
5. Observe the tool call in the response
6. Check **Insights** for the full request flow

### Monitoring Performance

1. Open **Insights**
2. Run your test workload
3. Observe:
   - Avg Time (should be consistent)
   - Success rate (should be high)
   - Avg Speed for inference (tok/s)
4. Expand slow requests to investigate

### Verifying MCP Tools

1. Open **Server Explorer**
2. Expand `GET /mcp/tools`
3. Click **Send Request**
4. Verify your expected tools are listed
5. Test a specific tool with `POST /mcp/call`

This verifies Osaurus's local MCP server surface, including tools discovered from connected URL-based Remote MCP Providers. It does not launch or inspect third-party stdio providers configured with `command` and `args`; those are outside the Remote MCP Providers transport supported by the current app.

---

## Tips

### Let retention do the clearing

The Insights log is pruned automatically by the Privacy → Activity Log
retention setting (30 days by default). **Clear** is an audited action — it
writes a chain-of-custody row — so prefer a filter (time range, source) when
you just want a quieter view while debugging.

### Use Source Filters

Filter by source to distinguish between:

- **Chat UI** — Requests from the built-in chat UI
- **Agent** — Delegated subagents and helper loops (Computer Use, AppleScript)
- **HTTP API** — Requests from external applications
- **Schedule / Watcher / Self-scheduled / Channel** — Headless runs
- **Tool** — Egress performed by a tool (search, URL fetch, MCP, channel delivery)

### Copy Responses

Use the copy button to quickly grab response payloads for debugging in other tools.

### Keep Server Running

The Server Explorer requires the server to be running. If endpoints show as disabled, start the server first.

---

## CI testing conventions

How CI runs the Osaurus test suite, and the hooks that exist to debug it when it goes sideways.

### Reproduce CI locally

The Makefile target `make ci-test` runs the exact `xcodebuild` flags CI uses, piped through `xcbeautify`, and writes a result bundle:

```bash
brew install xcbeautify    # one-time
make ci-test
open build/Tests.xcresult  # full Xcode Test Navigator UI
```

If a test fails on CI but you can't reproduce it on your machine, download the `test-core-xcresult-*` artifact attached to the failed CI run and open it the same way.

### Long-running and integration tests

Tests that require external infrastructure (Apple Containerization, real GPU, network, etc.) must:

1. **Be opt-in via an environment variable** — never run unconditionally in CI.
2. **Use Swift Testing's `.disabled(if:)` trait** at the suite level so they're reported as `Disabled` (not silently passing). Pattern:

   ```swift
   private let isEnabled =
       ProcessInfo.processInfo.environment["OSAURUS_RUN_FOO_TESTS"] == "1"

   @Suite(.disabled(if: !isEnabled, "Set OSAURUS_RUN_FOO_TESTS=1 to run"))
   struct FooIntegrationTests { … }
   ```

3. **Keep individual test bodies under ~250ms of `Task.sleep`** and prefer event-driven waits (continuations, `AsyncStream`) for everything else.

Currently env-gated:

| Env var                                  | Suite                                                                                    | Notes                                            |
| ---------------------------------------- | ---------------------------------------------------------------------------------------- | ------------------------------------------------ |
| `OSAURUS_RUN_SANDBOX_INTEGRATION_TESTS=1` | [`SandboxIntegrationTests`](../Packages/OsaurusCore/Tests/Sandbox/SandboxIntegrationTests.swift) | Boots a Linux VM; runs `pip`/`npm`/`go` workloads. |

### Document runtime discovery

Structured document parsing runs in-process for the built-in CSV/TSV, XLSX,
PPTX/POTX, PDF, and rich-document adapters. PPTX/POTX slide tables are
preserved from DrawingML table markup; PDF table extraction uses the text-layer
glyph geometry already exposed by PDFKit. Neither path adds OCR or a third-party
PDF engine. The optional office runtime
detector exists only to discover a local LibreOffice/OpenOffice-compatible
`soffice` binary for future conversion flows; it probes version metadata and
never sends document bytes to the runtime.

Set either variable to point tests or local builds at a specific executable:

| Env var | Purpose |
| ------- | ------- |
| `OSAURUS_OFFICE_RUNTIME_URL` | File URL for an explicit `soffice` executable. |
| `OSAURUS_OFFICE_RUNTIME_PATH` | File-system path for an explicit `soffice` executable. |

### CI cache controls

The `test-core` job caches `~/Library/Developer/Xcode/DerivedData` keyed on Swift sources, manifests, resources, the pinned Xcode version, and a manual `CACHE_SALT`. Two recovery levers when you suspect a bad cache:

1. **One-shot cold build**: trigger CI manually via the **Run workflow** button on the [CI workflow](../.github/workflows/ci.yml) page and check `clear_cache`. Skips the restore for that one run.
2. **Permanent bust**: change `CACHE_SALT` (currently `v2-vmlx-5b84387`) at the top of `.github/workflows/ci.yml` and merge. Every cache key invalidates immediately.

The cache only **saves** on `main` pushes — PRs read from it but never overwrite, so a half-baked branch can't poison everyone.

### Where the logs live

The full xcodebuild output is collapsed into expandable groups by `xcbeautify`. On a failure CI also publishes:

- A short failure summary (failed tests + assertion messages) at the top of the GitHub Actions run page.
- The raw `Tests.xcresult` bundle as a downloadable artifact (`test-core-xcresult-N`, 7 days retention).

A passing run produces ~1–2k log lines instead of the historical ~30k, and individual tests that hang are killed in ~2 min by `-test-timeouts-enabled YES` (default 60s, max 120s per test). The whole `test-core` job is capped at 45 minutes via `timeout-minutes`.

### Deferred follow-up

Test wall-time is now bounded by the build-from-scratch cost of the full `OsaurusCore` package. The biggest remaining lever is splitting `OsaurusCore` into focused SPM targets (`OsaurusFoundation`, `OsaurusInference`, `OsaurusVoice`, `OsaurusUpdater`, `OsaurusSandbox`, `OsaurusUI`) so a Foundation-only PR doesn't rebuild MLX / FluidAudio / Sparkle / VecturaKit. File-coupling counts that justify the split:

- MLX/MLXLLM/MLXVLM/MLXLMCommon/Tokenizers: ~10 files, all in `Services/ModelRuntime*`, `Managers/Model/ModelManager.swift`, `Models/Configuration/VLMDetection.swift`, `Utils/StreamingDeltaProcessor.swift`, `Views/Chat/ChatView.swift`.
- `FluidAudio`: 2 files (`Managers/SpeechService.swift`, `Managers/Model/SpeechModelManager.swift`).
- `Sparkle`: 1 file (`Services/UpdaterService.swift`).
- `AAInfographics`: 1 file (`Views/Chat/NativeChartView.swift`).
- `VecturaKit`: 7 files in `Services/{Memory,Method,Skill,Tool}/*`.
- `Containerization`: 1 file (`Services/Sandbox/SandboxManager.swift`).
- `P256K`, `Highlightr`, `SwiftMath`: 1 file each.

Yet **64 of 70 test files use `@testable import OsaurusCore`**, so even tiny tests rebuild the heavy graph today. The one boundary leak that needs cleaning before the split: `Models/Configuration/VLMDetection.swift` imports `MLXVLM` from the otherwise-pure `Models/` tree.

---

## Related Documentation

- [Activity Log specification](ACTIVITY_LOG.md) — Schema, hash chain, limits, threat model, offline verification
- [Inference Runtime](INFERENCE_RUNTIME.md) — Single MLX path through vmlx-swift's BatchEngine, model leases, and the one max-batch-size knob
- [OpenAI API Guide](OpenAI_API_GUIDE.md) — API usage and examples
- [FEATURES.md](FEATURES.md) — Feature inventory
- [README](../README.md) — Quick start guide
