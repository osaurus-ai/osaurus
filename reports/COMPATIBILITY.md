# Osaurus Model Compatibility (community)

Crowdsourced from 11 contribution(s). Verdicts: **works** (runs cleanly), **partial** (runs with errors or low pass-rate), **broken** (error-dominated / never scored).

| Model | Verdict | Pass | Contrib | Chips | RAM band | peak RAM | decode tok/s | builds |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `Ornith-1.0-35B-MXFP8` | partial | 85% (184/216) | 1 | Apple M4 Max | 128GB | 14587MB | 17 | 563f91746 |
| `Ornith-1.0-9B-MXFP4` | works | 76% (188/247) | 1 | Apple M4 Pro | 48GB | 20614MB | 23 | — |
| `Ornith-1.0-9B-MXFP8` | works | 82% (178/217) | 1 | Apple M4 Max | 128GB | 10590MB | 29 | 563f91746 |
| `gemma-4-12B-it-MXFP8` | works ⚠ | 89% (411/464) | 2 | Apple M4 Max, Apple M4 Pro | 48GB–128GB | 20536MB | 13–27 | 563f91746 |
| `gemma-4-E2B-it-8bit` | works | 54% (117/215) | 1 | Apple M4 Max | 128GB | 13531MB | 38 | 563f91746 |
| `gemma-4-E4B-it-4bit` | works | 77% (188/245) | 1 | Apple M4 Pro | 48GB | 19798MB | 21 | — |
| `gemma-4-E4B-it-8bit` | works | 80% (174/217) | 1 | Apple M4 Max | 128GB | 16445MB | 30 | 563f91746 |
| `Qwen3-4B-4bit` | works | 80% (198/246) | 1 | Apple M4 Pro | 48GB | 20583MB | 53 | — |
| `Qwen3.5-4B-OptiQ-4bit` | works | 86% (212/247) | 1 | Apple M4 Pro | 48GB | 20487MB | 35 | — |
| `grok-4.3` | works | 92% (228/247) | 1 | Apple M4 Pro | 48GB | 19637MB | 10 | — |

## Device coverage

Distinct contributing machines (chip × RAM). Missing shapes are the most valuable contributions — see `reports/community/README.md`.

| Chip | RAM | Contributions | macOS |
| --- | --- | --- | --- |
| Apple M4 Max | 128GB | 5 | 26.5.1 |
| Apple M4 Pro | 48GB | 6 | 26.2.0 |

## Caveats

- `gemma-4-12B-it-MXFP8`: ⚠ mixed catalog hashes (137408f3cdba4838, 8632f992dc0872b5) — contributions graded different case sets, so the aggregate pass-rate mixes denominators.
- `gemma-4-E2B-it-8bit`: at least one contribution self-judged an LLM-judged suite — those rubric grades are weaker.
- `grok-4.3`: at least one contribution self-judged an LLM-judged suite — those rubric grades are weaker.
