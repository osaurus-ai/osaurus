# Runtime validation standard

This is the standard checklist for Osaurus + vmlx runtime changes that touch
model loading, generation, cache residency, reasoning, Jinja templates, media
inputs, tool calls, or sampling defaults.

The goal is not "one smoke passed." The goal is enough evidence to know which
topologies are covered, which are intentionally gated, and which still need a
real-model run.

## Ground rules

- Record the exact Osaurus SHA, vmlx-swift-lm SHA, mlx-swift SHA, swift-jinja
  SHA, model bundle path, model revision, and Package.resolved entries.
- Do not claim speed, cache, or coherence from source reading alone. Source
  tests are contract guards. Runtime claims need logs or benchmark artifacts.
- Do not close system-prompt injection from source reading alone. A source trace
  must show the configured agent prompt reached the composed static prompt, and
  a live model probe must show the selected runtime obeyed it.
- Keep cache claims topology-specific. "Cache works" is not a valid result.
  Say which cache tier was used and which model cache family was exercised.
- Test both the direct engine path and the Osaurus app/API path when the change
  affects user-visible behavior.
- Preserve bundle generation_config defaults unless a model-specific reason is
  proven from a failing run.
- Never use fake parser transitions, forced tool calls, or hidden sampling
  shims as a substitute for fixing prompt, template, parser, or config wiring.
- Treat workspace, app-project, and package-level `Package.resolved` files as
  part of the runtime contract. They must agree on the vmlx, mlx-swift, Jinja,
  and swift-transformers revisions and org fork URLs.

## Required artifacts

Every manual or nightly run should write a folder such as:

```text
build/runtime-validation/YYYYMMDD-HHMM/
  summary.json
  runs.jsonl
  osaurus.log
  vmlx.log
  package-pins.txt
  ui-notes.md
```

Each `runs.jsonl` row should include:

```json
{
  "osaurus_sha": "...",
  "vmlx_sha": "...",
  "model_id": "...",
  "model_path": "...",
  "model_type": "...",
  "quant": "mxfp4|jangtq4|jangtk|fp16|...",
  "architecture_bucket": "dense|moe|swa|ssm|linear|cca|mla|vl|omni",
  "turn": 2,
  "prompt_tokens": 3472,
  "media": {"images": 0, "videos": 0, "audios": 0, "salt": "..."},
  "cache": {
    "tier": "paged|disk|none",
    "hit": true,
    "boundary_tokens": 3430,
    "path_dependent": false
  },
  "timing": {
    "submit_ms": 20,
    "processor_prepare_ms": 45,
    "prompt_ms": 146,
    "ttft_ms": 320,
    "tokens_per_second": 32.5
  },
  "generation": {
    "stop_reason": "stop|length|cancelled|error",
    "generated_tokens": 96,
    "reasoning_tokens": 25,
    "unclosed_reasoning": false,
    "tool_calls": 0
  },
  "memory": {
    "rss_peak_bytes": 0,
    "mlx_cache_bytes_peak": 0
  },
  "verdict": "pass|fail|blocked"
}
```

## GitHub checks

These checks should run on every PR that changes runtime code, package pins, or
model-family detection.

### Pin integrity

Fail if any of these are true:

- `Package.swift` or any tracked `Package.resolved` references a local path
  such as `/Users/...`.
- The workspace and app resolved files disagree on vmlx-swift-lm, mlx-swift,
  swift-jinja, or swift-transformers.
- A required org fork resolves to an upstream URL when Osaurus expects the
  osaurus-ai fork.
- vmlx, mlx-swift, or Jinja code needed by Osaurus is uncommitted while
  Osaurus pins an older SHA.

Suggested job:

