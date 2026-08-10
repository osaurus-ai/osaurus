# Osaurus Model Compatibility (community)

Crowdsourced from 11 contribution(s). Each row reflects the model's **latest run** (newest case catalog); same-catalog runs on other devices fold in, older runs live under the model's History and are never pooled into the headline. Verdicts: **works** (runs cleanly), **partial** (runs with errors or low pass-rate), **broken** (error-dominated / never scored). *stale* = the run predates the newest catalog and needs refreshing.

## Contributors

This leaderboard exists because **tpae** and **Michael Meding** donated machine-hours to run the suites. Ranked by contributed runs (every run counts, current and superseded), then by breadth of models and device shapes covered. Attribution comes from the contribution's `contributor` provenance, falling back to the git author who added the file. Want on this list? See `reports/community/README.md` — one command, one PR.

| # | Contributor | Runs | Models | Devices |
| --- | --- | --- | --- | --- |
| 1 | **tpae** | 6 | 6 | 1 |
| 2 | Michael Meding | 5 | 5 | 1 |

## Models

| Model | Verdict | Pass | Fail | Skip | Err | Great at | Devices | peak RAM | decode tok/s | build | as of |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `Ornith-1.0-35B-MXFP8` | partial | 85% (184/216) | 32 | 55 | 1 | apple_script, subagent, default_agent · weak: computer_use_loop | Apple M4 Max (128GB) | 14587MB | 17 | 563f91746 | 2026-07-11 |
| `Ornith-1.0-9B-MXFP4` | works *(stale)* | 76% (188/247) | 59 | 5 | 0 | subagent, capability_claims · weak: computer_use_loop | Apple M4 Pro (48GB) | 20614MB | 23 | — | 2026-07-05 |
| `Ornith-1.0-9B-MXFP8` | works | 82% (178/217) | 39 | 55 | 0 | apple_script, capability_claims, subagent, default_agent · weak: computer_use_loop | Apple M4 Max (128GB) | 10590MB | 29 | 563f91746 | 2026-07-10 |
| `gemma-4-12B-it-MXFP8` | works | 87% (188/217) | 29 | 55 | 0 | apple_script, computer_use_loop, subagent, default_agent · weak: agent_loop | Apple M4 Max (128GB) | 11489MB | 27 | 563f91746 | 2026-07-10 |
| `gemma-4-E2B-it-8bit` | works | 54% (117/215) | 98 | 57 | 0 | apple_script, subagent · weak: capability_claims | Apple M4 Max (128GB) | 13531MB | 38 | 563f91746 | 2026-07-10 |
| `gemma-4-E4B-it-4bit` | works *(stale)* | 77% (188/245) | 57 | 7 | 0 | subagent, computer_use_loop · weak: default_agent | Apple M4 Pro (48GB) | 19798MB | 21 | — | 2026-07-06 |
| `gemma-4-E4B-it-8bit` | works | 80% (174/217) | 43 | 55 | 0 | apple_script, subagent, computer_use_loop · weak: default_agent | Apple M4 Max (128GB) | 16445MB | 30 | 563f91746 | 2026-07-10 |
| `Qwen3-4B-4bit` | works *(stale)* | 80% (198/246) | 48 | 6 | 0 | subagent, computer_use_loop, capability_claims · weak: default_agent | Apple M4 Pro (48GB) | 20583MB | 53 | — | 2026-07-05 |
| `Qwen3.5-4B-OptiQ-4bit` | works *(stale)* | 86% (212/247) | 35 | 5 | 0 | subagent, agent_loop · weak: computer_use_loop | Apple M4 Pro (48GB) | 20487MB | 35 | — | 2026-07-06 |
| `grok-4.3` | works *(stale)* | 92% (228/247) | 19 | 5 | 0 | capability_claims, agent_loop, computer_use_loop, subagent · weak: apple_script | Apple M4 Pro (48GB) | 19637MB | 10 | — | 2026-07-05 |

## Model details

### `Ornith-1.0-35B-MXFP8`

