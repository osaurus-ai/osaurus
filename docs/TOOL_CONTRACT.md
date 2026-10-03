# Tool Contract

Every Osaurus tool — global built-in, folder tool, sandbox tool, **plugin tool** — returns a
JSON string in exactly one of two shapes. This page is the one-stop
reference for tool authors.

The type lives at [`Tools/ToolEnvelope.swift`](../Packages/OsaurusCore/Tools/ToolEnvelope.swift).

> **Plugin authors:** the contract on this page applies to your tools too.
> The `invoke` callback's return JSON must match the success or failure
> envelope below. See [`docs/plugins/AUTHORING.md`](plugins/AUTHORING.md#tools)
> for the plugin-specific manifest declaration.

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

### Structured, actionable result kinds

Results the agent loop needs to route on carry a discriminated `kind` so the
harness — not the model — decides the next move. The model acts by copying a
field, not by parsing prose:

- **Directory listing** (`file_read` on a directory, host + sandbox), built via
  `ToolEnvelope.listing(...)`:

  ```json
  {
    "ok": true,
    "result": {
      "kind": "listing",
      "path": "Desktop",
      "entries": [
        { "name": "notes.txt", "path": "Desktop/notes.txt", "type": "file" },
        { "name": "photos",    "path": "Desktop/photos",    "type": "directory" }
      ],
      "entry_count": 2,
      "truncated": false
    }
  }
  ```

  Each `entries[i].path` is a ready-to-use `path` argument for the next
  `file_read` — descending is a field copy. There is **no tree string** in the
  model-facing result; the chat UI renders a tree from `entries`, and
  `ContextBudgetManager` collapses an old listing to `"<N> entries in <path>"`.
  `entry_count` / `truncated` drive the loop's empty/partial/populated bias.

- **File content** (`file_read` on a file) carries `"kind": "file"` alongside
  `text`, `path`, and the line/byte metadata.

`AgentTaskState.classify(_:)` reads these discriminators (`listing` →
empty/partial/populated, `file` → file content, `not_found` failures →
not-found) to drive the agent loop. See `docs/AGENT_LOOP.md`.

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
| `execution_error`  | tool ran but failed (process exited non-zero, etc.)            | `true`              |
| `not_found`        | a referenced path (file or directory) does not exist           | `false`             |
| `unavailable`      | tool exists but can't run right now (sandbox booting, etc.)    | `true`              |
| `tool_not_found`   | model called a tool the registry doesn't have                  | `false`             |

`not_found` is distinct from `execution_error` so the agent loop's task-state
machine (`AgentTaskState`, see `docs/AGENT_LOOP.md`) can classify a missing
path as a not-found transition and steer the next step (pick a `path` from the
last listing, or list the parent) rather than treating it as a generic runtime
failure. `FolderToolError.fileNotFound` / `.directoryNotFound` both map here.

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

The local `/screenshot` command deliberately does not add a marker flow. It
writes the PNG directly into the chat artifact store and records it as
chat-local artifact metadata, not as a tool call or tool result. Chat rebuilds
the artifact card from that local metadata, so screenshot bytes, base64, and
artifact host paths do not enter model-visible transcript history.

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

### `file_edit` matching contract

`file_edit` (and the sandbox writer it routes `/workspace/...` paths
through) matches `old_string` with a fixed cascade and applies the first
tier that yields a match:

1. `exact` — byte-for-byte.
2. `whitespace_normalized` — whole lines compared with edge whitespace
   trimmed and inner whitespace runs collapsed (tabs vs spaces,
   indentation depth).
3. `blank_lines_collapsed` — as above, ignoring blank lines between the
   non-blank lines.
4. `unicode_normalized` — as above, folding curly quotes, dashes,
   ellipses and non-breaking spaces to their ASCII forms.

A relaxed tier is applied only when it matches exactly once (or
`replace_all` is set); otherwise the failure names the tier and count and
carries `metadata.retry_with = {"replace_all": true}`. Unchanged lines are
always copied from the FILE (never from `old_string`), so the file's
indentation, blank lines, BOM and line endings survive; inserted lines
are re-indented to the file's indent unit.

The success payload reports `replacements`, `match_strategy` (the most
relaxed tier any edit needed), `matched_lines` (`"12"` / `"12-15"` per
block), and for `edits` batches `edits_applied` / `edit_strategies` per
entry. Every relaxed match adds a `warnings` entry quoting the verbatim
file text that was matched, so the model learns what the file really
looked like. `dry_run` returns the same payload plus a `PREVIEW ONLY`
warning and writes nothing.

Document routes (`.docx`/`.pptx` `replace_text`) use a two-tier
cascade (`exact`, then punctuation/whitespace `normalized`); the
operation summary says when the normalized tier was used, multi-match
errors name the part (body / header / slide N), and a multi-line
`old_string` on `.docx` matches consecutive paragraphs. When a match
misses and `old_string` carries Markdown syntax — list markers (`•`,
`-`, `*`, `1.`, `1)` + space/tab: what `file_read` renders for list
paragraphs and what a Markdown-drafted brief contains), ATX heading
hashes (`## Scope`), or inline emphasis (`**Kickoff: April 7**`,
`_x_`, `` `x` ``, `~~x~~`; underscores inside words are left alone) —
the match is retried without the syntax and it is dropped from a
single-line `new_string` too, since Word and PowerPoint store all of it
as paragraph and run styling, not text. The summary names the rescue.
Raptor no-think drafted `- **Kickoff: April 7**` and `## Scope and
Timeline` and missed on both before this.

`file_write` for `.docx`/`.pdf` turns lines that start with a typographic
bullet (`•`, `◦`, `▪`, `■` + space/tab, outside fenced code) into
Markdown list items before parsing. CommonMark reads those glyphs as
prose, so a model that redrafted from a `file_read` rendering had a whole
section soft-wrap into one paragraph ("Goal • Migrate … • Ensure …") that
no later `old_string` could address. `.pptx` accepts the same glyphs
(space or tab) as bullet markers.

On `.docx`, newlines in `new_string` are paragraph boundaries, never soft
line breaks (a `<w:br/>` reads back as one run-on line that no later
`old_string` can address). A single-line match with a multi-line
replacement keeps the first line in the matched paragraph (head text and
runs intact), moves any tail after the match into a clone that takes the
last line, and builds the lines between as new paragraphs. New lines are
read as block Markdown the way `file_write` renders it: `## Title` takes
the document's `Heading2` style (bold text when the style is missing),
`- item` / `1. item` / `•\titem` clone the nearest list paragraph's
formatting (then `ListBullet`, then a literal bullet), everything else
clones the nearest unstyled body paragraph. Lines written into existing
paragraphs drop the prefix and keep that paragraph's style; a heading or
list line landing on a paragraph of another kind is rebuilt with the
matching style. The drafting eval (`frontier.document-drafting-revisions`,
grok-4.3) went from 16 tool calls with 7 `file_edit` errors to 4 calls
with none on this change.

Rendered drafts store list items as literal `•\t…` / `1.\t…` text (a
`<w:tab/>` inside the paragraph). In a multi-line `old_string` that prefix
counts as blank on the leading side, so once the Markdown rescue has
stripped `- ` from the model's lines, each middle/last line still
addresses the whole item; the bullet stays in the paragraph and the
replacement is written after it (never across the tab). Collapsing two
items into one keeps one bullet. Raptor no-think sent a 3-line
`- Kickoff …` / `- Phase 1 …` / `- Set the schedule …` `old_string`
against such a draft and missed on the last two lines before this. When
the stripped retry matches but cannot be applied, that error is the one
reported, not the original miss.

An empty `old_string` with a `new_string` on `.docx`/`.pptx` is an
insert, which `replace_text` cannot anchor; the rejection names the
operations that add text (`append_markdown`, `insert_paragraph` with
`after: N`; `set_slide_text` / `duplicate_slide` on `.pptx`).

Three Raptor no-think `file_edit` shapes are repaired before schema
validation (`FileEditTool.normalizeArgumentsBeforeValidation`); the
public schema stays strict and nothing else about the payload changes:

- `edits` / `operations` sent as a JSON **string** (`"edits": "[{…}]"`,
  `edit-docx-in-place`) is decoded.
- A missing top-level `path` that every entry carries identically
  (`{"edits": [{"path": "memo.docx", …}, {"path": "memo.docx", …}]}`;
  `edit-docx-in-place` ×3, `fill-pdf-form-in-place` ×2 in one run) is
  hoisted. Entries that disagree, or a call with no `path` anywhere, still
  get "Missing required property: path". The agent loop's dedupe/mutation
  bookkeeping (`AgentTaskState`) sees the raw call and resolves the same
  shared entry path (`sharedEntryPath`), so a verify-read after such an
  edit re-executes instead of replaying pre-edit content (observed on
  `edit-pptx-in-place`: "repeated reads continue to show the original
  content").
- Document operations under `edits` (`{"edits": [{"op": "set_cells", …}]}`,
  `edit-xlsx-in-place`, `document-drafting-revisions`) move to
  `operations`, which `edits.items` (requires `old_string`) would otherwise
  reject and start a shape-guessing loop. Only an array in which at least
  one entry carries a known document `op` moves (text-file batches never
  do); `{old_string, new_string}` entries in the same array become
  `replace_text` (top-level `replace_all` carries over), and a real
  `operations` array always wins.

Content-free fillers under `edits` / `operations` (`[]`, `null`, `""`,
`{}`, and containers holding only such values — `[{}]`, `[{"op": ""}]`)
next to a real edit form are dropped before dispatch, on both the host
and sandbox routes. Constrained decoders emit the unused optional
collection as an empty array (`"operations": []` beside a real `edits`
batch, 5/5 on grok-4.3) and, once the array is open, sometimes pad it
with an empty object (grok-4.3 `edit-batch-edits-single-call`, one run in
ten); the filler carries no intent and must not turn a text-file batch
into an "operations on a text file" error. A request that carries only a
filler still gets the pointed non-empty-array error; numbers and booleans
are content, so `[{"index": 0}]` is never dropped.

`file_write` on a document path refuses `content` that parses as a
`file_edit` operations array (`[{"op": "fill_form", …}]`, or wrapped as
`{"operations": [...]}`, every element carrying a known `op`). Rendering it
would replace the document with one line of JSON text — Raptor no-think
did exactly that to a PDF form, twice in one run. The rejection names the
ops, states the file was not changed, and carries the exact `file_edit`
call in `metadata.retry_with` (`retry_with_tool: "file_edit"`). A bare
array of rows for `.xlsx` is not an operations payload and still renders.

`.xlsx` JSON rows may be positional arrays or records (`{"Item": "Rent",
"Amount": 1200}`) at every level (`sheets[].rows`, top-level `rows`, or
the bare top-level array). Records produce a header row from the sorted
union of keys plus one row per record; a record whose values echo its keys
(a header spelled as a record) is dropped so the header is written once.

### Schema shape on the provider wire (constrained decoders)

Two wire facts, both measured against xAI `grok-4.3` (deterministic,
5/5 runs each) and matching how JSON-schema grammars (llama.cpp-style)
constrain output:

1. **Optional properties are only reachable in declared order.** Once
   the model has emitted a later-declared key, earlier ones are gone.
   Osaurus encodes bodies with `.sortedKeys` for prompt-cache
   determinism, which alphabetizes `properties`; `new_string` then sat
   before `old_string` and arrived missing every time
   (`{"path","old_string","replace_all":false}`). Tools that care declare
   `parameterOrder`; `ToolRegistry` records it and
   [`ToolWirePropertyOrder`](../Packages/OsaurusCore/Tools/ToolWirePropertyOrder.swift)
   rewrites the encoded body just before send so those tools'
   `properties` (top level and nested `items`/branches) follow the
   authored order while everything else stays sorted. The rewrite is
   deterministic, so the cache contract still holds. Put the key the
   model writes first, first: `path`, then `old_string`, then
   `new_string`.
2. **Do not enumerate per-variant keys on a polymorphic array item.**
   `file_edit.operations.items` is a free-form object whose keys are
   documented in the `operations` description. With `properties`
   declared, the model emitted `op` first and every key sorting before
   it (`cells`, `fields`, `index`, `new_string`, `old_string`) became
   unreachable, arriving as `{"op":"replace_text","slide":1,"text":…}`;
   with the original `{op}`-only declaration the call arrived as
   `{"op":"replace_text"}`. The free-form shape produced correct
   arguments 3/3. Each editor validates its own keys with
   entry-numbered errors that list the keys the entry did carry.

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

---

## Output normalization (automatic)

Every returned string passes through
[`ToolRegistry.normalizeToolResult`](../Packages/OsaurusCore/Tools/ToolRegistry.swift)
before the model ever sees it, in this order:

1. **Secret-prompt guard.** A result that carries the `SecretPromptParser`
   marker is handled first and returned byte-exact — it is **not** an
   envelope and is never wrapped or compacted, so the secure-input overlay
   flow stays intact.
2. **Lossless compaction**
   ([`ToolOutputCompressor`](../Packages/OsaurusCore/Tools/ToolOutputCompressor.swift)).
   Validated-JSON whitespace crush (string-aware; preserves key order,
   number lexemes, and escaping) plus a trailing-whitespace strip. It is
   deterministic and idempotent, so the **KV prefix stays byte-stable**
   across loop turns, and it runs *before* the cap so oversized external
   pretty-JSON can crush back under the ceiling instead of being truncated.
   It is a no-op on Osaurus's own already-compact envelopes — the win lands
   on external surfaces (`shell_run` of `… | jq`, MCP text, pretty `.json`
   reads), ~36% on pretty JSON and ~10% on trailing-whitespace logs.
   Default-on; set `OSAURUS_DISABLE_TOOL_OUTPUT_COMPRESSION=1` to bypass it.
3. **Envelope wrap + universal cap.** Non-envelope output is wrapped into the
   success envelope, and anything still over `ToolOutputCaps.universalResult`
   is head+tail truncated and re-wrapped with `truncated: true` plus a
   recovery hint, so no single call can blow the context window in one turn
   (error-ness is preserved).

The `truncateForModel(_:maxChars:)` advice above is a tool deliberately
shaping its *own* output; steps 1–3 are the platform's safety net applied to
*every* tool's result regardless of how it was produced.
