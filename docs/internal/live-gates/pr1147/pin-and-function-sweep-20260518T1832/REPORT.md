# PR 1147 Pin and Function Sweep - 2026-05-18 18:32 PDT

Scope: source-level sweep for the consolidated `vmlx-swift` package switch after
the Osaurus PR pin moved to `0218591ed6ae02bf998a6ec6f8d204a89c26a7f7`.

This is not live model production proof. It only verifies that the active
Osaurus source, lockfiles, and policy tests agree on the current vmlx-swift pin
and continue to require the live UI/API/model rows documented elsewhere.

## Fix Applied

The app workspace lockfile and source-policy test still referenced the previous
vmlx-swift revision `0b85cad0a9d22d69ddeb787d7695b796fd00275b` while
`Packages/OsaurusCore/Package.swift` and the root workspace lockfile referenced
`0218591ed6ae02bf998a6ec6f8d204a89c26a7f7`.

Updated:

- `App/osaurus.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- `Packages/OsaurusCore/Tests/Service/RuntimePolicySourceTests.swift`
- `docs/VMLX_SWIFT_SINGLE_PACKAGE_SWITCH_2026_05_18.md`

## Current Pin Surfaces

All current pin surfaces now name:

```text
0218591ed6ae02bf998a6ec6f8d204a89c26a7f7
```

Checked surfaces:

- `Packages/OsaurusCore/Package.swift`
- `osaurus.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- `App/osaurus.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- `Packages/OsaurusCore/Tests/Service/RuntimePolicySourceTests.swift`
- `docs/VMLX_SWIFT_SINGLE_PACKAGE_SWITCH_2026_05_18.md`

## Function Policy Sweep

Source-policy coverage remains focused on the non-negotiable runtime boundaries:

- Osaurus has one direct inference package: `vmlx-swift`.
- Active Osaurus source imports vmlx-swift products (`MLX`, `MLXLLM`,
  `MLXVLM`, `MLXLMCommon`, `VMLINUXTokenizers`, `VMLINUXJinja`) instead of old
  direct inference/template/tokenizer packages.
- Transitive `swift-jinja` and `swift-transformers` entries in lockfiles are
  expected because vmlx-swift owns them. They are not direct Osaurus inference
  pins.
- Tool parsing, reasoning parsing, stop matching, media processing, and cache
  reuse remain engine-owned through vmlx-swift `BatchEngine` and
  `CacheCoordinator`; Osaurus maps typed events and must not repair parser
  output into a pass.
- Generation defaults must resolve from bundle metadata and explicit user/API
  settings. No model row may pass via hidden repetition floors, temperature
  clamps, forced `</think>` close tokens, parser repair, or name-only MTP.
- Current Osaurus chat-runtime policy still opts out of post-generation SSM
  re-derive for its mutating system-prefix workload. That is a source-locked
  Osaurus policy, not proof that all hybrid SSM rows are production-clear; live
  Ling/Hy3/Qwen hybrid rows still need cache-hit and async rederive artifacts
  where that feature is claimed.

## Verification

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --package-path Packages/OsaurusCore \
  --filter RuntimePolicySourceTests \
  --jobs 2
```

Result: 29 Swift Testing tests passed.

```sh
git diff --check
```

Result: passed.

## Remaining Gate

The package switch is still not production-clear from this sweep alone. The
remaining rows are live Osaurus UI/API/model rows with visible coherent output,
normal stop, no loops, no marker leaks, resolved generation defaults, cache
stats, TTFT, tok/s, RSS or physical-footprint context, media-state proof, and a
no-fake-guard review for each supported family.
