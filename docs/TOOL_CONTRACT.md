# Tool Contract

Every Osaurus tool — global built-in, folder tool, sandbox tool — returns a
JSON string in exactly one of two shapes. This page is the one-stop
reference for tool authors.

The type lives at [`Tools/ToolEnvelope.swift`](../Packages/OsaurusCore/Tools/ToolEnvelope.swift).

---

## Success envelope

```json
{
  "ok": true,
  "tool": "sandbox_write_file",
  "result": { "path": "/home/agent/foo.txt", "size": 123 },
  "warnings": ["slow disk"]
}
```

- `ok`: always `true`.
- `tool`: optional — the tool name. Populated automatically by the helpers.
- `result`: the tool's payload. Object, array, string, number, bool, or null.
- `warnings`: optional list of non-fatal notes the model should read.

### `text` convenience

Tools whose primary output is a single human-readable string (folder tools,
capability listings, search-memory hits, `todo`/`complete`/`clarify`) use:

```swift
return ToolEnvelope.success(tool: name, text: "Found 3 matches\n...")
```

which is sugar for `result: { "text": "..." }`. The chat UI's tool-call
card detects this pattern and renders the text verbatim as markdown
instead of a JSON code block.

## Failure envelope

```json
{
  "ok": false,
  "kind": "invalid_args",
  "message": "Missing required argument `content` (string).",
  "field": "content",
  "expected": "non-empty string of file contents",
  "tool": "sandbox_write_file",
  "retryable": true
}
```

- `ok`: always `false`.
- `kind`: classification — see the table below.
- `message`: human- and model-readable explanation.
- `field`: optional — the offending argument name when `kind` is `invalid_args`.
- `expected`: optional — what the argument should look like (example form).
- `tool`: optional — the tool name. Populated automatically.
- `retryable`: whether a retry might succeed. Defaulted by kind.

### Kinds

| `kind`             | meaning                                                        | default `retryable` |
| ------------------ | -------------------------------------------------------------- | ------------------- |
| `invalid_args`     | argument missing, malformed, or scope-incompatible             | `true`              |
| `rejected`         | blocked by configured policy                                   | `false`             |
| `user_denied`      | user clicked Deny on an interactive approval                   | `false`             |
| `timeout`          | tool ran past its time budget                                  | `true`              |
| `execution_error`  | tool ran but failed (process exited non-zero, file missing...) | `true`              |
| `unavailable`      | tool exists but can't run right now (sandbox booting, etc.)    | `true`              |
| `tool_not_found`   | model called a tool the registry doesn't have                  | `false`             |

---

## Detection

Code paths that need to distinguish success from failure without parsing
the whole envelope use:

```swift
ToolEnvelope.isError(resultString)     // true for failure envelopes + legacy prefixes
ToolEnvelope.isSuccess(resultString)   // symmetric
ToolEnvelope.successPayload(result)    // returns the `result` dict for a success
ToolEnvelope.failureMessage(result)    // returns `message` (falls back to the input)
```

These also recognise the legacy `[REJECTED]` / `[TIMEOUT]` prefixes and the
legacy `ToolErrorEnvelope` JSON shape so partial migrations don't
mis-classify.

---

## Writing a tool

Use the `require…` helpers on `OsaurusTool` to build failure envelopes
with the right `field` / `expected` automatically:

```swift
func execute(argumentsJSON: String) async throws -> String {
    let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
    guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

    let pathReq = requireString(
        args, "path",
        expected: "relative path under the agent home",
        tool: name
    )
    guard case .value(let path) = pathReq else { return pathReq.failureEnvelope ?? "" }

    // ... do work ...
    return ToolEnvelope.success(tool: name, result: ["path": path, "size": 123])
}
```

Sandbox tools have `requirePath(_:home:tool:)` on top that routes through
`SandboxPathSanitizer` and turns a rejection into an `invalid_args`
envelope with the specific reason (path traversal, dangerous character,
outside allowed roots, etc.).

### Thrown errors

