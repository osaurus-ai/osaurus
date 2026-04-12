# Build Reference

This is the detailed build, supply-chain, dependency, and troubleshooting
reference for Osaurus.

Use `BUILD_GUIDE.md` as the short entrypoint. Use this file when you need the
durable reasoning, exact gotchas, or the current build reality behind the quick
steps.

## Canonical Build Doc Stack

- `BUILD_GUIDE.md`
  - quick-start entrypoint
- `docs/development/reference/BUILD_REFERENCE.md`
  - durable build, lockfile, supply-chain, and troubleshooting reference

Historical source material folded into this document:

- `BUILDING_FROM_SOURCE_LESSONS.md`
- `SUPPLY_CHAIN_VERIFICATION.md`

## Environment Baseline

Last consolidated from current repo documentation on `2026-04-12`.

Expected environment:

- macOS 15.5+ or macOS 26
- Apple Silicon Mac
- Xcode with command-line tools
- Metal Toolchain component installed
- `jq` available for the supply-chain verification script

Install the Metal Toolchain if missing:

```bash
xcodebuild -downloadComponent MetalToolchain
```

## The Core Build Realities

### 1. There Are Two Lockfiles

This repo has two independent SPM lockfiles:

- `Packages/OsaurusCore/Package.resolved`
  - used by `swift build`, `swift package`, and package-first workflows
- `osaurus.xcworkspace/xcshareddata/swiftpm/Package.resolved`
  - used by Xcode and `xcodebuild`

They can drift. If you update only one, CLI builds and Xcode builds may compile
different dependency graphs.

Keep them aligned with one of these patterns:

```bash
cp Packages/OsaurusCore/Package.resolved osaurus.xcworkspace/xcshareddata/swiftpm/Package.resolved
```

or

```bash
xcodebuild -resolvePackageDependencies -project App/osaurus.xcodeproj -scheme osaurus
```

### 2. The Repo Uses MLX Forks

Relevant background:

- upstream PR [#769](https://github.com/osaurus-ai/osaurus/pull/769) switched the repo to Osaurus MLX forks
- later local work and PRs have needed additional care around MLX pinning and runtime behavior
- PR [#838](https://github.com/osaurus-ai/osaurus/pull/838) is part of that ongoing hardening work

Practical rule:

- do not casually update MLX dependencies without checking both lockfiles, the current forks, and the active PRs touching MLX behavior

### 3. FluidAudio Compatibility Has Been Moving

The repo has already hit API drift between `SpeechService` and the resolved
FluidAudio version.

Relevant current context:

- PR [#836](https://github.com/osaurus-ai/osaurus/pull/836) carries compatibility and pinning work from the integration line
- PR [#839](https://github.com/osaurus-ai/osaurus/pull/839) isolates the `SpeechService` compatibility fix on a clean focused branch

Practical rule:

- if ASR-related build failures appear, inspect both lockfiles and the currently resolved FluidAudio revision before changing app code

### 4. Local Unsigned Builds Are Normal

The Xcode project is configured for the Osaurus team identity. For local builds,
override signing or switch to personal/local signing.

Command-line unsigned build:

```bash
xcodebuild -project App/osaurus.xcodeproj -scheme osaurus -configuration Release \
  -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build -quiet
```

## Supply-Chain Workflow

### Before Building

Read the lockfiles and verify what will actually be compiled.

Run the verification script:

```bash
chmod +x scripts/verify_supply_chain.sh
./scripts/verify_supply_chain.sh
```

What this checks:

- pinned SHAs exist upstream
- version tags still point to the expected commits
- branch-pinned dependencies are flagged
- drift between the two lockfiles is detected

### What To Treat As High-Risk

- branch-pinned dependencies
- force-moved or mismatched tags
- unexpected lockfile drift
- post-install or build scripts that fetch additional code or binaries
- dependencies with privileged responsibilities:
  - Sparkle
  - cryptography libraries
  - containerization/runtime libraries
  - model/runtime libraries

### General Lessons Worth Keeping

- audit before the first build, not after
- count transitive dependencies, not just direct ones
- if a project has multiple lockfiles, treat them as independent until proved otherwise
- after changing dependency versions, clean stale build artifacts before trusting the result
- inspect the built binary’s linked libraries before first execution if the dependency graph changed materially

## Quick Build Paths

### CLI Build

```bash
make cli
```

CLI install:

```bash
make install-cli
```

### Full App Build

```bash
rm -rf build/DerivedData
xcodebuild -project App/osaurus.xcodeproj -scheme osaurus -configuration Release \
  -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build -quiet
```

### Package-Resolution Refresh

```bash
xcodebuild -resolvePackageDependencies -project App/osaurus.xcodeproj -scheme osaurus -derivedDataPath build/DerivedData
```

## Safe Build Checklist

1. Run the supply-chain verification script.
2. Confirm the Metal Toolchain is installed.
3. Confirm both lockfiles are in the state you intend to build.
4. Clean `build/DerivedData` if dependency state changed.
5. Build the CLI first if you want the faster sanity check.
6. Build the unsigned app if GUI validation is needed.
7. Inspect output artifacts and linked libraries if a dependency change was involved.

## Troubleshooting

### `cannot execute tool 'metal'`

Cause:

- Metal Toolchain component is missing

Fix:

```bash
xcodebuild -downloadComponent MetalToolchain
```

### `AsrManager` API mismatch or missing method

Cause:

- FluidAudio version drift versus current `SpeechService` expectations

Fix:

- inspect both lockfiles
- inspect PRs [#836](https://github.com/osaurus-ai/osaurus/pull/836) and [#839](https://github.com/osaurus-ai/osaurus/pull/839)
- re-resolve only after deciding which dependency graph you actually want

### `unable to resolve module dependency`

Cause:

- stale compiled modules in `build/DerivedData`

Fix:

```bash
rm -rf build/DerivedData
```

Then rebuild from scratch.

### `swift package update` fixed CLI builds but not Xcode builds

Cause:

- only the package-side lockfile changed

Fix:

- sync the workspace lockfile too
- or re-resolve package dependencies through Xcode

### The build looks frozen

Possible cause:

- Metal shader compilation is slow and noisy

Check:

```bash
ps aux | grep metal
```

If Metal processes are active, the build is usually still progressing.

## Post-Build Verification

Inspect the built CLI binary:

```bash
otool -L build/DerivedData/Build/Products/Release/osaurus-cli
```

Inspect app signing metadata if relevant:

```bash
codesign -dvvv build/DerivedData/Build/Products/Release/osaurus.app
```

Optional first-run caution:

- prefer a constrained first run if you changed dependency state materially

## Relationship To Current PRs

- `#836` and `#839` are the most relevant public PRs for current build/runtime compatibility
- `#838` matters for MLX runtime safety and long-context pressure
- `#815` matters for runtime API expectations even though it is not a local build fix

When these PRs merge or close with a different resolution, update this file and
`BUILD_GUIDE.md`.
