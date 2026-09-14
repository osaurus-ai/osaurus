# Qwen 3.6 / 3.8 vision report — Osaurus 0.25.1

Status: **PARTIAL — report documented; detector defects reproduced; reporter's
inference failure not reproduced or attributed.** No production fix or merge is
claimed. This investigation is separate from the RAM-admission PR #2752.

## Report and source boundary

PROTOTYPE-461Y-5K reports that Qwen 3.6 and 3.8 vision work in LM Studio but not
Osaurus 0.25.1, while Qwen3 VL works in Osaurus. Exact repository IDs,
quantizations, local-versus-provider routing, attachment type, and the error or
incorrect answer have not yet been supplied in readable form. Do not interpret
the family names as evidence of the installed architecture or checkpoint.

All three supplied Discord attachments returned HTTP 403 during this audit
(web access also failed). They have **not** been visually inspected:

- Osaurus screenshot: attachment `1548865942421905498`, `Screenshot_2026-09-14_at_04.10.39.png`.
- Osaurus screenshot: attachment `1548865943541776404`, `Screenshot_2026-09-14_at_04.18.55.png`.
- LM Studio screenshot: attachment `1548866112861773936`, `Screenshot_2026-09-14_at_04.20.46.png`.

The supplied signed URLs are retained in the private evidence directory below.
An asynchronous clarification asks for exact model IDs/quantizations, local or
provider routing, and whether attachment admission, a runtime error, or an
image-blind answer is the symptom. LM Studio's result is the reporter's evidence;
same weights, processor, format, and prompt between applications are unconfirmed.

Inspected source:

- Osaurus tag `0.25.1`: `e4734a216d9613e17ab42ca0de13f648e6b792f1`.
- Its actual package pin: vMLX `ffe9153f1ad8f8e8cf50ce8b95733656e44f7601`.
- Current app audit base: `7842b471310b631d19996f6fe5b73cb34deda70f`,
  vMLX pin `67ccb4b347a23820b838a98f0c195b0c29c676d2`.
- Worktree: `/Users/eric/osaurus-qwen-vision`, branch `fix/qwen-vision-evidence`.
  The dirty `/Users/eric/vmlx-swift` checkout was read only; engine inspection
  uses the app's pinned commits rather than that checkout's HEAD.

`VLMDetection.swift`, `ModelMediaCapabilities.swift`, and `ModelFamilyNames.swift`
are byte-identical between 0.25.1 and the audit base. This matters: the executed
detector probe below exercises the reported release's detector code too.

## Earlier fixes: yes, this failure class was addressed

These commits are ancestors of 0.25.1 or its actual engine pin, checked with
`git merge-base --is-ancestor`. Historical PR proof is not a current rerun.

