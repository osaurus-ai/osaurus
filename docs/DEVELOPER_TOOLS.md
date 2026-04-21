# Developer Tools

Osaurus includes built-in developer tools for debugging, monitoring, and testing your integration. Access them via the Management window (`⌘ Shift M`).

---

## Insights

The **Insights** tab provides real-time monitoring of all API requests flowing through Osaurus.

### Accessing Insights

1. Open the Management window (`⌘ Shift M`)
2. Click **Insights** in the sidebar

### Features

#### Request Logging

Every API request is logged with:

| Field        | Description                 |
| ------------ | --------------------------- |
| **Time**     | Request timestamp           |
| **Source**   | Origin: Chat UI or HTTP API |
| **Method**   | HTTP method (GET/POST)      |
| **Path**     | Request endpoint            |
| **Status**   | HTTP status code            |
| **Duration** | Total response time         |

Click any row to expand and see full request/response details.

#### Filtering

Filter requests to find what you need:

| Filter     | Options                      |
| ---------- | ---------------------------- |
| **Search** | Filter by path or model name |
| **Method** | All, GET only, POST only     |
| **Source** | All, Chat UI, HTTP API       |

#### Aggregate Stats

The stats bar shows real-time metrics:

| Stat           | Description                           |
| -------------- | ------------------------------------- |
| **Requests**   | Total request count                   |
| **Success**    | Success rate percentage               |
| **Avg Time**   | Average response duration             |
| **Errors**     | Total error count                     |
| **Inferences** | Chat completion requests (if any)     |
| **Avg Speed**  | Average tokens/second (for inference) |

#### Request Details

Expand a request row to see:

**Request Panel:**

- Full request body (formatted JSON)
- Copy to clipboard

**Response Panel:**

- Full response body (formatted JSON)
- Status indicator (green for success, red for error)
- Response duration
- Copy to clipboard

**Inference Details** (for chat completions):

- Model used
- Token counts (input → output)
- Generation speed (tok/s)
- Temperature
- Max tokens
- Finish reason

**Tool Calls** (if applicable):

- Tool name
- Arguments
- Duration
- Success/error status

### Use Cases

- **Debugging API integration** — See exactly what's being sent and received
- **Performance monitoring** — Track latency and throughput
- **Tool call inspection** — Debug tool calling behavior
- **Error investigation** — Understand why requests fail

---

## Server Explorer

The **Server** tab provides an interactive API reference and testing interface.

### Accessing Server Explorer

1. Open the Management window (`⌘ Shift M`)
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

---

## Tips

### Clear Logs Regularly

The Insights log grows over time. Use the **Clear** button to reset when debugging a specific issue.

### Use Source Filters

Filter by source to distinguish between:

- **Chat** — Requests from the built-in chat UI
- **HTTP** — Requests from external applications

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

### CI cache controls

The `test-core` job caches `~/Library/Developer/Xcode/DerivedData` keyed on Swift sources, manifests, resources, the pinned Xcode version, and a manual `CACHE_SALT`. Two recovery levers when you suspect a bad cache:

1. **One-shot cold build**: trigger CI manually via the **Run workflow** button on the [CI workflow](../.github/workflows/ci.yml) page and check `clear_cache`. Skips the restore for that one run.
2. **Permanent bust**: bump `CACHE_SALT` (currently `v1`) at the top of `.github/workflows/ci.yml` to `v2` and merge. Every cache key invalidates immediately.

The cache only **saves** on `main` pushes — PRs read from it but never overwrite, so a half-baked branch can't poison everyone.

### Where the logs live

The full xcodebuild output is collapsed into expandable groups by `xcbeautify`. On a failure CI also publishes:

- A short failure summary (failed tests + assertion messages) at the top of the GitHub Actions run page.
- The raw `Tests.xcresult` bundle as a downloadable artifact (`test-core-xcresult-N`, 7 days retention).

A passing run produces ~1–2k log lines instead of the historical ~30k, and individual tests that hang are killed in ~2 min by `-test-timeouts-enabled YES` (default 60s, max 120s per test). The whole `test-core` job is also capped at 15 minutes via `timeout-minutes`.

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

- [Inference Runtime](INFERENCE_RUNTIME.md) — Single MLX path through vmlx-swift-lm's BatchEngine, model leases, and the one max-batch-size knob
- [OpenAI API Guide](OpenAI_API_GUIDE.md) — API usage and examples
- [FEATURES.md](FEATURES.md) — Feature inventory
- [README](../README.md) — Quick start guide
