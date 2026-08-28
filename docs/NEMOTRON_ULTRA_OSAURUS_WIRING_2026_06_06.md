# Nemotron Ultra Osaurus Wiring - 2026-06-06

## Scope

Model family: Nemotron 3 Ultra text reasoning bundles, including
`NVIDIA-Nemotron-3-Ultra-550B-A55B-JANGTQ_1L`.

This note tracks the Osaurus-side wiring that sits above the vMLX runtime pin.
It does not claim new decode speed. Current vMLX evidence keeps the resident
Swift row separate from the low-footprint mmap row:

- resident Swift decode: `8.1 tok/s`, bundle generation defaults, no loop, no
  parser leak, about 100 GB physical footprint.
- low-footprint mmap decode: `3.9-4.5 tok/s`, coherent and hybrid-cache
  correct, but still below the 8-10 tok/s target.

## Osaurus Fix

The chat composer previously allowed a generic `fallbackSupportsImages` bit to
promote an explicit text-only model id to image support. Nemotron Ultra is a
text reasoning model even when a bundle config contains generic vision-shaped
metadata. The composer now keeps non-Omni Nemotron reasoning ids text-only.

This keeps media routing aligned with the vMLX contract:

- Nemotron Omni remains image + video + audio.
- Nemotron Ultra remains text-only unless a future real Omni/VL bundle declares
  the correct family.
- Hybrid cache keys include the real Ultra ids so prefix-cache salt includes
  SSM companion topology for the production names.

## Validation

Focused source test:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift test --package-path Packages/OsaurusCore \
  --filter 'ModelMediaCapabilitiesMCDCTests|ModelRuntimeIsHybridTests|MLXBatchAdapterTests/cacheCoordinatorModelKey_alignsWithKnownHybridFamilies|MLXBatchAdapterTests/additionalContext_defaultsNemotronThinkingOffButHonorsExplicitOptIn' \
  --jobs 1 --no-parallel
```

Result: 53 tests passed.

Covered surfaces:

- Nemotron Ultra directory detection stays text-only even with `vision_config`.
- Nemotron Ultra composer fallback stays text-only when `fallbackSupportsImages`
  is true.
- Nemotron Ultra ids match the SSM hybrid cache-key path.
- Nemotron reasoning ids default local API context to `enable_thinking=false`
  while preserving explicit thinking opt-in.

## Live Osaurus Row - 2026-06-06

Keychain-free no-sign app build:

```sh
scripts/live-proof/build-keychain-free-osaurus.sh \
  build/DerivedData-keychain-free-nosign-bbd5d5ce
```

Result: build succeeded, ad-hoc signed app at
`build/DerivedData-keychain-free-nosign-bbd5d5ce/Build/Products/Release/osaurus.app`.

The app served the local model id
`nvidia-nemotron-3-ultra-550b-a55b-jangtq_1l` for the bundle at
`/Users/eric/models/NVIDIA-Nemotron-3-Ultra-550B-A55B-JANGTQ_1L`.

Cold row:

- Artifact:
  `/tmp/osaurus-bbd5d5ce-nemotron-ultra-tool-cache-20260606-071215`
- The three-turn required-tool harness passed parser and history checks:
  turn 1 exact `line_count` call, turn 2 visible answer, turn 3 exact
  `line_count` call after tool history.
- No tool marker, reasoning marker, or protocol text leaked.
- Cache topology was correct: 60 layers, 12 KV layers, 48 Mamba layers,
  `requires_disk_backed_restore=true`, and
  `requires_ssm_companion_state=true`.
- Cold cache movement stored blocks but did not prove reuse:
  `disk_l2_hits=0`, `disk_l2_misses=5`, `disk_l2_stores=4`.

Warm relaunch row using the same test-root disk cache:

- Artifact:
  `/tmp/osaurus-bbd5d5ce-nemotron-ultra-tool-cache-warm-20260606-071921`
- Harness result: `passed=true`, `failed_checks=[]`.
- Tool/history/parser checks all passed again with no marker leak.
- Warm cache proof passed:
  `disk_l2_hits=3`, `disk_l2_misses=3`, `disk_l2_stores=4`,
  `ssm_companion_hits=3`, and `companion_hits=3`.
- Runtime path was low-footprint MLXPress mmap:
  `mlx_press.backend=mmap`, `cold_fraction=0.7`,
  `weights_bytes=31680933825`.

Boundary:

- This proves Osaurus wiring, model autodetection, text-only media policy,
  required-tool parsing, tool-history replay, disk L2 warm restore, and SSM
  companion cache hits for the low-footprint app path.
- It does not change the speed boundary above: current release wording may
  claim `8.1 tok/s` only for the resident Swift row. The low-footprint mmap
  path remains a lower-speed path even though the warm cache row is correct.
