# Vision and idle-residency follow-up audit

Status: PARTIAL. The combined native app has not been built or exercised.
No claim of general model compatibility, regression freedom or merge readiness.

## Current source and evidence

- Combined runtime source: Osaurus `86294389f9d422e7c98fa3965205ba8a760cc6e9`,
  vMLX `6244dfe2c8715ae0ff68c43afb596b987573ade6`.
- Combined CI run `34941961952`: seven jobs succeeded. Its actual checkout
  `cf6a332874aaa12aadedc31a76c47510d4fd45d9` has the same tree as the combined
  branch. Core XCTest: 399 executed, eight skipped, zero failures; the
  SwiftTesting residency/configuration/telemetry suites completed. Scripted
  Evals: 118 passed, 15 skipped, 133 total. These are not native UI evidence.
- Current-engine installed image sweep: 28 passed, five failed, 33 selected
  from 79 inventoried bundles across ten architectures. This executable uses
  vision-only host `f1568966b2e3dfa832d01d5bbaeb4a537123df2e`, not the combined
  idle policy. GLM non-MTP's stream reached 1024 tokens with reasoning only and
  `finish_reason=length`; six other requests passed. Other failed bundles:
  Ornith9B2D, both ZAYA quantizations, and CRACK Qwen27B2D. Preserve the complete
  responses and the distinction between wrong colors and verbose answers.

Evidence directory:
`/Users/eric/vmlx-private-evidence/ornith-vision-2026-09-14/`.
See `glm-policy-full-matrix-receipt.json`, `vision-idle-ci-862-receipt.json`,
and the detailed internal `VISION-IDLE-EDGE-CASE-AUDIT-2026-09-15.md` ledger.

## Newly reproduced admission gaps

The production inventory advertised `supportsImage=true` for all three:

1. `processor_class=NotAnInstalledProcessor`.
2. Safetensors `dtype=NOT_A_DTYPE`.
3. A tensor with shape `[1048576]`, dtype `F32`, and only four payload bytes.

The nonempty-processor check in `LocalVisionEvidence.read` does not establish
that the processor is registered. The actual engine factory resolves its
processor override and calls `ProcessorTypeRegistry.createModel`, which rejects
an unknown processor type. The detector must consume that shared registration
and override contract; adding a second processor-name allowlist would preserve
the drift risk. Actual registration changes must remain visible to the check.

`LocalVisionEvidence.tensorNames` checks shape positivity and file offset bounds,
but does not validate dtype or shape-derived payload length. The engine's
`Source/Cmlx/mlx/mlx/io/safetensors.cpp` checks both when loading tensors.
The correction needs overflow-safe byte arithmetic and coverage for the actual
packed/quantized tensor storage types. Do not confuse logical quantization bits
with the safetensors payload dtype, or reject a supported bundle by guessing its
storage format from its name.

Run the new bounded, inference-free probe against an existing executable:

```sh
python3 scripts/live-proof/probe-vision-admission-edge-cases.py \
  --evals /absolute/path/to/osaurus-evals \
  --out /absolute/path/to/new-evidence-directory
```

Observed result: **five passed / eight checks**, exit 1, with the three false
positives above. Missing processor, missing encoder block, missing projection,
and unknown architecture were correctly rejected; the structural control was
accepted. The fixtures contain tiny real safetensors files, but are not runnable
models. This is admission proof only, not processor construction or inference.
The probe records the executable/script hashes and every observed verdict.
Raw receipt: `admission-edge-cases-script-0915/receipt.json` under the evidence
directory. Executable SHA256:
`ae04a7f8600b33fce3c16a20a2774ef2a8bea432e0b1844c7116b296b127ecbe`.
The relevant detector source is unchanged between that executable's host and
the combined source. Production corrections are now source-prepared; corrected-runtime proof remains pending.

## Questions that still require composed runtime proof

- Does the exact processor/config file precedence agree with the factory,
  including architecture overrides, aliases and accepted JSON syntax?
- Do unknown/renamed bundles retain the same capability under every catalog
  alias, and do unsupported attachments retain the user's draft?
- Does an identical media replay restore every architecture-specific companion
  and reproduce cold-prefill results? The GLM streamed failure is not yet
  causally attributed to cache state or model behavior.
- Does focused idle unload occur about 30 seconds after the final lease, and
  does a closed window unload promptly once active work finishes?
- Do another window, API request, child or parent handoff retain their own
  lease, including load cancellation and immediate retry?
- Does Keep Model Loaded default off, persist on across navigation/relaunch,
  and rearm a resident model when switched off? The old explicit 15-minute
  choice is indistinguishable from the former default during migration.
- Does SSD cache survive idle unload and app restart while volatile state is
  released, with a real cache hit and correct retained/changed-image answers?
- Do quota changes, corrupt payloads and cancellation preserve bounded disk
  usage and reject incomplete restoration without modifying live state?
- Do RAM safety, coexistence, handoff, concurrency and same-model batching
  compose across repeated children and parent continuation? A 128GB result
  cannot establish the reporter's 16GB behavior.
- Does sampled critical swap emulation leave the composer/send path free of
  the removed warnings, while consent and synthetic-event exclusion hold?
- Are video, audio, OCR and open-ended caption quality kept distinct from the
  narrow image/background-color qualification?

## Build dependency

After model evaluation ended, the unchanged build supervisor refused at
49.5 GiB kernel-free memory, normal pressure and 7.85 GiB swap, because its
inherited swap cutoff is 2 GiB. Exit 3; zero owned processes remained.
`SWIFTTEST_VisionIdleCombined862__010621.log` retains the receipt.
The September 15 continuation attachment repeats that status and permission
question; it does not answer the question. A subsequent read-only observation
at 09:11 UTC still found normal pressure and 7799.44 MiB swap, with no model or
build process running. No resource gate was changed.

Required next evidence: fresh combined app identity, actual controls and
screenshots, complete turns with token/s and Stop/input cleanup, then the full
affected matrix on any corrected source. The older app cannot qualify this
combined lifecycle change. The goal remains active.

## Source-prepared correction, not yet runtime-qualified

The follow-up pins engine `441d9a8e8df19f4c364b50903cbc62b4059639c9`.
The factory and admission check share processor resolution and live registry
membership. The registry registration version also invalidates cached verdicts.
SafetensorsPayloadSize validates the pinned native reader's stored dtype sizes
and computes payload length with overflow checks; it never reads tensor payloads
or uses the bundle's logical quantization bit count.

New Core regressions cover unknown processors, cached-negative invalidation after
registration, malformed dtype/length/overflow and all15native storage dtype sizes.
These are not executed results. The guarded engine-test invocation was refused
at48.1GiBkernel-free, normalpressure,7.48GiBswap>2GiB, before compilation:
`SWIFTTEST_VisionProcessorRegistryTests0915__022706.log`.

A separate real parser check used installed PythonMLX0.31.2 and safetensors0.7.0:
both accepted the tiny control and rejected invaliddtype/wrongbytecount fixtures.
That is an independent parser oracle, not the pinned Swift engine or new app.
Receipt: `admission-payload-parser-oracle-0915.json`.
A header-only scan of all33previously-admitted bundles found F16,BF16,U32,F32,I64,U8;
all are represented by the new validator. No tensor data or models were loaded.
Receipt: `vision-positive-dtype-audit-0915.json`. This metadata audit is not a
substitute for the corrected executable, full installed sweep or nativeUI.
