# Installed vision evidence — implementation and proof

Status: PARTIAL. Implementation and focused checks are present; live Release
image generation and merge gates are pending. The original reporter's exact
bundle/error remain unavailable (Discord media returned HTTP 403).

## Change

`LocalVisionEvidence` reads nonempty architecture/processor configuration and
bounded headers from actual safetensors files. It verifies index entries against
the selected shards. Qwen2/2.5/3VL, Qwen35/MoE and Qwen4Exp require patch input,
every declared encoder block, and merger weights; Gemma4/unified require patch
input, declared encoder blocks, and the vision embedding projection. Other
registered VL architectures require encoder input and block weight evidence.
These checks establish installed component evidence, not full tensor-shape,
quantization, processor-forward or numerical correctness. Inference remains the
runtime loader's responsibility and is a separate live proof gate.

`VLMDetection`, local model metadata, composer/send capability resolution, and MLX
media preflight now use that evidence. The external locator is consulted by the
API detector too. Local model names no longer grant or deny media. Missing or
incomplete evidence remains unsupported with a reason. Explicit negative local
facts override stale picker/provider hints. A refresh at preflight prevents a
cached verdict from authorizing changed weights; invalidation generations prevent
an older scan from republishing its result after notification.

A new attachment that cannot be sent now raises a visible error before history
filtering rather than disappearing into a text-only message. Existing history
filtering on model switches remains. At model load, verified vision-bundle
expectations are reconciled with constructed modalities so a successful text
factory fallback cannot silently become the admitted model.

`qwen4_exp` now receives the video capability already implemented by its engine
architecture. This is a config architecture mapping, not a product-name pattern.
Audio evidence uses actual projection headers instead of an index substring.

The Core `swift-http-types` lock entry matches the existing app lock's 1.6.0:
the old 1.5.1 entry prevented SwiftPM tests from resolving NIO's FoundationURL
trait. No engine pin or sampler defaults changed.

## Recorded checks

Private evidence root:
`/Users/eric/vmlx-private-evidence/qwen-vision-2026-09-13/`.

- Focused Core: **154/154 tests, 8 suites**, 1.783 s after build. Suites:
  ModelMediaCapabilitiesMCDCTests, VLMDetectionTests,
  CapabilityFromDirectoryTests, MultiTurnCapabilityStabilityTests,
  CapabilityFromModelIdTests, ComposerAudioCapabilityTests,
  ChatAttachmentSecurityTests, RuntimePolicySourceTests.
  The initial run was 153/154 because an old source assertion required the
  name-based exclusion; that assertion was replaced with the shared evidence
  contract while retaining its unrelated compression/MTP assertions.
- Actual installed-bundle inspection: Gemma4 E2B 8-bit (2,649 total tensor names,
  27.9 ms); Qwen35-based Qwen3.8-27B-JANG_4D (2,379, 23.8 ms); Qwen4Exp
  Qwen3.8-Flash-Next-JANG_1L (3,257, 47.7 ms). All report image evidence; Qwen
  rows report video; Gemma E2B reports audio. Neutral, Step-looking, and
  Nemotron-looking aliases return the same result. This is not inference proof.
  Raw file: `installed-evidence-after.json` and `installed-evidence-test.log`.
- Synthetic tests cover null/empty config, missing weights/processor/input/block/
  projection, unsupported architectures, stale index, corrupt header, directory
  isolation, cache refresh/invalidation, provider fallback, and unsupported
  current attachments. They do not substitute for real app proof.

## Live rows still required

Fresh isolated Release app, same source and vMLX pin, with actual image payloads:

| Architecture | Local bundle | Required rows | Status |
| --- | --- | --- | --- |
| Gemma4 | OsaurusAI/gemma-4-E2B-it-8bit, snapshot 433003a1e3fbfd10819ad15179d5e3c4d02d7ea7 | image, follow-up, repeat/twin image | PENDING |
| Qwen35 | JANGQ-AI/Qwen3.8-27B-JANG_4D | image, follow-up, repeat/twin image | PENDING |
| Qwen4Exp | JANGQ-AI/Qwen3.8-Flash-Next-JANG_1L | image, follow-up, repeat/twin image | PENDING |

Record the visible answer/reasoning, token/s, physical footprint,
constructed model/processor, terminal state, and media cache behavior. Include
picker/composer/API parity and a rejected invalid-bundle row. The original
reporter repro cannot be declared fixed solely from these different bundles.

Earlier investigation and PR attribution:
[QWEN_VISION_REGRESSION_2026_09_13.md](QWEN_VISION_REGRESSION_2026_09_13.md).
