# Osaurus Build Guide

This is the short build entrypoint for Osaurus.

For the detailed reference covering supply-chain verification, dependency
realities, the two lockfiles, local signing strategy, and troubleshooting, read:

- [docs/development/reference/BUILD_REFERENCE.md](/Users/mmeding/Documents/Claude/Projects/osaurus/docs/development/reference/BUILD_REFERENCE.md)

Last refreshed from the current repo state: `2026-04-12`

## Prerequisites

- Apple Silicon Mac
- macOS 15.5+ or macOS 26
- Xcode with command-line tools
- Metal Toolchain component
- `jq`

Install the Metal Toolchain if needed:

```bash
xcodebuild -downloadComponent MetalToolchain
```

## Before You Build

Verify the dependency graph first:

```bash
chmod +x scripts/verify_supply_chain.sh
./scripts/verify_supply_chain.sh
```

Important build truth:

- this repo has two independent lockfiles
  - `Packages/OsaurusCore/Package.resolved`
  - `osaurus.xcworkspace/xcshareddata/swiftpm/Package.resolved`

If you change dependency resolution, keep both in sync.

## Quick Build Paths

### CLI

```bash
make cli
```

### Install CLI

```bash
make install-cli
```

### Full App, Unsigned For Local Use

```bash
rm -rf build/DerivedData
xcodebuild -project App/osaurus.xcodeproj -scheme osaurus -configuration Release \
  -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build -quiet
```

## Package-Resolution Refresh

If CLI and Xcode builds disagree, re-check lockfile sync and re-resolve:

```bash
xcodebuild -resolvePackageDependencies -project App/osaurus.xcodeproj -scheme osaurus -derivedDataPath build/DerivedData
```

## Common Gotchas

- `cannot execute tool 'metal'`
  - Metal Toolchain is missing
- `AsrManager` or FluidAudio API mismatch
  - inspect both lockfiles and current FluidAudio-related PRs before changing code
- `unable to resolve module dependency`
  - clean `build/DerivedData` and rebuild
- build appears stuck
  - Metal shader compilation can take a long time; check `ps aux | grep metal`

## Current PRs Most Relevant To Building

- [#836](https://github.com/osaurus-ai/osaurus/pull/836)
  - build/runtime compatibility on the integration line
- [#838](https://github.com/osaurus-ai/osaurus/pull/838)
  - MLX runtime safety
- [#839](https://github.com/osaurus-ai/osaurus/pull/839)
  - FluidAudio / `SpeechService` compatibility

## If You Need More Than This File

Go straight to:

- [docs/development/reference/BUILD_REFERENCE.md](/Users/mmeding/Documents/Claude/Projects/osaurus/docs/development/reference/BUILD_REFERENCE.md)
