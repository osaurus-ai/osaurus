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

## Programmatic usage

```swift
let url = OsaurusPaths.agentRunTraceFile(agentId: agentId, runId: runId)
let inspection = RunTraceInspector.inspectFile(at: url)

let markdown = inspection.markdownReport()
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
the findings.

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
- `session_token`
- `token`

It also scans text previews for common inline forms such as `Bearer ...`,
`api_key=...`, `token=...`, and `password=...`. Reports include redacted
previews only; raw trace files are not modified.

## Timing

Current `RunTrace` files record `startedAt` and `endedAt`, so the inspector can
report total run duration. Per-turn timing is not present in the artifact yet;
the inspector emits an informational finding when it can only report run-level
duration.

## Tests

Focused coverage lives in:

```text
Packages/OsaurusCore/Tests/Agent/RunTraceInspectorTests.swift
Packages/OsaurusCore/Tests/Agent/Fixtures/RunTrace/
```

Run the focused lane from the repository root:

```bash
OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 \
OSAURUS_TEST_ROOT=/tmp/osaurus-test \
swift test --package-path Packages/OsaurusCore --filter RunTraceInspectorTests
```
