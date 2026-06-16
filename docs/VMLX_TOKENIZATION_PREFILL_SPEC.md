# vMLX spec: incremental tokenization + L2 prefix-cache carryover

Target repo: `osaurus-ai/vmlx-swift` (`MLXLMCommon`). These two levers cannot
live in the Osaurus app: tokenization runs in `context.processor.prepare(...)`
/ `context.tokenizer.encode(...)` and the disk cache lives in
`MLXLMCommon/Cache/{CacheCoordinator,DiskCache}.swift`.

## Evidence (measured on Osaurus, M2 24 GB, gemma-4-12B-it-qat-JANG_4M, sandbox + tools)

Per-step timeline captured via `PrefillDebugLog` (`GENERATE-ENTER` →
`STEP-BEGIN` is `prepareInput`; `STEP-PREFILL` stages are GPU prefill):

| Prompt tokens | `prepareInput` (tokenize+template) |
|---|---|
| 17,762 | ~89 s |
| 5,865 | ~10.5 s |

3.03× fewer tokens → 8.5× faster ⇒ **≈ O(n^1.9), near-quadratic.** Tokenization
is pure CPU work done *before* the GPU runs, and it is **redone in full every
agent-loop step** even though `lcpVsPrev` shows the entire previous prompt is a
byte-identical prefix (only ~90–120 new suffix tokens change per step).

Separately, the cold first-step GPU prefill of a *new* static-prefix hash was
~92 s for 5,865 tokens (~64 tok/s); a repeat run with the **same** prefix hash
restored from disk L2 in ~1–2 s, so cross-run carryover works when the prefix is
byte-identical.

## Lever 1 — fix the near-quadratic tokenization, then make it incremental

### 1a. Profile and remove the O(n²) hotspot (do this first)
The super-linear curve implies an accidental quadratic in the chat-template
render or the BPE/SentencePiece pre-tokenization (e.g. repeated full-string
scans, `String.Index` re-walks, or per-merge rescans). A purely *linear*
tokenize would already take the 5.9k-token case from ~10 s toward ~2–3 s and
help every large-context local model, independent of incrementality. Candidate
sites: the Jinja template apply over `tools` + system text, and the
pre-tokenization regex loop in the tokenizer.

### 1b. Prefix-cached / incremental tokenization
Add an opt-in cache on the processor keyed per model container:
- Cache `(lastRenderedString, lastTokenIds)` from the previous `prepare(...)`.
- On the next call, render the new prompt string, compute the longest common
  string prefix with `lastRenderedString`, then snap the reuse boundary **back
  to the last guaranteed-atomic split point** at/under that common prefix — i.e.
  the last special/control token (`<end_of_turn>`, `<start_of_turn>`, BOS) or a
  separator the pre-tokenizer always breaks on. Reuse the cached token ids up to
  that boundary; tokenize only the remainder; concatenate.
- **Correctness gate:** behind a feature flag, periodically (and in tests)
  assert `incremental(prefix+suffix) == full(prefix+suffix)` exactly; on any
  mismatch, fall back to full tokenization and disable the fast path for that
  model. This is the safety the app layer cannot provide — it requires the
  tokenizer's own merge/atomicity rules. The existing tokenizer test suites
  (`Tests/MLXLMTests/TestTokenizer.swift`, the Gemma scramble repros on the
  Osaurus side) are the regression backstop.

Expected: steps 2…N of an agent loop drop from ~10 s to ~tokenize-only-the-
suffix (~tens of ms), i.e. ~30 s saved on a 4-step turn at current prompt sizes,
and the win grows with prompt size because of the quadratic.

## Lever 2 — disk-L2 prefix-cache carryover reliability

Carryover already works for a byte-identical prefix; harden it so users pay the
cold prefill once-ever per prefix, not per app launch / per prompt edit:
- Confirm the L2 key is a hash of the static prefix **token ids** (not the raw
  string) and is stable across process launches; verify the store completes
  before eviction (the Osaurus side holds the solo lease until the producer
  drains, so the store has time — confirm the cache write isn't being dropped
  under the RAM-safety KV cap).
- Consider defaulting a small **paged RAM KV** budget on when headroom allows
  (post prompt-shrink, a ~6k-token KV is cheap on 24 GB), so within-session
  step-to-step reuse never round-trips to disk at all. Today paged RAM KV is off
  by default and reuse leans entirely on disk L2.
- Surface `restore`/`store` byte sizes + durations in the cache-stats payload so
  the Osaurus `/admin/cache-stats` endpoint can show carryover health.

## Validation harness (already in Osaurus)
`PrefillDebugLog` (`/tmp/osaurus-prefill-debug.log`, env `OSAURUS_PREFILL_DEBUG`)
emits `GENERATE-ENTER` / `LEASE-ACQUIRED` / `STEP-BEGIN` (with `lcpVsPrev`,
`tokenizedPrompt`) / `STEP-PREFILL` / `STEP-DECODE` / `STREAM-DRAINED`. After 1a/1b,
the `GENERATE-ENTER → STEP-BEGIN` delta on steps 2…N should collapse to near-zero;
after lever 2, a second fresh chat with an unchanged prefix should show the cold
step-1 prefill restore from L2 instead of recomputing.
