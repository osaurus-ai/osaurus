# Native effort selection qualification

Status: the preceding runtime integration is merged in Osaurus #3248
(`d564e542`). Further DSV4.1/M3.1 performance and quality investigations are
deferred. This change only consumes merged runtime #718 (`0f70a4f29`) and
exposes explicitly declared effort tiers alongside boolean thinking modes.

## Contract and implementation

Some bundles declare `chat.reasoning.efforts`, `effort_flag: reasoning_effort`,
`template_flag: enable_thinking`, and `think`/`no_think` modes together. The
runtime capability reader and Osaurus declaration reader must both recognize
that contract. The app uses the existing effort rail: None disables thinking,
Light sends native `low`, and High sends native `high`. Inherit retains the
bundle default. No sampler defaults, prompt guards, or thinking tags are added.
Canonical declarations keep their precedence; legacy keyless declarations keep
their existing absence semantics.

## Source evidence

- Runtime #718: explicit `efforts` alias and regression fixture. The merged
  runtime tree is identical to qualified head `f564e23a6`.
- `DeclaredReasoningEffort.toggleEffortList` validates the explicit toggle,
  effort key and transport before creating exact per-level template kwargs.
- `DeclaredReasoningEffortTests`: all 31 tests passed in canonical Debug
  configuration, including adapter context for None/Light/High.
- Full runtime build and 25 reader tests passed. The separate affected Spark
  parser/template/cache/activation/projection run passed 37 tests.

## Live evidence and limits

A fresh isolated Release app at consumer `9e0ae43c`, runtime `f564e23a6`, ran
on one local M5 Max with the private Raptor 0.7 bundle. The first app build
exposed only a toggle; that failure led to the app reader correction above.
The corrected agent editor and model picker exposed None/Light/High.

Three dependent Low/High/Off turns returned 42, 50, and 25 and stopped
naturally. Low/High showed closed reasoning rails; Off showed no reasoning
rail. Runtime cache scopes independently recorded low/high/off. Short
Low/High decode observations were 106.13/107.71 tokens/s; these are correctness
observations under concurrent compilation, not a matched-clock speedup claim.

Real terminal tool calls read an isolated marker file and ran a two-second
Python command. Both completed with exit code zero and grounded final answers;
tool cards settled and the composer unlocked. The first attempt without an
attached working folder failed normally and remains in the evidence record.
Displayed tool durations include permission waiting and must not be presented
as shell or model execution time.

The tool-result continuation restored 5,997 of 6,137 prompt tokens from disk
and prefetched only the remaining 140. Live topology was FP16 KV, 27 rotating
and 9 full layers, disk-backed restore, and zero effective paged KV layers.
This is not a TurboQuant layer claim. Owned weight loading was retained;
observed lifetime maximum physical footprint was about 5.98 GiB. This does not
qualify a low-footprint loading claim.

Private raw artifacts are retained under
`/Users/eric/vmlx-private-evidence/land-proven-raptor-20261102/`:
`RAPTOR-V2-APP-IDENTITY.json`, `RAPTOR-V2-LIVE-RESULT.json`,
`raptor-v2-runtime.log`, the memory trace, UI AX/PNG captures, and all initial
failure logs. No model weights, credentials, or raw UI captures are published.

## Remaining work

- Qualify the final consumer rebased on current main and pinned to the actual
  runtime merge commit; run CI and merge normally.
- Verify persisted agent and conversation choices in the final app.
- Additional fusion/cold-prefill optimizations require exact quantization and
  rounding parity plus matched live measurements. Existing fused paths remain
  enabled under their current shape/dtype gates; no unqualified port is added.
- Physical M2 Max prevention remains unconfirmed; the previously merged core
  guard is consumed by the landed runtime. Do not reopen the deferred model
  performance matrix as a prerequisite for this metadata fix.
- No release or tag is authorized by this qualification.