Current run: as of 2026-07-11 · build 563f91746 · catalog 8632f992dc0872b5 · 1 contribution(s) · by Michael Meding.

| Domain | Pass | Fail | Skip | Err |
| --- | --- | --- | --- | --- |
| agent_loop | 81% (83/103) | 20 | 21 | 0 |
| apple_script | 100% (16/16) | 0 | 19 | 0 |
| capability_claims | 75% (6/8) | 2 | 3 | 0 |
| computer_use_loop | 65% (15/23) | 8 | 0 | 0 |
| default_agent | 96% (27/28) | 1 | 0 | 0 |
| micro_perf | 100% (3/3) | 0 | 0 | 1 |
| subagent | 97% (34/35) | 1 | 12 | 0 |

Skipped areas:
- agent_loop: 21 — reasons unrecorded (pre-schema contribution)
- apple_script: 19 — reasons unrecorded (pre-schema contribution)
- capability_claims: 3 — reasons unrecorded (pre-schema contribution)
- subagent: 12 — reasons unrecorded (pre-schema contribution)

### `Ornith-1.0-9B-MXFP4` *(stale — needs a fresh run)*

Current run: as of 2026-07-05 · catalog 137408f3cdba4838 · 1 contribution(s) · by tpae.

| Domain | Pass | Fail | Skip | Err |
| --- | --- | --- | --- | --- |
| agent_loop | 72% (66/92) | 26 | 3 | 0 |
| apple_script | 77% (27/35) | 8 | 0 | 0 |
| capability_claims | 91% (10/11) | 1 | 0 | 0 |
| computer_use_loop | 57% (13/23) | 10 | 0 | 0 |
| default_agent | 68% (26/38) | 12 | 0 | 0 |
| micro_perf | 100% (3/3) | 0 | 0 | 0 |
| subagent | 96% (43/45) | 2 | 2 | 0 |

Skipped areas:
- agent_loop: 3 — reasons unrecorded (pre-schema contribution)
- subagent: 2 — reasons unrecorded (pre-schema contribution)

### `Ornith-1.0-9B-MXFP8`

Current run: as of 2026-07-10 · build 563f91746 · catalog 8632f992dc0872b5 · 1 contribution(s) · by Michael Meding.

| Domain | Pass | Fail | Skip | Err |
| --- | --- | --- | --- | --- |
| agent_loop | 74% (76/103) | 27 | 21 | 0 |
| apple_script | 100% (16/16) | 0 | 19 | 0 |
| capability_claims | 100% (8/8) | 0 | 3 | 0 |
| computer_use_loop | 61% (14/23) | 9 | 0 | 0 |
| default_agent | 93% (26/28) | 2 | 0 | 0 |
| micro_perf | 100% (4/4) | 0 | 0 | 0 |
| subagent | 97% (34/35) | 1 | 12 | 0 |

Skipped areas:
- agent_loop: 21 — reasons unrecorded (pre-schema contribution)
- apple_script: 19 — reasons unrecorded (pre-schema contribution)
- capability_claims: 3 — reasons unrecorded (pre-schema contribution)
- subagent: 12 — reasons unrecorded (pre-schema contribution)

### `gemma-4-12B-it-MXFP8`

Current run: as of 2026-07-10 · build 563f91746 · catalog 8632f992dc0872b5 · 1 contribution(s) · by Michael Meding.

| Domain | Pass | Fail | Skip | Err |
| --- | --- | --- | --- | --- |
| agent_loop | 78% (80/103) | 23 | 21 | 0 |
| apple_script | 100% (16/16) | 0 | 19 | 0 |
| capability_claims | 88% (7/8) | 1 | 3 | 0 |
| computer_use_loop | 96% (22/23) | 1 | 0 | 0 |
| default_agent | 93% (26/28) | 2 | 0 | 0 |
| micro_perf | 100% (4/4) | 0 | 0 | 0 |
| subagent | 94% (33/35) | 2 | 12 | 0 |

