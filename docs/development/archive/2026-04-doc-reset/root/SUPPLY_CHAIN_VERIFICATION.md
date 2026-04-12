# Osaurus Supply Chain Verification & Safe Build Guide

## The Problem

Osaurus declares 13 direct dependencies and resolves to ~45 total (including transitive). Every one of those is pulled from GitHub at build time. If any upstream repo is compromised — a force-pushed tag, a hijacked maintainer account, a malicious transitive dep — that code compiles into the binary you run on your Mac with full user privileges.

You cannot eliminate this risk entirely without auditing every line of every dependency. But you can reduce it to a manageable level.

---

## Phase 1: Verify the Supply Chain

### Step 1 — Run the verification script

```bash
cd /path/to/osaurus
chmod +x scripts/verify_supply_chain.sh
./scripts/verify_supply_chain.sh
```

This checks every resolved dependency against its upstream remote:
- Confirms the pinned commit SHA actually exists
- Verifies version tags point to the expected commit (detects tag tampering)
- Flags branch-pinned deps with no version tag
- Detects version drift between the two lockfiles

### Step 2 — Fix branch-pinned dependencies

Three direct dependencies track mutable branches instead of immutable versions. Before building, pin them to the exact commits from `Package.resolved`:

Open `Packages/OsaurusCore/Package.swift` and change:

```swift
// BEFORE (dangerous):
.package(url: "https://github.com/osaurus-ai/mlx-swift", branch: "osaurus-0.31.3"),
.package(url: "https://github.com/osaurus-ai/mlx-swift-lm", branch: "main"),
.package(url: "https://github.com/rryam/VecturaKit", branch: "main"),

// AFTER (safe — uses the commits from Package.resolved):
.package(url: "https://github.com/osaurus-ai/mlx-swift", revision: "02b01f07e8c5cae22cd7fd1187e673d8d5de0db6"),
.package(url: "https://github.com/osaurus-ai/mlx-swift-lm", revision: "10d547ee65e16e9e9c20197623b29ab7c4952100"),
.package(url: "https://github.com/rryam/VecturaKit", revision: "5fed66f3700bee561326e719250aa01c49fc53d5"),
```

### Step 3 — Spot-check high-value dependencies

These deserve manual inspection because they have privileged access:

| Dependency | Why it matters | What to check |
|---|---|---|
| swift-secp256k1 (0.21.1) | Handles cryptographic keys | Confirm tag 0.21.1 on github.com/21-DOT-DEV/swift-secp256k1 matches commit `8c62aba8...` |
| Sparkle (2.9.1) | Auto-update framework — can replace the entire app | Confirm tag 2.9.1 on github.com/sparkle-project/Sparkle matches the resolved commit |
| containerization (0.30.0) | Runs sandboxed VMs | This is Apple's official repo — low risk, but verify the tag |
| VecturaKit | Third-party, was branch-pinned | Browse the actual code at the pinned commit — it's a vector DB, should be small |

To manually verify a tag:
```bash
git ls-remote --tags https://github.com/21-DOT-DEV/swift-secp256k1 | grep 0.21.1
# The SHA should match what's in Package.resolved
```

### Step 4 — Sync the two lockfiles

The project has two Package.resolved files that are out of sync:
- `Packages/OsaurusCore/Package.resolved` (newer versions)
- `osaurus.xcworkspace/xcshareddata/swiftpm/Package.resolved` (older versions)

This means builds via `swift build` and builds via Xcode may pull different code. Pick one as the source of truth and sync the other.

---

## Phase 2: Safe Build

### Option A — Fully offline build (most secure)

```bash
# 1. Resolve dependencies (this is the ONLY step that touches the network)
swift package resolve --package-path Packages/OsaurusCore

# 2. Verify the resolution didn't change anything unexpected
git diff Packages/OsaurusCore/Package.resolved
# If there are changes, inspect them. If a commit SHA changed, stop and investigate.

# 3. Build without allowing further network access
swift build --package-path Packages/OsaurusCore --skip-update

# Or via Make (which uses xcodebuild):
make cli
```

### Option B — Xcode build with frozen resolution

```bash
# Resolve first
xcodebuild -resolvePackageDependencies -project App/osaurus.xcodeproj -scheme osaurus

# Check for drift
git diff osaurus.xcworkspace/xcshareddata/swiftpm/Package.resolved

# Build
make app
```

### Option C — Maximum paranoia

```bash
# 1. Resolve deps
swift package resolve --package-path Packages/OsaurusCore

# 2. The resolved packages are cached in ~/Library/org.swift.swiftpm/
#    or in the DerivedData. Find the checkout directory:
find ~/Library/org.swift.swiftpm -name "VecturaKit" -type d 2>/dev/null
find build/DerivedData -name "VecturaKit" -type d 2>/dev/null

# 3. Manually inspect the checked-out source of any dep you're unsure about
#    Look for Process(), dlopen(), URLSession, or anything that touches disk/network

# 4. Once satisfied, build offline
make cli
```

---

## Phase 3: Post-Build Verification

### Check what the binary links against

```bash
# After building, inspect dynamic library dependencies
otool -L build/DerivedData/Build/Products/Release/osaurus-cli

# Check for unexpected dylibs or rpaths
otool -l build/DerivedData/Build/Products/Release/osaurus-cli | grep -A2 LC_RPATH
```

### Check code signing (if building the app)

```bash
codesign -dvvv build/DerivedData/Build/Products/Release/osaurus.app
```

### Run in a sandbox first

Rather than running the built binary with full access, test it in a restricted environment:

```bash
# Run with network access blocked (macOS sandbox)
sandbox-exec -p '(version 1)(allow default)(deny network*)' \
    build/DerivedData/Build/Products/Release/osaurus-cli status
```

---

## Ongoing Maintenance

After the initial verification, keep the supply chain locked down:

1. **Commit Package.resolved** — always. This is your lockfile. If it's not in version control, every build resolves fresh.
2. **Review lockfile diffs in PRs** — any change to Package.resolved should be reviewed like code.
3. **Never use `branch:` pins in production** — always pin to exact versions or revisions.
4. **Re-run the verification script** after any `swift package update`.
5. **Watch upstream repos** — GitHub's "Watch > Releases only" on critical deps like Sparkle and swift-secp256k1.
