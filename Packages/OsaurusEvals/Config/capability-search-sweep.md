# Capability-search retrieval retune — sweep evidence

Recorded calibration for the **tools-lane embed-cosine quality gate**
(`CapabilitySearch.minimumEmbedCosineForTools`), the score-aware fusion change
made in `ToolSearchService.searchHybridWithDiagnostic` (`minEmbedCosine:`).

- **Date:** 2026-06-19
- **Suite:** `Packages/OsaurusEvals/Suites/CapabilitySearch` (`--model auto`)
- **Harness:** `osaurus-evals run --embed-cosine-floor <F> --report-forensics`
  (the `--embed-cosine-floor` sweep flag added for this calibration; `nil`
  uses the shipped constant). Runs are hermetic — isolated temp storage with
  the real `~/.osaurus/Tools` symlinked in, so the index is populated
  (`index=61`) and never contends with a running host app.
- **Raw artifacts:** `build/evals/ws5-sweep/floor-{0.00,0.25,0.30,0.40}.json`
  (+ `.log`).

## Mechanism

Pure rank-based RRF (`k=60`) saturates at `2/(60+1) ≈ 0.0328`, so an
abstain-noise tool that merely *ranks* in the embed top-K fuses to the same
~0.03 band as real recall — no single `minimumFusedScore` separates them (the
long-standing note in `CapabilitySearch.swift`). The retune gates each embed
candidate's RRF contribution by its **raw cosine**: a candidate below
`minEmbedCosine` contributes zero to fusion (as if it weren't an embed hit),
so a BM25-only rank-1 (`≈0.0164 < 0.020` cutoff) drops out. `minEmbedCosine == 0`
disables the gate (legacy callers unchanged). The gate is **tools-lane only**;
the methods/skills lanes already apply their own `0.25` embed-cosine floor
(`minimumRelevanceScoreMethods` / `…Skills`).

## Sweep — accepted hits per case (outcome)

| case | f=0.00 | f=0.25 (shipped) | f=0.30 | f=0.40 |
|---|---|---|---|---|
| abstain-greeting (abstain) | 3 fail | 3 fail | 3 fail | 0 pass |
| method-abstain (abstain) | 3 fail | 3 fail | 3 fail | 0 pass |
| skill-abstain (abstain) | 1 fail | **0 pass** | 0 pass | 0 pass |
| browser-prefix (recall, min 5) | 11 pass | **11 pass** | 11 pass | **5 fail** |
| method-lexical-name (recall) | 7 pass | 1 pass | 1 pass | 1 pass |
| method-multi-match (recall) | 11 pass | 4 pass | 4 pass | 3 pass |
| method-paraphrase (recall) | 6 pass | 5 pass | 4 pass | 2 pass |
| skill-direct-name (recall) | 4 pass | 1 pass | 1 pass | 1 pass |
| skill-keyword-only (recall) | 2 pass | 2 pass | 1 pass | 1 pass |
| skill-paraphrase (recall miss) | 4 fail | 0 fail | 0 fail | 0 fail |
| shell-execution (tracking) | 4 fail | 4 fail | 1 fail | 1 fail |

(`extract-webpage-natural`, `weather-natural` skip — `osaurus.fetch/search/weather`
not installed.)

## Per-hit cosine evidence (f=0.00, the overlap that decides the floor)

Abstain noise that gets accepted (tools lane) vs the real recall that must
survive — same embedder (`potion-base-4M`), same cosine scale:

| group | tool | embed cosine |
|---|---|---|
| abstain-greeting noise | `complete` | 0.355 |
| abstain-greeting noise | `clarify` | 0.339 |
| abstain-greeting noise | `notify` | 0.308 |
| skill-abstain noise | `complete` | **0.110** |
| browser recall (min) | `browser_scroll` | 0.298 |
| browser recall | `browser_select` | 0.326 |
| browser recall | `browser_execute_script` | 0.351 |
| browser recall (max) | `browser_open_login` | 0.505 |
| method recall (min) | `plot_data` | 0.281 |

## Decision: `minimumEmbedCosineForTools = 0.25`

- **Preserves all recall.** 0.25 sits below the minimum real tools-recall
  cosine (`browser_scroll` 0.298), so every recall floor still passes
  (browser-prefix 11, all method/skill recall). It only trims sub-0.25 tool
  noise — a precision win (e.g. accepted noise on method/skill queries falls
  7→1, 11→4, 4→1) with **zero recall loss**.
- **Fixes a real abstain case.** `skill-abstain`'s lone accepted hit was the
  tool `complete` at cosine **0.110**, accepted only via BM25 rank-1; gating
  its embed term drops it below the fused cutoff → **skill-abstain reaches 0
  accepted**. Promoted out of tracking-only in `recall_floors.json`.
- **Consistent.** Matches the methods/skills lanes' existing 0.25 cosine floor.

## Why the conversational-abstain cases stay tracking-only (honesty note)

`abstain-greeting` and `method-abstain` accept `complete` (0.355), `clarify`
(0.339), `notify` (0.308) — conversational meta-tools whose cosine to "thanks,
that's perfect" genuinely **overlaps real recall** (`browser_scroll` 0.298,
`plot_data` 0.281). The sweep proves the tradeoff: the only floor that zeroes
them (f=0.40) **breaks `browser-prefix` recall** (5 fail). Picking ~0.36 to
straddle this one query's noise would gate legitimate browser capabilities
(`browser_scroll/select/execute_script`) and overfit the gate to the eval —
forbidden by `AGENTS.md`. The correct fix is the separately-tracked
query-intent / pre-RRF abstain mechanism, not a higher cosine floor. These
cases therefore remain tracking-only with `expect maxAccepted=0`.

`skill-paraphrase` also stays tracking-only: `Content Summarizer` never reaches
the embedder's top hits for "give me the gist" (a recall/description gap, not a
threshold issue) — addressed by the description-audit follow-up, not this retune.
