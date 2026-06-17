# vMLX spec: tokenization (root cause found) + prefill/decode follow-ups

Target repo: `osaurus-ai/vmlx-swift`. This spec was rewritten after direct,
in-process instrumentation (`TokenizeDebugLog` in `VMLXTokenizers`,
`PrefillDebugLog` in osaurus) measured the real bottleneck on the user's model.
The earlier hypotheses (near-quadratic-in-prompt-length tokenization;
incremental tokenization as the main lever) were **wrong** and have been
replaced with the measured cause below.

## TL;DR

Per agent-loop step on M2 24 GB, gemma-4-12B-it-qat-JANG_4M, sandbox + 17 tools:

| Phase | Cost | Nature |
|---|---|---|
| **Tokenize (BPE encode)** | **~6.4 s every step** | recurring — **root cause below** |
| Jinja render | ~3 ms | negligible |
| GPU prefill, step 1 (cold) | ~70 s (incl. Metal kernel JIT) | one-time per process/prefix |
| GPU prefill, steps 2…N | fast (~965 tok/s, KV-reused) | not a recurring problem |
| Decode | ~10–19 tok/s | recurring; dominates file-writing turns |

The dominant **recurring** cost is tokenization, and it is **not** about prompt
length — it is one pathological pre-token. Fixing it is the highest-leverage win.

## Root cause: BPE merge loop is O(word_len²), fed an 11,035-char pre-token

Measured (`/tmp/vmlx-tokenize-debug.log`, gemma-4-12B-it-qat, sandbox + 17 tools):

```
RENDER agp=true renderMs=3.5 encodeMs=6332.7 chars=18991 tokens=4484 bpeMs=6324.8 bpeWords=298 bpeMaxWordLen=11035
RENDER agp=true renderMs=3.2 encodeMs=6493.5 chars=20557 tokens=4882 bpeMs=6485.5 bpeWords=304 bpeMaxWordLen=11035
RENDER agp=true renderMs=3.9 encodeMs=6480.7 chars=20894 tokens=5009 bpeMs=6471.3 bpeWords=310 bpeMaxWordLen=11035
```

- **`bpeMs` ≈ `encodeMs` (99.9 %)** — the entire ~6.4 s is the BPE merge loop
  `BPETokenizer.bpe(token:)` (`Vendors/swift-transformers/Sources/Tokenizers/BPETokenizer.swift:179-223`).
  Not normalize, not pre-tokenize, not id-lookup, not Jinja.
- **`bpeMaxWordLen=11035`** — one pre-token is 11,035 chars (~58 % of the whole
  18,991-char prompt). `bpe()` is O(word_len²) per merge (inner `firstIndex`
  scan + full pair rebuild), so an 11 k-char "word" is ~10⁸ ops × merge depth.
  That single word is essentially the whole 6.4 s; the other ~297 pre-tokens are
  normal-length and cheap.

### Why an 11 k-char pre-token exists
The chat template renders the tool schemas with **no whitespace** between
structural elements or between tools (osaurus's `Gemma4WithTools` fallback —
embedded in `MLXLMCommon/ChatTemplates/ChatTemplateFallbacks.swift`,
source-of-truth `Gemma4WithTools.jinja`). Description-less params and tools
chain together space-free
(`path:{type:<|"|>string<|"|>},mode:{type:<|"|>string<|"|>}…}<tool|><|tool>declaration:next…`),
and the pre-tokenizer splits on whitespace — so the run between two spaces grows
to 11 k chars. This is exactly why **tools + sandbox** specifically was
catastrophic, and why a tool-free / different-content run looked fast
(no giant word).

## Lever 1 — kill the giant pre-token / fix the quadratic (do both)

### 1a. Template whitespace (NOT cleanly viable — abandoned)
Adding newlines to the tool-schema rendering so no pre-token spans more than
~one param would bound `bpeMaxWordLen` and make even the O(n²) `bpe()` fast. But
the offending template **ships inside the model bundle**, and for JANG
weights-only bundles (`gemma-4-12B-it-qat-JANG_4M`, `source_model:
gemma-4-12B-it-qat-q4_0-unquantized`) the tokenizer + its `chat_template` resolve
through `JangLoader.resolveTokenizerDirectory` /
`resolveChatTemplateSidecarSubstitution` to the *source* model's cache — not any
file osaurus controls. Editing the bundle's `chat_template.jinja`, the bundle's
`tokenizer_config.json` `chat_template`, and the repo `gemma4WithTools` fallback
all produced **byte-identical output** (`bpeMaxWordLen=11035` unchanged) — none
is the active render path. So there is no clean, durable osaurus-side template
lever; do 1b instead. (A `VMLX_CHAT_TEMPLATE_OVERRIDE` override exists but is
per-model and fragile.)