| PR | Earlier defect and change | Current source assessment |
| --- | --- | --- |
| [Osaurus #795](https://github.com/osaurus-ai/osaurus/pull/795) | Dual-registered text-only models were classified as VL; images survived model switches into text runtimes. | Original fix history exists; modern detection still lacks weight validation. |
| [Osaurus #2389](https://github.com/osaurus-ai/osaurus/pull/2389), [vMLX #267](https://github.com/osaurus-ai/vmlx-swift/pull/267) | Qwen3.6-27B image crash: valid vision widths were absent from quantization inference, which could reinterpret 4-bit/group-128 as 8-bit/group-64. | Engine commit `e77cdf59` is included, not lost through a pin rollback. PR records an image GUI repro and image/tool/multiturn results; those are historical receipts. |
| [Osaurus #2427](https://github.com/osaurus-ai/osaurus/pull/2427) | `Qwen3.6-35B-A3B-6bit` accepted video in the composer, then the name-only send check silently removed it. | `ChatSession.selectedModelSendCapabilities` still shares the composer recipe. The specific repair remains. |
| [Osaurus #2442](https://github.com/osaurus-ai/osaurus/pull/2442) | HF/LM Studio/custom-folder bundles accepted in the picker were rejected at MLX preflight because capability lookup rebuilt the wrong path. | `MLXService.mediaCapabilityDescriptor` still consults `ExternalModelLocator`. That repair did not reach every other capability lookup. |
| [Osaurus #2504](https://github.com/osaurus-ai/osaurus/pull/2504) | Pinned the `qwen4_exp` Flash Next runtime and vision bridge. | Included, but Flash Next is not interchangeable with dense 27B merely because both are sold as Qwen3.8. |

## Executed findings, not just source hypotheses

The diagnostic compiles the unchanged production `ModelMediaCapabilities` and
`ModelFamilyNames` with a small driver. No detector is reimplemented or mocked.
It performs no model inference.

| Input | Observed image/video verdict | Significance |
| --- | --- | --- |
| Name only: `Qwen3.6-27B-4bit` / `Qwen3.8-27B-4bit` | false / false for both names | A remaining name-only fallback reproduces the *shape* of the report. It does not establish that this fallback was reached in the reporter's chat. |
| Name only: `Qwen3-VL-4B-4bit` | true / true | A product name grants executable media capability without a bundle. |
| `model_type=qwen3_5`, no vision stanza | false / false | Negative control. |
| Same type with `vision_config: null` | true / true | JSON null is counted as a vision configuration. |
| Same type with `vision_config: {}` | true / true | An empty, nonconstructible declaration is accepted. |
| Nonempty vision stanza; **no weights or processor files** | true / true | Config presence alone grants media capability. |
| Missing directory, VL-looking name | true / true | Missing evidence falls back to the name rather than an unknown/incomplete result. |
| Composer: false image fallback, local `qwen3_5`, VL-looking name | true / true | A name can override a negative local vision fact. |
| Actual local Qwen3.8-27B-JANG_4D bundle | true / true | Its directory route does recognize it. A global claim that all Qwen3.8 vision is disabled would be unsupported. |
| Same actual directory, neutral alias | true / true | Neutral renaming does not change this directory result. |
| Same actual directory, alias `Nemotron-3-Ultra-Local` | false / false | Name-based family rejection overrides the identical config and weights. |

Two local bundles were separately inspected through **actual safetensors
headers**, not just their index or capability stamps:

| Local bundle | Shards | Actual unique tensors | Vision namespace tensors | Index entries lacking backing header keys |
| --- | ---: | ---: | ---: | ---: |
| `JANGQ-AI/Qwen3.8-27B-JANG_4D` | 5 | 2,379 | 501 | 0 |
| `JANGQ-AI/Qwen3.8-27B-JANG_2D` | 4 | 2,379 | 501 | 0 |

Both resolve under `/Volumes/EricMLWork/models/JANGQ-AI/`. Their configs identify
`qwen3_5`, a nonempty vision configuration, and `Qwen3VLProcessor`. Header reads
record tensor names, shapes, dtypes, bounded offsets, and metadata/header hashes.
These facts do not prove compatible quantization, correct forward computation,
payload integrity, or usable inference. Neither is confirmed as the reporter's
bundle. No model download or generation occurred in this audit.

## Current source trace and remaining failure mechanisms

1. **P1: multiple capability authorities still disagree.**
   `Models/Configuration/VLMDetection.swift:67` accepts sidecar presence or
   `json["vision_config"] != nil`, without weights or processor validation.
   `ModelMediaCapabilities.swift:293` combines a name-derived result with a
   fallback bool; `:379` reads local config but falls back to names if unreadable.
   `MLXModel.swift:560` also rejects selected names before inspecting the bundle.
   The executed cases above demonstrate false positives and a name-driven denial.

2. **P1: local path and API parity remain incomplete.**
   `MLXService.swift:535` uses the external locator, while
   `VLMDetection.swift:121` reconstructs only the app-root path.
   `HTTPHandler.swift:5530,5670` calls the latter by model ID; the picker uses
   the `MLXModel.localDirectory`, and `/api/show` uses `ModelInfo.load` with a
   directory (`ModelInfo.swift:289`). An externally installed model can therefore
   produce different metadata through these paths. This is a source-traced risk;
   a live HTTP/UI mismatch is not yet captured.

3. **P1: rejected media can still become a text-only message.**
   `ChatView.swift:1689` allows the name matcher to return before the picker fact.
   `selectedModelSendCapabilities` (`:1725`) and
   `FloatingInputCard.mediaCapabilityDescriptor` (`:5188`) share a recipe but
   still depend on that mixed authority. `buildUserChatMessage` (`:2280`) filters
   attachment payloads by the booleans and emits plain text if none survive.
   A stale/missing false verdict could drop media; a false positive could send it
   to an incompatible runtime. No reporter transcript establishes which occurred.

4. **P1: successful text fallback can hide the original VLM load error.**
   At the 0.25.1 engine pin, `MLXLMCommon/ModelFactory.swift:815` tries VLM then
   LLM, retains VLM errors, but returns immediately if the next factory succeeds.
   Qwen35 has registrations in both factories. A processor/weight/config failure
   in the VLM path can therefore be obscured if the text path accepts the bundle.
   `VLMModelFactory.swift:832` prefers `preprocessor_config.json` wholesale over
   `processor_config.json`; split metadata can lose a processor class that exists
   only in the latter. The actual local bundles inspected here carry the expected
   class in the preferred file, so that specific failure is not reproduced.
   Capture `VMLX_MODEL_FACTORY_TRACE` and the constructed model/processor on the
   reporter's exact bundle before attributing this mechanism.

5. **P2: a protocol conformance is weaker than constructed capability.**
   At the release engine pin, `ModelFactory.swift:87` defines `isVLM` by
   `VisionLanguageModelProtocol` conformance. Construction can now omit the tower.
   Osaurus `ModelRuntime.swift:4442` records `container.isVLM`, not a reconciliation
   of requested, constructed, and weight-backed capability. Report those distinct
   facts; do not treat the bool as proof that image features were processed.

6. **P2: cache freshness needs a defined contract.**
   `VLMDetection.cachedVerdict` caches by path/ID until `.localModelsChanged`.
   In-place bundle repair/replacement and an in-flight computation publishing
   after invalidation need coverage. External scan code does emit the notification;
   there is no evidence yet that a missing notification caused this report.

## Other contributors' PRs reviewed

These are attribution candidates or exclusions, **not accusations of a confirmed
regression**. Review the changed function and reproduce with a matched bundle,
rather than assigning fault from authorship or merge date.

| PR / author | Relevant change | Assessment |
| --- | --- | --- |
| [vMLX #315](https://github.com/osaurus-ai/vmlx-swift/pull/315), [#359](https://github.com/osaurus-ai/vmlx-swift/pull/359) — rcfa | Qwen35 vision became optional; construction requests are propagated through the registry; absent towers cause vision weights to be dropped. | Highest-priority engine comparison because it touches exactly the affected construction. Counterevidence: `nil` requests build config-offered towers, and Osaurus's normal load has no explicit text-only construction request. No proven causal failure. |
| [Osaurus #2598](https://github.com/osaurus-ai/osaurus/pull/2598) — jjang-ai | First app pin containing #359: `2422cfb8`, after `de82613a` in #2587. | Concrete app bisection boundary for the construction change. The earlier Qwen fixes were retained. |
| [vMLX #311](https://github.com/osaurus-ai/vmlx-swift/pull/311) — rcfa | Declares dual-entry families and adds registry introspection/tests. | Relevant context; changed files do not replace the Qwen image forward path. |
| [vMLX #317](https://github.com/osaurus-ai/vmlx-swift/pull/317) — rcfa | Object-shaped patch-size decoding. | Changes Pixtral/Mistral processing, not Qwen's processor. Low relevance for native Qwen bundles. |
| [vMLX #455](https://github.com/osaurus-ai/vmlx-swift/pull/455) — tijs | Qwen35 routed-MoE compiled-decode policy shared between text and VL copies. | Could affect generation on the matching MoE configuration, not name detection or attachment inclusion; dense 27B is not that row. Exact model is needed. |
| [Osaurus #1374](https://github.com/osaurus-ai/osaurus/pull/1374), [#2203](https://github.com/osaurus-ai/osaurus/pull/2203) — RaajeevChandran | Capability memoization; external catalog generation caching and scan/UI work. | Freshness audit candidates. #1374 introduced the VLM cache; #2203 did not introduce that cache, though it changed nearby code. Both predate the August fixes. |
| [Osaurus #2562](https://github.com/osaurus-ai/osaurus/pull/2562) — tpae | Learned remote media-rejection recovery and Responses replay. | Potentially relevant only if this is a remote-provider report. Diff does not replace the local MLX detector. |
| [Osaurus #2630](https://github.com/osaurus-ai/osaurus/pull/2630) — RaajeevChandran | Tab/window ownership redesign. | Changed ChatView but did not alter the capability functions or image payload builder in the reviewed diff. No direct regression evidence. |
| [Osaurus #2660](https://github.com/osaurus-ai/osaurus/pull/2660) — jjang-ai | Lazy model loading on first Send. | Include cold-send versus already-loaded comparison. A timing change can expose stale pre-load facts even when detection functions are unchanged. |

## Required replacement: config AND weights, never local model names

The user explicitly rejects name-based VL enforcement. The implementation
contract is recorded here; **the production replacement remains open**:

1. Resolve a canonical installed directory once, including HF snapshots, LM
   Studio/custom folders, and symlinks. Retain a bundle-generation/fingerprint.
2. Inspect valid, non-null architectural config and processor metadata. Map
   `model_type` to the engine's implemented architecture/processor contract;
   never infer architecture from a display name or `-VL` suffix. Validate the
   encoder/projector dimensions and image token/processor contract.
3. Read bounded headers from the weight files the loader will actually use.
   Validate indexed keys against existing shard headers; an index, sidecar stamp,
   or one suggestively named tensor cannot establish a complete vision tower.
   Include the architecture's required encoder and projection/merger roles,
   quantization scales/biases where required, and accepted checkpoint namespaces.
   Do not union unrelated stale shard families into a fictitious complete model.
4. Produce one structured, cached result: available / absent / incomplete /
   unsupported runtime, with evidence and reason. Missing/unreadable config or
   weights means incomplete/unknown, not a name fallback. Explicit metadata and
   actual tensors disagreeing is a diagnostic, not an OR operation.
5. Feed that same result to model badges/picker, composer, send/history builder,
   MLX preflight, `/v1/models`, `/api/show`, and runtime diagnostics. Inspect off
   the main thread; invalidate by scan generation plus changed bundle identity.
6. After load, reconcile it with the actual model, processor, and constructed
   tower. A requested image must not silently downgrade to text after a failed
   VLM factory load. Surface the original typed failure and retain attachments.
7. Provider models require provider capability evidence, not local weight scans.
   Unknown provider support must remain explicitly unknown; do not invent local
   evidence or silently discard a payload the user attached.

Do not solve this by adding Qwen3.6/3.8 strings to a whitelist. Nor should a
generic `vision_config != nil && any vision-looking weight` replace the current
bug with a different false-positive test.

Required proof matrix: renamed identical bundle; misleading VL name on a text
bundle; null/empty config; config without weights; stale/incomplete index; weights
without compatible config; single-file and sharded/quantized layouts; external
directory parity; cold first Send, text-then-image without restart, repeated image
and fresh-chat image, image+tool continuation, model switch, cancellation, and
cache reuse with media identity. At least one exact reporter bundle must exercise
the real Release app and payload path. Record answer correctness, separate
reasoning, token/s, physical footprint, terminal state, processor/tower facts,
image/grid token counts, and architecture-appropriate cache telemetry. No sampler
or prompt masking.

## Reproduction and evidence

Private raw artifacts:
`/Users/eric/vmlx-private-evidence/qwen-vision-2026-09-13/`

- `capability-probe.json`: 12 executed production-detector observations.
- `bundle-evidence.json`: actual config and bounded tensor-header inventory for
  the two local bundles; no tensor payloads copied.
- `pr-history.json`: 17 PR records, changed files, authors, merge commits, and
  ancestry checks against the reported release.
- `construction-pin-history.json`: first app pin carrying the #359 change.
- `reporter-urls.txt`: the supplied attachment URLs.

Run from this worktree:

```sh
swiftc \
  Packages/OsaurusCore/Models/Configuration/ModelFamilyNames.swift \
  Packages/OsaurusCore/Models/Configuration/ModelMediaCapabilities.swift \
  scripts/diagnostics/qwen-vision-capability-probe.swift \
  -o /tmp/osaurus-qwen-vision-capability-probe
/tmp/osaurus-qwen-vision-capability-probe /path/to/installed/bundle
python3 scripts/diagnostics/vision-bundle-evidence.py /path/to/installed/bundle
```

Probe-source hashes at the audited release/current base:

- ModelMediaCapabilities: `91069b940c08cf171cd43cd0812163a381b13fdc600d09924150c7b4807480a1`
- ModelFamilyNames: `e4442596183950db2ccf4092d88fbc4eb6d753397a65a450eee8cdb8775b443a`
- VLMDetection: `91b35a039af19da878bfa66d90b870405cda44537c44ce086f0155940c61767e`

Live inference/UI verification is **missing**. Therefore this document establishes
the report, retained fixes, concrete detector defects, and a bounded regression
investigation plan; it does not establish a repaired Qwen vision runtime.