```sh
swift package resolve --package-path Packages/OsaurusCore
swift package resolve
mkdir -p build/runtime-pin-check
runtime_pins() {
  jq -r '.pins[]
    | select(.identity=="vmlx-swift-lm"
      or .identity=="mlx-swift"
      or .identity=="jinja"
      or .identity=="swift-transformers")
    | [.identity, .location, .state.revision] | @tsv' "$1"
}
runtime_pins Packages/OsaurusCore/Package.resolved > build/runtime-pin-check/core.tsv
runtime_pins App/osaurus.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved > build/runtime-pin-check/app.tsv
runtime_pins osaurus.xcworkspace/xcshareddata/swiftpm/Package.resolved > build/runtime-pin-check/workspace.tsv
diff -u build/runtime-pin-check/core.tsv build/runtime-pin-check/app.tsv
diff -u build/runtime-pin-check/core.tsv build/runtime-pin-check/workspace.tsv
rg -n '/Users/|huggingface/swift-jinja|huggingface/swift-transformers' \
  Packages/OsaurusCore/Package.swift \
  Packages/OsaurusCore/Package.resolved \
  App/osaurus.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved \
  osaurus.xcworkspace/xcshareddata/swiftpm/Package.resolved && exit 1 || true
```

### Osaurus no-load contract tests

These are fast CI checks for wiring and policy. They do not prove model quality.

Run at least:

```sh
swift test --package-path Packages/OsaurusCore \
  --filter 'ModelRuntimeMappingTests|MultimodalContentPartTests|MaterializeMediaDataUrlMCDCTests|ModelMediaCapabilitiesMCDCTests|VLMDetectionTests|MultiTurnFamilyMatrixTests|LocalReasoningCapabilityTests|LocalGenerationDefaultsTests|GenerationEventMapperTests|MLXBatchAdapterTests|RuntimePolicySourceTests|ThinkTagScrubberTests'
```

Coverage expected from these tests:

- OpenAI content parts decode for text, image_url, input_audio, and video_url.
- `mapOpenAIChatToMLX` forwards images, videos, audios, assistant
  `reasoning_content`, assistant tool calls, and tool-role `tool_call_id`.
- Local reasoning policy is family-aware: Ling is non-reasoning, ZAYA defaults
  off unless explicitly opted in, Hy3 uses `reasoning_effort`, MiniMax and
  Qwen-family stamps resolve through vmlx.
- Media capability detection rejects bare text models that only look similar to
  VLM or omni names.
- Generation defaults from bundle/config and Osaurus overrides are merged
  without silently dropping top_k, top_p, temperature, min_p, stop strings, or
  KV settings.

### vmlx contract tests

Run on the vmlx repo before repinning Osaurus:

```sh
swift build --target MLXLMCommon
swift test --filter 'ReasoningParser|ReasoningStamp|GenerationConfig|Gemma4PLE|BatchEngineGrowingChatCache|Zaya|Cache|ToolCall|MultiTurnFamilyMatrix'
```

Required contract areas:

- `Chat.Message.reasoningContent` remains in the generated Jinja dict.
- `Chat.Message` media arrays copy into `UserInput.images`, `videos`, and
  `audios`.
- `Generation.reasoning` and `Generation.chunk` are mutually exclusive for the
  same bytes.
- Tool-call routing works on both content and reasoning rails when the family
  can emit calls there.
- JANG capability stamps for reasoning/tool parsers resolve by stamp first and
  by model_type only as fallback.
- Gemma 4 PLE config tolerance handles known non-PLE A4B configs without
  disabling real PLE when both PLE fields are present.

### Nightly real-model matrix

Run this on self-hosted hardware with local model bundles. It is too large for
normal hosted CI, but it should be required before runtime-heavy releases.

For each row, do at least three turns: cold turn, same-chat follow-up, and
follow-up after assistant reasoning/tool state. Record `runs.jsonl`.

