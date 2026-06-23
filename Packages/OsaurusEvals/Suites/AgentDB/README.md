# AgentDB suite

End-to-end agentic evals for the **Agent DB superpowers** — the bulk-ingest,
SQL-transform, paging, and guardrail surface documented in
[`docs/AGENT_DB.md`](../../../../docs/AGENT_DB.md). Every case runs the canonical
`AgentToolLoop` against the **real** `ToolRegistry`, `LocalAgentBridge`, and a
per-eval-agent `AgentDatabase`, so a green row means the model drove the actual
`db_*` tools to the asserted database state — not that it described doing so.

The suite is deliberately framed around the **daily GitHub analyst** reference
flow: ingest data you didn't type, derive numbers in SQL, and deliver a result.
The analyst itself is *not* shipped here — `agentdb.daily-github-analyst` proves
the flow is reachable end-to-end from existing tools.

## What each case proves

| Case | Proves | Key feature | Headline assertions |
|------|--------|-------------|---------------------|
| `import-csv-500` | A 500-row CSV loads in **one** call, no per-row writes | `db_import` (host-mediated file load) | rowCount 500, `SUM(additions)=125250`, `db_insert`/`db_upsert` **not** called |
| `bulk-insert` | Many computed rows land in one call | `db_insert` with `rows[]` (`insertMany`) | `db_insert` called exactly once, `SUM(points)=210` |
| `pagination` | Paging a result set instead of slurping it | `db_query` `limit`/`offset` | `db_query` arg contains `offset`, answer `n=23` |
| `sql-transform` | Aggregation done **in SQL**, in one transaction | multi-statement `db_execute` (`INSERT … SELECT … GROUP BY`) | `db_execute` ≤1 call, `daily_totals` shape + busiest-day row, `db_insert` **not** called |
| `sql-guardrails` | Destructive SQL is rejected and data survives | `forbiddenReason` (`DROP TABLE`) | table still holds its 3 rows after a rejected `DROP` |
| `softdelete-restore` | The soft-delete contract round-trips | `db_delete` → `db_restore` | delete-before-restore ordering, 3 active / 3 total rows |
| `daily-github-analyst` | The full reference flow, from existing tools | `db_import` → `db_define_view` → `db_run_view` → `share_artifact` | `repo_stats` has 4 rows, today total 175, trend view (day,total) rows, artifact named `*trend*` shared |