Skipped areas:
- agent_loop: 21 — reasons unrecorded (pre-schema contribution)
- apple_script: 19 — reasons unrecorded (pre-schema contribution)
- capability_claims: 3 — reasons unrecorded (pre-schema contribution)
- subagent: 12 — reasons unrecorded (pre-schema contribution)

History (superseded, not in the headline):
- 2026-07-04 · catalog 137408f3cdba4838 · 90% (223/247) · Apple M4 Pro (48GB) · by tpae

### `gemma-4-E2B-it-8bit`

Current run: as of 2026-07-10 · build 563f91746 · catalog 8632f992dc0872b5 · 1 contribution(s) · by Michael Meding.

| Domain | Pass | Fail | Skip | Err |
| --- | --- | --- | --- | --- |
| agent_loop | 46% (47/103) | 56 | 21 | 0 |
| apple_script | 100% (16/16) | 0 | 19 | 0 |
| capability_claims | 0% (0/8) | 8 | 3 | 0 |
| computer_use_loop | 57% (13/23) | 10 | 0 | 0 |
| default_agent | 21% (6/28) | 22 | 0 | 0 |
| micro_perf | 100% (4/4) | 0 | 0 | 0 |
| subagent | 94% (31/33) | 2 | 14 | 0 |

Skipped areas:
- agent_loop: 21 — reasons unrecorded (pre-schema contribution)
- apple_script: 19 — reasons unrecorded (pre-schema contribution)
- capability_claims: 3 — reasons unrecorded (pre-schema contribution)
- subagent: 14 — reasons unrecorded (pre-schema contribution)

### `gemma-4-E4B-it-4bit` *(stale — needs a fresh run)*

Current run: as of 2026-07-06 · catalog 137408f3cdba4838 · 1 contribution(s) · by tpae.

| Domain | Pass | Fail | Skip | Err |
| --- | --- | --- | --- | --- |
| agent_loop | 79% (73/92) | 19 | 3 | 0 |
| apple_script | 73% (24/33) | 9 | 2 | 0 |
| capability_claims | 82% (9/11) | 2 | 0 | 0 |
| computer_use_loop | 91% (21/23) | 2 | 0 | 0 |
| default_agent | 34% (13/38) | 25 | 0 | 0 |
| micro_perf | 100% (3/3) | 0 | 0 | 0 |
| subagent | 100% (45/45) | 0 | 2 | 0 |

Skipped areas:
- agent_loop: 3 — reasons unrecorded (pre-schema contribution)
- apple_script: 2 — reasons unrecorded (pre-schema contribution)
- subagent: 2 — reasons unrecorded (pre-schema contribution)

### `gemma-4-E4B-it-8bit`

Current run: as of 2026-07-10 · build 563f91746 · catalog 8632f992dc0872b5 · 1 contribution(s) · by Michael Meding.

| Domain | Pass | Fail | Skip | Err |
| --- | --- | --- | --- | --- |
| agent_loop | 81% (83/103) | 20 | 21 | 0 |
| apple_script | 100% (16/16) | 0 | 19 | 0 |
| capability_claims | 88% (7/8) | 1 | 3 | 0 |
| computer_use_loop | 96% (22/23) | 1 | 0 | 0 |
| default_agent | 29% (8/28) | 20 | 0 | 0 |
| micro_perf | 100% (4/4) | 0 | 0 | 0 |
| subagent | 97% (34/35) | 1 | 12 | 0 |

Skipped areas:
- agent_loop: 21 — reasons unrecorded (pre-schema contribution)
- apple_script: 19 — reasons unrecorded (pre-schema contribution)
- capability_claims: 3 — reasons unrecorded (pre-schema contribution)
- subagent: 12 — reasons unrecorded (pre-schema contribution)

### `Qwen3-4B-4bit` *(stale — needs a fresh run)*

Current run: as of 2026-07-05 · catalog 137408f3cdba4838 · 1 contribution(s) · by tpae.