| Bucket | Example families | Required checks |
|---|---|---|
| Dense KV | Qwen dense, Mistral dense | cold/warm TTFT, generation_config, stop/EOS, compiled decode on/off if enabled |
| Dense MoE | Qwen3.5/3.6 MoE, Laguna, Gemma MoE | top-k override honored, compiled router active where supported, no router fallback speed cliff |
| Sliding/rotating KV | Gemma 4 | PLE load, rotating cache behavior, image token path for VLM variants |
| Hybrid SSM/Mamba | MiniMax, Nemotron-H, Jamba, FalconH1 | SSM companion disk cache, no unsafe full-hit double count, reasoning/tool parser stamps, no cross-model cache poisoning |
| Linear attention | Ling/Bailing hybrid, LFM-style models | ArraysCache disk round-trip, non-reasoning policy where expected, no false paged-cache claim |
| CCA | ZAYA text/VL | ZayaCCACache state restore, reasoning toggle on/off, no CCA state corruption across turns |
| MLA/compressor | DSV4, Nemotron variants | compressor/cache restore, reasoning tags, EOS/stop tokens |
| Image VL | Qwen VL, ZAYA1-VL, Gemma VLM, Pixtral/Mistral VL | image token IDs, media salt isolation, repeated same image cache hit |
| Video VL | Qwen VL, SmolVLM, omni | data:video mp4 extension preservation, frame extraction, changed video cache miss |
| Audio/omni | Nemotron-Omni | input_audio temp-file materialization, audio sample prep, changed audio cache miss |
| Image generation | Z-Image, Flux, Flux2 Klein, Qwen Image, Kontext/Fill/Edit | exact local image-model autodetect, tokenizer/text-encoder load, safetensors key-map coverage, prompt-sensitive multi-turn PNG/JPEG output, edit/generation capability split, cancellation, unload/reload, and app/API parity |
| Tool calling | MiniMax, Qwen, Mistral, Laguna, Gemma | structured tool_calls, tool result turn, no XML-in-content fallback |

## Known Regression Classes

Use these as explicit release blockers when they touch the current branch:

- Stale resolver URLs: the app project, workspace, and package resolver records
  must not disagree on `osaurus-ai/Jinja`, `osaurus-ai/swift-transformers`,
  `osaurus-ai/vmlx-swift-lm`, or `osaurus-ai/mlx-swift`.
- Parakeet live streaming: independently encoded chunks are not safe to
  concatenate. Use retained PCM snapshots or fresh `.preEncoded` embeddings until
  a stateful/incremental Parakeet path has its own proof.
- Nemotron Omni default reasoning: call-mode/audio defaults should produce
  visible answer deltas unless the user explicitly opts into thinking.
- DSV4 long context: HSA top-k must mask future compressed chunks, and the
  overlap compressor must preserve previous complete ratio windows across
  decode calls. Raw `reasoning_effort=max` needs separate diagnostics before it
  is treated as a stable UI default.
- ZAYA1-VL detection: `zaya1_vl` and bundles with `vision_config` must route
  through VLM detection, not text-only ZAYA. Nested MXTQ/routed-expert bit
  metadata parse failures are runtime detection bugs, not user-facing media
  errors.
- Cache topology: CCA state, SSM companion state, DSV4 compressor state, dense
  KV, rotating KV, and media-salted VLM prompts require separate cache evidence.

## Manual UI checklist

Run after a fresh Release build from the same pins that will ship.

For each selected model:

1. Confirm the UI chip and debug log show the correct model.
2. Send `hi`. Record TTFT, stop reason, visible answer, and whether stop button
   returns to send.
3. Send a follow-up in the same chat. Confirm prefix-cache behavior by log, not
   by perception.
4. Toggle reasoning OFF, send a short prompt, confirm no reasoning pane and no
   leaked think tags.
5. Toggle reasoning ON, send a short prompt, confirm the expected family
   behavior:
   - non-reasoning families ignore or hide the control by policy;
   - reasoning families emit `.reasoning` when the template/model supports it;
   - final visible answer is separate from reasoning unless the family is
     explicitly configured otherwise.
6. Stop a generation mid-stream. Confirm cancellation yields terminal stats or
   a clear cancelled state and the input control unlocks.
7. For VLM/omni models, attach one supported media file and one unsupported
   media file. Confirm the unsupported file is rejected before submit.

Do not call a run "good" if only the first turn passed. Many regressions only
show on turn 2 or after prior assistant reasoning/tool state is serialized.

## Cache-specific probes

Every cache fix must answer these questions with logs or a test:

- Which cache family is active: `KVCacheSimple`, `RotatingKVCache`,
  `TurboQuantKVCache`, `MambaCache`, `ArraysCache`, `ZayaCCACache`,
  `CacheList`, or a batch wrapper?
- Which coordinator tier hit: paged memory, disk, or none?
- If the cache is path-dependent, was the stored boundary restored and then
  correctly advanced for the remaining prompt?
- Was the restored cache materialized before decode so TTFT does not hide
  deferred Metal work?
- Did media salt participate in the key when image/audio/video was present?
- Was a full hit treated differently from a growing-chat partial hit when SSM
  state would be double-counted by re-feeding the last token?
