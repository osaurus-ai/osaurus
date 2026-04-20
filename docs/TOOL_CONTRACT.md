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