### 1b. Linearize `BPETokenizer.bpe()` (vmlx-side, IMPLEMENTED)
The root defect is the O(word_len²) merge loop: the per-merge
`word[i..<].firstIndex(of:)` scan + full `getPairs` rebuild every round.
Replaced with `bpeFast` — a doubly-linked list of symbols plus a min-heap of
candidate merges keyed by `(rank, leftIndex)`; each merge is O(log n) and there
are O(n) merges → O(n log n). The original is kept as `bpeReference` (oracle +
fallback). Output is provably identical: a pair formed by a merge always outranks
the merge that created its components, so popping the globally-lowest
`(rank, leftIndex)` reproduces the reference's "merge all occurrences of the
min-rank pair per round, left-to-right"; stale heap entries are skipped on pop.

**Correctness gate:** `VMLX_BPE_VERIFY=1` runs both paths on every token and
falls back to the reference (logging `BPE-MISMATCH` to the tokenize log) on any
disagreement. Off by default (zero overhead). Validation protocol:
1. Run with `VMLX_BPE_VERIFY=1` → confirm **no** `BPE-MISMATCH` lines (fast ==
   reference on the real prompt). Encode stays ~6.4 s here because both paths run.
2. Run with the flag unset → `bpeMs`/`encodeMs` drop from ~6.4 s to ~tens of ms,
   while `bpeMaxWordLen` stays ~11,035 (the giant word is unchanged — it just
   tokenizes fast now). This is the win, on any model/template.

> Incremental / prefix-cached tokenization (the previous draft's main idea) is
> **deprioritized**: with 1a or 1b, a full encode is ~tens of ms, so caching the
> prefix saves little and adds correctness risk. Revisit only if encode is still
> material after 1a/1b.

## Lever 2 — GPU prefill: hide the one-time cold cost

The ~70 s step-1 prefill is **not** a per-step cost: it includes first-run Metal
kernel JIT, and steps 2…N run at ~965 tok/s with KV-prefix reuse (measured:
`STEP-PREFILL completed=4484/4879`, `STEP-STATS promptTps=965`). So this is a
once-per-process / once-per-new-prefix cost, not recurring.
- **Pre-warm (app-side):** prefill the static system+tools prefix in the
  background when a sandbox chat opens, so the cold ~70 s overlaps with the user
  reading/typing instead of landing on their first send. Must yield the solo
  GPU lease immediately when a real request arrives (the log shows
  `LEASE-ACQUIRED solo=true`), or have the real send adopt the partial progress.
- **Disk-L2 carryover (already built):** key is a stable SHA-256 over prefix
  token ids; store is synchronous before eviction; restore is content-addressed.
  Nothing to harden — see the cache findings. Pre-warming populates it so a
  second chat with the same prefix restores instead of recomputing.

## Lever 3 — decode throughput

Decode runs ~10–19 tok/s (`STEP-DECODE decodeTps`), which dominates turns that
generate large output (e.g. writing a file as tool-call arguments — ~150 s in an
earlier run). The only lever here is faster decode: speculative decoding
(`Libraries/MLXLMCommon/SpecDec/` exists) could ~1.5–2× it. Out of scope for the
tokenization work; tracked separately.

## Validation harness (in place)
- vmlx `/tmp/vmlx-tokenize-debug.log` (`VMLX_TOKENIZE_DEBUG=1`): per
  `applyChatTemplate`, `renderMs` / `encodeMs` / `bpeMs` / `bpeWords` /
  `bpeMaxWordLen` / `lcpBytesVsPrev`.
- osaurus `/tmp/osaurus-prefill-debug.log` (`OSAURUS_PREFILL_DEBUG=1`, also lights
  up the vmlx log): `COMPOSE` (token breakdown + static-prefix hash),
  `GENERATE-ENTER` / `LEASE-ACQUIRED` / `STEP-BEGIN` (tokenizedPrompt, lcp,
  cache deltas) / `STEP-PREFILL` (per stage) / `STEP-STATS` / `STEP-DECODE` /
  `STREAM-DRAINED` / `TOOL-EXEC`.

After 1a: `bpeMaxWordLen` should drop to a few hundred and `encodeMs` to ~tens of
ms, with the osaurus `LEASE-ACQUIRED → STEP-BEGIN` gap collapsing from ~6.4 s
accordingly. After 1b: the same holds even if a giant pre-token reappears.
