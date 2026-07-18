# Evidence Report Registry

The evidence report registry is the shared projection layer for report
artifacts produced by eval, benchmark, runtime, live-proof, run-trace, provider
validation, and model-library evidence flows. It does not create a new report
destination or move artifact files; callers register local artifact descriptors
and receive typed summaries that can be listed, filtered, serialized, and
rendered by future surfaces.

## Model

`EvidenceReportDescriptor` is the input from a local producer:

- `kind`: one of `eval`, `benchmark`, `runtime`, `live_proof`, `run_trace`,
  `provider`, `model_compatibility`, `cache`, or `custom`.
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
filters for kind, source, status, and artifact availability. Re-registering the
same identity is a deliberate refresh: the incoming summary replaces the prior
one even when its artifact has since become unavailable. Stable JSON output uses
the package canonical encoder with sorted keys and ISO-8601 dates.

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

## Model Library Evidence

`ModelLibraryEvidenceService` is the model-library producer for the shared
registry. It registers read-only rows for:

- local cache/import status (`kind = cache`, `source = model-library-cache`);
- compatibility and preflight status (`kind = model_compatibility`,
  `source = model-library-preflight`);
- optional cache, benchmark, and runtime proof artifacts supplied by proof
  producers.

The service preserves model state as `supported`, `partial`, `unsupported`, or
`unproven` metadata while mapping registry status to the common report
vocabulary. Missing local/proof artifacts stay explicit `unavailable` rows
rather than becoming support claims.

The model projection also returns grouping metadata for consumers. Incomplete
local directories and external cache/import candidates are grouped and excluded
from default visible rows, so large local caches do not flood model views. A
consumer can opt into those groups for repair or audit workflows.

Full bundle paths are not copied into model row metadata. The registry artifact
path remains the local source-of-truth pointer, but model evidence metadata uses
redacted display paths such as `.../repo-name` and stores `bundle_path` as
`<redacted>`.