Fixtures live in [`../../Fixtures/AgentDB`](../../Fixtures/AgentDB):
`commits-500.csv` (500 deterministic commit rows) and `stars-today.csv`
(today's snapshot for the analyst flow). Cases reference them through
`workspaceFiles[].contentsFromFixture`, and yesterday's state is staged with
`fixtures.seedSql`.

## Scoring is deterministic — no judge model

Every assertion here is mechanical: `dbState` SQL run against the eval agent's
DB (`expectFirstValue` / `expectRowCountEquals` / `expectColumns` /
`expectValues`), `toolUsageAudit`, `mustCallTools(InOrder)`, `mustNotCallTools`,
`artifactShared`, and substring `finalTextContains`. **No `rubric`**, so the
suite needs **no `JUDGE_MODEL`** and produces the same score for the same
trajectory every run. That is the point: it measures whether the *model* drives
the tools correctly, with nothing fuzzy in the loop.

## Running

These cases need no sandbox VM and no entitlement (unlike `SandboxFrontier`), so
`swift run` is fine. The CLI auto-connects an ephemeral, in-process xAI provider
when `--model xai/...` and `XAI_API_KEY` are set; it is torn down at the end and
never written to disk or Keychain.

Measure the frontier ceiling with **xAI Grok**:

```bash
XAI_API_KEY=... \
swift run --package-path Packages/OsaurusEvals osaurus-evals run \
  --suite Packages/OsaurusEvals/Suites/AgentDB \
  --model xai/grok-4.3 \
  --out build/evals/agentdb-grok-4.3.json
```

Run a single case while iterating with `--filter`:

```bash
XAI_API_KEY=... \
swift run --package-path Packages/OsaurusEvals osaurus-evals run \
  --suite Packages/OsaurusEvals/Suites/AgentDB \
  --model xai/grok-4.3 --filter agentdb.sql-transform \
  --out build/evals/agentdb-grok-4.3.json
```

A local model is also useful for a discipline baseline (expect lower scores on
the multi-step cases — small-context models tend to fall back to per-row writes,
which `mustNotCallTools` / `argsMustContain` are designed to catch):

```bash
swift run --package-path Packages/OsaurusEvals osaurus-evals run \
  --suite Packages/OsaurusEvals/Suites/AgentDB \
  --model <local-model-id> \
  --out build/evals/agentdb-local.json
```

## Frontier baseline (xAI Grok)

> **Status: RECORDED — 7/7 pass on `xai/grok-4.3`.**
> - Run date: 2026-06-22 (report `startedAt` 2026-06-22T13:29:38Z)
> - Model: `xai/grok-4.3` (ephemeral xAI provider, `XAI_API_KEY`)
> - Harness: commit `c5b84db7` + the Agent DB superpowers working changes (this branch)
> - Report: `build/evals/agentdb-grok-4.3.json` (gitignored `build/`); reproduce with the command above.

`token/s` is **not applicable** here — `xai/grok-4.3` is a remote API model, so
there is no local generation rate to record (that metric belongs to local-MLX
runtime proof). The meaningful frontier metrics are wall latency, model
round-trips (`steps`), and total model tokens (prompt + completion across
steps), pulled from each case's `telemetry`.

| Case | Result | Latency | Steps | Model tokens |
|------|--------|---------|-------|--------------|
| `import-csv-500` | PASS | 4.8s | 3 | 18,704 |
| `bulk-insert` | PASS | 10.5s | 4 | 25,101 |
| `pagination` | PASS | 4.3s | 3 | 18,592 |
| `sql-transform` | PASS | 6.8s | 3 | 18,754 |
| `sql-guardrails` | PASS | 4.2s | 3 | 18,628 |
| `softdelete-restore` | PASS | 8.8s | 6 | 38,181 |
| `daily-github-analyst` | PASS | 8.7s | 6 | 40,973 |

### What the frontier run caught (and the fixes)

Per the authoring rule, every case must pass on `xai/grok-4.3`; getting there
surfaced two real defects rather than being a rubber-stamp:

1. **Harness — case-sensitive `toolUsageAudit.argsMustContain`.** The `pagination`
   case asserts `db_query` args contain `offset`, but Grok paged with SQL
   `... LIMIT 1 OFFSET 22` (uppercase `OFFSET`) — a perfectly valid offset
   window. The agent-loop audit was matching case-sensitively and rejected a
   correct trajectory. Fixed in `scoreToolUsageAudit`
   ([`EvalRunnerAgentLoop.swift`](../../Sources/OsaurusEvalsKit/EvalRunnerAgentLoop.swift)):
   `argsMustContain` / `argsMustNotContain` now match case-insensitively,
   matching the sibling default-agent matcher. The assertion is now
   mechanism-agnostic — the typed `offset` parameter and SQL `OFFSET` both
   satisfy it, while a full-table slurp (no offset) still fails.
2. **Test faithfulness — `seedSql` raw tables lack system columns.** The analyst
   seeded `repo_stats` with a bare `CREATE TABLE`, so it had none of the
   reserved `_created_at` / `_updated_at` / `_deleted_at` columns. `db_import`
   and `db_schema` (which stamp/read those) then failed with `no such column:
   _updated_at`, and Grok fell back to a per-row `db_insert` (tripping
   `mustNotCallTools`). In production that table would have been created by
   `db_create_table` and carried the system columns. Fixed by seeding a table
   shaped like a real agent table; the `seedSql` doc comment in
   [`EvalCase.swift`](../../Sources/OsaurusEvalsKit/EvalCase.swift) now documents
   the gotcha for future case authors.

Keep failed cases in the table with their attribution (below) rather than
trimming the suite to chase green.

## Failure attribution

Keep the harness honest. A failure here is one of:

- **Harness defect** — surfaces as an `errored` row (bad fixture path, decode
  failure, bridge exception). Fix the harness and re-run before recording.
- **Model-discipline finding** — the model had the capability and the tools but
  drove them wrong: looped per-row `db_insert` instead of `db_import`, computed
  an aggregate in prose instead of SQL, tried to delete data another way after a
  guardrail rejection, or skipped delivery. These are the real signal; record
  them in [`docs/HARNESS_COMPATIBILITY.md`](../../../../docs/HARNESS_COMPATIBILITY.md)
  per its attribution convention.

Headless constraints (shared with the other agent-loop suites): `.ask`-gated
tools are auto-approved for the isolated eval agent, and user notifications
no-op without an app bundle — so the analyst case asserts delivery via
`share_artifact` (always available) rather than `notify`, even though
self-scheduling is enabled so a capable model *may* also notify.
