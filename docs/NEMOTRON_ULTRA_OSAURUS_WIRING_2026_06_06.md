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