Tool bodies that throw (folder tools, for historical reasons) have the
exception mapped to the envelope at the catch site via
`ToolEnvelope.fromError(_:tool:)`. That helper understands
`FolderToolError`, `ToolRegistry` permission `NSError` codes, and any
other `Error` (falls through to `execution_error`).

### Schema

Add `"additionalProperties": .bool(false)` to every new tool's top-level
schema. `SchemaValidator` enforces it at `ToolRegistry.execute` time and
emits `invalid_args` with `field: <offending-key>` for the model.

Scalar types are intentionally lenient: `integer`, `number`, and
`boolean` properties accept native JSON values *and* string-encoded
equivalents (`"15"`, `"3.14"`, `"true"`/`"yes"`/`"1"`). `array`
properties additionally accept a string that JSON-decodes to an array
(`"[\"a\",\"b\"]"`). This matches the tool-side `ArgumentCoercion`
helpers so local models that emit slightly off types don't bounce on
the preflight when the body would coerce anyway. `string`, `object`,
and `enum` checks remain strict, and `array` still rejects bare
non-array strings so the model gets a clear signal.

Prefer:

- `enum` for closed-set values (`chartType`, `scope`, `language`, ...).
- `default` declared in the schema for any default the implementation uses.
- Concrete examples in `description` strings.

### Special-case markers (artifact, chart)

`share_artifact` and `render_chart` carry marker-delimited blobs
(`---SHARED_ARTIFACT_START---` / `---CHART_START---`) because the chat UI
is tightly coupled to those parsers. The markers ride inside the
envelope's `result.text` string — downstream parsers extract `text` from
the envelope first, then scan for markers. Prefer not to add new
marker-based flows; treat them as legacy.

### `share_artifact` failure envelopes

The chat-layer wrapper differentiates four failure modes for
`share_artifact` so the model can self-correct on the next turn instead
of retrying the same path. Each maps to a specific `ToolEnvelope.failure`
shape:

- **Path rejected** (`pathRejected`) → `kind: invalid_args`, `field: "path"`,
  message names the trusted root and suggests `sandbox_search_files`.
- **File not found** (`fileNotFound`) → `kind: execution_error`, message
  enumerates every candidate path the resolver tried (e.g. `<home>/foo.png`,
  `<home>/output/foo.png`, `<home>/dist/foo.png`, …) so the model knows
  exactly where to look next.
- **Copy failed** (`copyFailed`) → `kind: execution_error`, message carries
  the FS error string (disk full, perms) plus the source path.
- **Filename rejected** (`destinationRejected`) → `kind: invalid_args`,
  `field: "filename"`, asks for a plain basename.

Empty-string filler in optional fields (`content: ""`, `filename: ""`) is
treated as absent on entry — many models pass empty placeholders for
unused fields, and rejecting that as `invalid_args` was a footgun.

### `sandbox_exec` background flag

Foreground (default): returns `{stdout, stderr, exit_code, cwd}` when the
command finishes. **No built-in wall-clock timeout** — long-running
commands run to completion. Pass `timeout: <seconds>` to set a hard
idle ceiling (kill if no output for N seconds). The user's
`[Terminate]` button on the chat tool-call card is the primary control;
when pressed, the result envelope additionally carries
`killed_by: "user"` so the model can branch on it.

Pass `background:true` to spawn a detached process — the tool returns
`{pid, log_file, cwd, background:true}` as soon as the spawn shim
returns. The chat card still streams the live tail of the log file, and
the `[Terminate]` button still works (signals SIGTERM via
`execAsRoot kill -TERM <pid>`). Manage the resulting job through
`sandbox_process` (poll/wait/kill).

### Streaming-aware tools

Tools that drive long-running shell commands (`sandbox_exec`,
`shell_run`) opt out of the registry's 120 s wall-clock race via
`var bypassRegistryTimeout: Bool { true }` on `OsaurusTool`. They have
no usable wall-clock budget — a `cargo build` legitimately runs for
30+ minutes — and rely on:

