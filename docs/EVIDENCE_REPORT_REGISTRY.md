# Evidence Report Registry

The evidence report registry is the shared projection layer for report
artifacts produced by eval, benchmark, runtime, live-proof, run-trace, and
provider validation flows. It does not create a new report destination or move
artifact files; callers register local artifact descriptors and receive typed
summaries that can be listed, filtered, serialized, and rendered by future
surfaces.

## Model

`EvidenceReportDescriptor` is the input from a local producer:

- `kind`: one of `eval`, `benchmark`, `runtime`, `live_proof`, `run_trace`,
  `provider`, or `custom`.
- `source`: the producing flow, such as `evals-pr-evidence` or
  `provider-connectivity`.
- `artifactPath`: the local artifact path. Relative paths can be resolved
  against a caller-provided base URL.
- `status` and `counts`: summary outcome fields from the producer.
- `startedAt`, `completedAt`, and registration time.
- `metadata`: string metadata, redacted at registration before storage.

`EvidenceReportSummary` is the canonical output. Missing artifact paths are
kept as explicit rows with `status = unavailable` and
`artifact.availability = unavailable`. Descriptors that already know they
failed to parse or validate can pass `artifactError`, which produces an
explicit `error` row.

## Behavior

`EvidenceReportRegistryService` stores summaries in memory, dedupes repeated
descriptors by explicit `id` or by `(kind, source, artifactPath)`, and supports
filters for kind, source, status, and artifact availability. Stable JSON output
uses the package canonical encoder with sorted keys and ISO-8601 dates.

Metadata is redacted before it reaches the registry. Sensitive keys such as API
keys, authorization headers, passwords, private keys, credentials, and token
fields are replaced with `<redacted>`. Values that look like common bearer,
OpenAI, GitHub, or Slack-style secrets are also replaced.

## Eval Watcher Usage

`osaurus-evals report` writes the eval-specific report bundle as before, then
emits `evidence-registry.json` next to `summary.json`. That snapshot registers
the report summary as an `eval` artifact with source
`osaurus-evals-review-report`.

`osaurus-evals scoreboard` consumes those registry snapshots when rebuilding a
watcher scoreboard. It does not scan arbitrary `summary.json` files as a second
report source; it follows registry summaries, fails closed when a registered
artifact is unavailable or invalid, and writes its own scoreboard registry
snapshot with source `osaurus-evals-scoreboard`.