- Did stop reason `.stop`, `.length`, and `.cancelled` each do the intended
  post-answer storage behavior?

Minimum sequence:

```text
T1: new chat, no cache expected.
T2: same chat, same model, growing prompt, cache hit expected where supported.
T3: same chat after assistant reasoning_content or tool_calls, cache still valid.
T4: same chat with different media, cache miss or different media salt expected.
T5: switch model, then switch back, no cross-model cache poisoning.
```

## Reasoning and parser probes

Every reasoning-family change must test:

- Template context sent by Osaurus (`enable_thinking`, `reasoning_effort`, or
  family-specific field) in `MLXBatchAdapter.prepareInput`.
- vmlx parser stamp source: JANG stamp, model_type heuristic, or none.
- ON/OFF/ON toggle across three turns in the same chat.
- Prior assistant `reasoning_content` on the next prompt.
- Stream split: reasoning pane receives `.reasoning`; visible answer receives
  `.chunk`; no byte appears in both.
- Terminal `.info` arrives and `unclosedReasoning` is shown only when it is a
  real diagnostic.

For MiniMax, Qwen, ZAYA, Hy3, Nemotron, DSV4, and Gemma 4, do not assume a
shared tag contract. Check the bundle template, JANG stamps, and current vmlx
`ReasoningParser.fromCapabilityName` behavior.

## Performance probes

Separate these timings:

- App submit-to-engine time.
- Chat/tool/context build time.
- Jinja/template processor prepare time.
- Prompt prefill time.
- Restore/materialization time.
- First decode token time.
- Sustained decode tok/s.
- Model load time and peak resident memory.

If a user-visible TTFT is slow but `promptMs` is fast, inspect template render,
cache materialization, media preprocessing, and first-token decode before
calling it a cache miss.

## Runtime proof matrix appendix

Render the machine-readable classifier report into this appendix after a live
matrix run:

```bash
scripts/live-proof/render-runtime-proof-matrix.py \
  build/runtime-validation/YYYYMMDD-HHMM/PROOF_CLASSIFICATION.json \
  --update-doc docs/RUNTIME_VALIDATION_STANDARD.md \
  --json-surface build/runtime-validation/YYYYMMDD-HHMM/runtime-proof-surface.json
```

The renderer is source/UX only. It cannot promote proof rows; it only displays
the verdicts already written by `classify-runtime-proof-summary.py`. The schema
rows for #903 and #1163 stay `unproven` until live artifacts exist.

<!-- BEGIN RUNTIME PROOF MATRIX -->

Generated from PROOF_CLASSIFICATION.json at not generated in this checkout.

| Row | Model | Family | Verdict | Requirements | Evidence | Blockers |
|---|---|---|---|---|---|---|
| issue-903-system-prompt-injection-schema | all local chat runtimes | cross-family | unproven | visible_output, tokens_per_second, no_parser_marker_leak, multi_turn_coherency, system_prompt_injection | none | requires a live artifact with an explicit system-prompt injection probe, visible output, token/s, multi-turn coherency, and no parser marker leakage |
| issue-1163-hy3-harmony-retro-validation-schema | Hy3/harmony local rows | hy3 | unproven | visible_output, tokens_per_second, no_parser_marker_leak, multi_turn_coherency | none | requires a Hy3/harmony live artifact; sibling model rows or source-only parser checks do not prove this issue |

<!-- END RUNTIME PROOF MATRIX -->

## Recommended next tooling

Add these scripts as follow-up work:

- `scripts/runtime-matrix/run_osaurus_matrix.sh`: runs the live app/API matrix
  and writes `runs.jsonl`.
- `scripts/runtime-matrix/collect_logs.sh`: extracts structured Osaurus and
  vmlx logs for one run window.
- `scripts/runtime-matrix/compare_runs.py`: compares two validation folders and
  flags speed, stop-reason, parser, or cache regressions.
- `scripts/ci/check-package-pins.sh`: enforces remote pins and org fork URLs.
- `scripts/ci/check-runtime-policy-tests.sh`: runs the no-load tests above.

Also extend `MLXBatchAdapter.prepareInput` logs to include `videos`, `audios`,
and media salt. Existing logs include images, tool count, prompt tokens, and
context keys; audio/video need equal visibility for future omni/VL debugging.