1. The user's `[Terminate]` button (sends SIGTERM, then SIGKILL after a
   3 s grace; surfaces `killed_by: "user"` in the result envelope).
2. The optional `timeout` arg (idle ceiling; resets on every byte of
   output).
3. Container CPU / memory limits + per-turn command count.

Other tools keep the 120 s safety net unchanged.

### Pipefail by default

`sandbox_exec` and `shell_run` wrap the model's command in
`set -o pipefail; ...` so a real upstream pipeline failure surfaces as
the rightmost non-zero exit instead of being masked by `head` / `tee`.
SIGPIPE (exit 141) is treated as a benign soft warning — common and
expected for `cmd | head -n N` patterns.

The same path adds an empty-output warning when
`exit_code == 0 && stdout.isEmpty && stderr.isEmpty` AND the command
contained `|` or `2>/dev/null`. Tool authors writing wrappers around
shell exec should follow the same pattern (see
`diagnosticWarnings(...)` in `BuiltinSandboxTools.swift`) so the model
sees the same vocabulary regardless of which tool ran the pipeline.

---

## Resilience checklist for tool authors

Quantized models routinely emit slightly off shapes — string-encoded
integers (`"timeout": "15"`), JSON-encoded arrays
(`"packages": "[\"a\",\"b\"]"`), empty-string fillers for unused
optional fields (`"description": ""`), and mixed-case enums
(`"scope": "Pinned"`). The platform handles every one of these at the
preflight layer ([`SchemaValidator.coerceArguments`](../Packages/OsaurusCore/Tools/SchemaValidator.swift)
+ `validate`) before your tool body sees the arguments. To stay
inside that contract:

- Use the `requireXxx` helpers — `requireArgumentsDictionary`,
  `requireString`, `requireStringArray`, `requireInt`, `optionalString`
  — instead of `args["x"] as? String`. They produce the standard
  `invalid_args` envelope with `field` and `expected` populated, which
  the model uses to self-correct on the next turn.
- Set `"additionalProperties": .bool(false)` on every top-level (and
  nested object) schema so the central preflight rejects unknown keys
  with a pointed envelope. The matrix test
  [`BuiltinToolResilienceTests.allBuiltInsRejectUnknownProperties`](../Packages/OsaurusCore/Tests/Tool/BuiltinToolResilienceTests.swift)
  pins this for every built-in.
- Declare `enum` for closed-set string values. The preflight
  case-normalises to the canonical declared form, so the body's
  equality check stays strict without per-tool case-folding.
- Declare `default` for optional values; the schema's `default` is
  visible to the model.
- Return `ToolEnvelope.success(...)` / `ToolEnvelope.failure(...)`
  envelopes — never raw `{stdout, stderr, exit_code}` blobs. The chat
  UI's `ToolEnvelope.isSuccess` / `isError` detectors drive grouping,
  retry classification, and the failure card; tools that bypass the
  envelope land in a "neither success nor failure" gap and render
  generically.
- Cap large stdout/stderr (or any model-bound text) with
  `truncateForModel(_:maxChars:)` (head + tail strategy, defaults to
  ~50KB). The function lives next to the sandbox built-ins and is
  internal-scope so plugin tools can share it.

What you can rely on the preflight to handle for you:

- `"15"` ↔ `15`, `"true"` ↔ `true`, `"3.14"` ↔ `3.14` for typed
  scalars (mirrors `ArgumentCoercion`).
- `"[\"a\",\"b\"]"` ↔ `["a","b"]` for typed arrays.
- `"{\"a\":1}"` ↔ `{"a":1}` for typed objects.
- `"description": ""` (empty / whitespace-only) → key is dropped
  before the body runs, when the field is optional. Required fields
  keep their empty value so your `requireString` can surface a pointed
  `must not be empty` envelope.
- `"Pinned"` → canonical `"pinned"` for declared string enums.
- `{"properties": {chartType: "bar", ...}}` → unwrapped to the
  top-level shape when the model accidentally wraps its args in a
  `properties` envelope (only when `properties` isn't itself a declared
  field of the schema and at least one inner key matches).
