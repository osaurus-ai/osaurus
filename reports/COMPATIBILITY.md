# Osaurus Model Compatibility (community)

Crowdsourced from 6 contribution(s). Verdicts: **works** (runs cleanly), **partial** (runs with errors or low pass-rate), **broken** (error-dominated / never scored).

| Model | Verdict | Pass | Contrib | Chips | RAM band | peak RAM | decode tok/s | builds |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `Ornith-1.0-9B-MXFP4` | works | 76% (188/247) | 1 | Apple M4 Pro | 48GB | 20614MB | 23 | — |
| `gemma-4-12B-it-MXFP8` | works | 90% (223/247) | 1 | Apple M4 Pro | 48GB | 20536MB | 13 | — |
| `gemma-4-E4B-it-4bit` | works | 77% (188/245) | 1 | Apple M4 Pro | 48GB | 19798MB | 21 | — |
| `Qwen3-4B-4bit` | works | 80% (198/246) | 1 | Apple M4 Pro | 48GB | 20583MB | 53 | — |
| `Qwen3.5-4B-OptiQ-4bit` | works | 86% (212/247) | 1 | Apple M4 Pro | 48GB | 20487MB | 35 | — |
| `grok-4.3` | works | 92% (228/247) | 1 | Apple M4 Pro | 48GB | 19637MB | 10 | — |

## Caveats

- `grok-4.3`: at least one contribution self-judged an LLM-judged suite — those rubric grades are weaker.
