# Gemma3n E2B Post-Scrubber Text Sequence Review

Timestamp: 2026-05-18 17:42 PDT

Model: `gemma-3n-e2b-it-4bit`

App/API target: keychain-safe PR #1147 debug app on `http://127.0.0.1:4242`.

Purpose: rerun a small real Osaurus API sequence after removing the app-side
`ThinkTagScrubber` output repair. This is a behavioral artifact, not a
production-clear row.

## Result

Status: `FAIL/PARTIAL`

- Chat Completions and Responses T1 both returned coherent math:
  `2 + 2 = 4`.
- Chat Completions and Responses T2 both returned coherent short sky answers.
- Chat Completions T3 failed the exact literal UTF/string request, returning
  only `The sky is a clear blue. 🚀`.
- Responses T3 failed the exact literal UTF/string request and drifted into
  unrelated Chinese/emoji text instead of including `café 東京 🚀`.
- No visible raw `<think>` marker leakage was observed in these short outputs.
- Cache proof is absent in this run: the app's configured idle residency is
  `immediately`, health snapshots show no resident model after each request,
  and `/admin/cache-stats` counters remain zero.
- Memory proof is RSS-only. No Activity Monitor physical-footprint artifact is
  attached.

## Gate Consequence

This row does not support a production-ready claim for Gemma3n text. The
remaining issue is still a real runtime/template/tokenizer/decode or route
behavior problem. It must not be hidden with sampler clamps, repetition
penalty, forced stop/close tokens, prompt rewriting, parser output repair, or
output post-processing.

The next Gemma3n row should run with a residency/cache configuration that keeps
the model loaded long enough to capture prefix/block-L2 counters and should
include physical-footprint capture alongside TTFT/tok/s.