| Domain | Pass | Fail | Skip | Err |
| --- | --- | --- | --- | --- |
| agent_loop | 72% (66/92) | 26 | 3 | 0 |
| apple_script | 85% (29/34) | 5 | 1 | 0 |
| capability_claims | 91% (10/11) | 1 | 0 | 0 |
| computer_use_loop | 91% (21/23) | 2 | 0 | 0 |
| default_agent | 63% (24/38) | 14 | 0 | 0 |
| micro_perf | 100% (3/3) | 0 | 0 | 0 |
| subagent | 100% (45/45) | 0 | 2 | 0 |

Skipped areas:
- agent_loop: 3 — reasons unrecorded (pre-schema contribution)
- apple_script: 1 — reasons unrecorded (pre-schema contribution)
- subagent: 2 — reasons unrecorded (pre-schema contribution)

### `Qwen3.5-4B-OptiQ-4bit` *(stale — needs a fresh run)*

Current run: as of 2026-07-06 · catalog 137408f3cdba4838 · 1 contribution(s) · by tpae.

| Domain | Pass | Fail | Skip | Err |
| --- | --- | --- | --- | --- |
| agent_loop | 90% (83/92) | 9 | 3 | 0 |
| apple_script | 83% (29/35) | 6 | 0 | 0 |
| capability_claims | 73% (8/11) | 3 | 0 | 0 |
| computer_use_loop | 65% (15/23) | 8 | 0 | 0 |
| default_agent | 82% (31/38) | 7 | 0 | 0 |
| micro_perf | 100% (3/3) | 0 | 0 | 0 |
| subagent | 96% (43/45) | 2 | 2 | 0 |

Skipped areas:
- agent_loop: 3 — reasons unrecorded (pre-schema contribution)
- subagent: 2 — reasons unrecorded (pre-schema contribution)

### `grok-4.3` *(stale — needs a fresh run)*

Current run: as of 2026-07-05 · catalog 137408f3cdba4838 · 1 contribution(s) · by tpae.

| Domain | Pass | Fail | Skip | Err |
| --- | --- | --- | --- | --- |
| agent_loop | 97% (89/92) | 3 | 3 | 0 |
| apple_script | 74% (26/35) | 9 | 0 | 0 |
| capability_claims | 100% (11/11) | 0 | 0 | 0 |
| computer_use_loop | 96% (22/23) | 1 | 0 | 0 |
| default_agent | 89% (34/38) | 4 | 0 | 0 |
| micro_perf | 100% (3/3) | 0 | 0 | 0 |
| subagent | 96% (43/45) | 2 | 2 | 0 |

Skipped areas:
- agent_loop: 3 — reasons unrecorded (pre-schema contribution)
- subagent: 2 — reasons unrecorded (pre-schema contribution)

## Device coverage

Distinct contributing machines (chip × RAM). Missing shapes are the most valuable contributions — see `reports/community/README.md`.

| Chip | RAM | Contributions | macOS |
| --- | --- | --- | --- |
| Apple M4 Max | 128GB | 5 | 26.5.1 |
| Apple M4 Pro | 48GB | 6 | 26.2.0 |

## Caveats

- `Ornith-1.0-9B-MXFP4`: stale — its newest run graded catalog `137408f3cdba4838`, older than the newest catalog in this report; a fresh `make evals-contribute` run would refresh the row.
- `gemma-4-E2B-it-8bit`: the current run self-judged an LLM-judged suite — those rubric grades are weaker.
- `gemma-4-E4B-it-4bit`: stale — its newest run graded catalog `137408f3cdba4838`, older than the newest catalog in this report; a fresh `make evals-contribute` run would refresh the row.
- `Qwen3-4B-4bit`: stale — its newest run graded catalog `137408f3cdba4838`, older than the newest catalog in this report; a fresh `make evals-contribute` run would refresh the row.
- `Qwen3.5-4B-OptiQ-4bit`: stale — its newest run graded catalog `137408f3cdba4838`, older than the newest catalog in this report; a fresh `make evals-contribute` run would refresh the row.
- `grok-4.3`: stale — its newest run graded catalog `137408f3cdba4838`, older than the newest catalog in this report; a fresh `make evals-contribute` run would refresh the row.
- `grok-4.3`: the current run self-judged an LLM-judged suite — those rubric grades are weaker.
