# Run Trace Inspector

Saved run traces are written under:

```text
~/.osaurus/agents/<agent-id>/runs/<run-id>.json
```

Each file is a `RunTrace` snapshot with run metadata, turns, assistant tool
calls, matching tool results, token accounting, and terminal error text when
available. The run trace inspector turns those artifacts into a redacted
diagnostic summary for debugging without rerunning the model.

## App usage

1. Open an agent.
2. Go to the Activity tab.
3. Select a run.
4. The right pane shows the trace inspector when a saved run JSON file exists.
5. Use the copy buttons in the inspector header:
   - document icon: redacted Markdown report
   - braces icon: redacted JSON report

The existing database changelog remains below the inspector. If a trace file is
missing, the Activity tab still shows the changelog. If a trace file is
malformed, the inspector shows typed findings instead of silently hiding it.
Copied reports abbreviate absolute source paths to the artifact filename so a
debug bundle does not expose the user's home directory.

Copy actions are disabled when inspection was cancelled, the artifact exceeded
a resource limit, JSON was malformed or unsupported, a tool payload could not
be parsed, or the final report still contains unsafe Unicode or a local path.
The copy guarantee applies only to reports produced by the trace inspector. It
does not claim that scheduler instructions, SQL changelog rows, errors, or other
content elsewhere in the Activity tab are redacted.

## Run continuity

The Activity tab also links a persisted run to its saved chat when that link is
available. `Open Chat` reuses the live background task first, focuses an
already-open saved chat second, and only then opens the persisted session. A
chat is never opened through a run owned by another agent.

`Cancel Run` appears only when `BackgroundTaskManager` still owns the exact
persisted run id. A database row whose status is `running` is not sufficient
evidence that work is live, so stale rows never receive a cancel action.

On an unclean app exit, a persisted `running` row can outlive the process that
owned it. The next Activity load marks only pre-process orphan rows as
`interrupted`; current-process and manager-owned rows are excluded. The
reconciliation timestamp is approximate. An interrupted run is not a model
failure, and its previous inference stream cannot be resumed, though its saved
chat can still be opened when available. Clean app termination continues to
record active tasks as `cancelled`.

## Programmatic usage

```swift
let url = OsaurusPaths.agentRunTraceFile(agentId: agentId, runId: runId)
let inspection = RunTraceInspector.inspectFile(at: url)

let markdown = try inspection.markdownReport()
let json = try inspection.jsonReport(prettyPrinted: true)
```

`RunTraceInspector.inspect(data:sourcePath:options:)` also accepts in-memory
JSON data. The inspector recognizes current `RunTrace` artifacts, saved eval
reports, and simple generic step traces.

## Findings

Findings are typed and severity-scoped:

- `error`: invalid JSON, missing required fields, invalid required types, bad
  UUIDs, invalid dates, or decode failures.
- `warning`: malformed tool arguments/results, missing tool results, orphaned
  tool results, duplicate tool results, unknown statuses, and error-shaped tool
  results.
- `info`: redaction notices and limitations such as missing per-turn timing.

Malformed artifacts return a `RunTraceInspection` with findings. Callers should
not treat an empty summary as success; check `inspection.hasErrors` and display
the findings. Before copying or exporting, check `inspection.canExport`; both
report methods also throw when export safety cannot be established.

## Resource limits

The file reader uses a bounded `FileHandle` read and rejects symbolic links.
Before Foundation materializes the JSON tree, a byte scanner enforces limits on
file size, nesting depth, and individual string size. Parsed artifacts are also
bounded by turn, step/case, and tool-call counts. Defaults are intentionally
large enough for normal traces but prevent a trace file from becoming an
unbounded memory or recursion workload:

- 4 MiB per artifact
- 64 levels of JSON nesting
- 64 KiB per JSON string
- 2,000 turns
- 5,000 steps or eval cases
- 5,000 tool calls

Inspection runs off the main UI path. Selecting another run cancels the prior
load, and request identity checks prevent a late result from replacing the
newer selection.

## Redaction

The inspector redacts JSON fields whose keys look sensitive, including:

- `api_key`
- `authorization`
- `bearer`
- `cookie`
- `credential`
- `password`
- `private_key`
- `secret`
- `access_token`
- `refresh_token`
- `id_token`
- `auth_token`
- `session_token`
- `token`

It also scans text previews for common inline forms such as `Bearer ...`,
`api_key=...`, `token=...`, and `password=...`. Reports include redacted
previews only; raw trace files are not modified. Token-like diagnostic keys such
as `max_tokens`, `token_type`, and `tokenizer` stay visible because they are not
secrets.

Report rendering escapes Markdown metacharacters and HTML, rejects remaining
local paths, and refuses bidirectional-control or unsafe control text. This is
a fail-closed diagnostic export policy, not a claim that heuristic secret-name
matching can identify every possible user-defined secret.

## Timing

Current `RunTrace` files record `startedAt` and `endedAt`, so the inspector can
report total run duration. Per-turn timing is not present in the artifact yet;
the inspector emits an informational finding when it can only report run-level
duration.

## Tests

Focused coverage lives in:

```text
Packages/OsaurusCore/Tests/Agent/RunTraceInspectorTests.swift
Packages/OsaurusCore/Tests/Agent/AgentRunContinuityTests.swift
Packages/OsaurusCore/Tests/Agent/Fixtures/RunTrace/
```

Run the focused lane from the repository root:

```bash
OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 \
OSAURUS_TEST_ROOT=/tmp/osaurus-test \
swift test --package-path Packages/OsaurusCore \
  --filter 'RunTraceInspectorTests|AgentRunContinuityTests'
```
