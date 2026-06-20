# Apple Foundation context-window probe (W6)

Investigation + fix for the hard-coded `4096`/`.tiny` classification that
makes Apple's Foundation model skip every tool suite. The W6 question:
**is the 4096 window a real device limit, or a stale assumption — and if it
is real, is a minimal Foundation-only "tiny-tool mode" worth building?**

- **Date:** 2026-06-19
- **Host:** macOS 26.2 (Darwin 25.2.0, build 25C56), Xcode SDK 26.5, arm64.
- **Status:** **PROVEN** for the probe/reclassification fix (shipped, tested).
  **NO-GO (documented, not blocked)** for the tiny-tool prototype — feasible
  on budget, deferred on engineering cost + the 27.0 upgrade path.

## What was actually wrong

`ContextSizeResolver.resolve` special-cased the `foundation`/`default` alias
and returned a **hard-coded** `(.tiny, contextLength: 4096)`. The 4096 was an
assumption, not a measurement — so even hardware with a larger Foundation
window would still strip tools, memory, and skills.

## Measurement (the real window)

`SystemLanguageModel.contextSize` is `@backDeployed(before: macOS 26.4)`, so
the property works all the way back to the framework's macOS 26.0 floor — it
can be read on this 26.2 host even though the sibling `tokenCount(for:)` APIs
require 26.4. Direct probe on this device:

```
isAvailable: true
contextSize: 4096
```

So on the macOS 26.x baseline the hard-coded `4096` is **correct** — the
`.tiny` classification (tools + memory off) is honest here, not a bug. Per
Apple's WWDC sessions the on-device window is **4096 on the 26.x baseline and
8192 on 27.0+ hardware**, and `tokenCount(for:)` (input-token accounting,
incl. tool schemas) landed in 26.4.

## Fix shipped (dynamic probe, root-cause)

Replaced the hard-coded constant with a live, memoized read so the classifier
tracks the device truth instead of an assumption:

- `FoundationModelService.defaultModelContextSize` — `static let` (nonisolated,
  initialized at most once) that reads the back-deployed `contextSize`
  (guarded by `#available(macOS 26.0, *)` + `isAvailable`), or `nil` when
  Foundation is unavailable. Memoized because `ContextSizeResolver.resolve`
  is a pure, synchronous function called during UI layout and must not pay a
  framework round-trip per call or hop onto an actor.
- `ContextSizeResolver.sizeClass(forContextLength:)` — extracted the inclusive
  ceiling policy (`<= 4096 .tiny`, `<= 8192 .small`, else `.normal`) into a
  pure, unit-testable function shared by the Foundation probe and the MLX
  `config.json` path.
- `ContextSizeResolver.resolve` Foundation branch now reads the probe and
  classifies by the **real** value (falling back to `tinyCeiling` when
  Foundation is unavailable, which lands on `.tiny`). Foundation always sets
  `prefersCompactPrompt: true` (it is always a small on-device model).

Resulting device behavior (no per-device code, just the probe):

| Real window | Class   | Tools | Memory | Prompt  | Devices                |
| ----------- | ------- | ----- | ------ | ------- | ---------------------- |
| 4096        | `.tiny` | off   | off    | compact | macOS 26.x (this host) |
| 8192        | `.small`| **on**| off    | compact | macOS 27.0+ hardware   |

The chip in `FloatingInputCard` reads `info.contextLength`, so the
auto-disable popover now shows the probed window rather than a literal.

## Token-budget proof (`FoundationContextBudgetTests`)

Measured with the same `TokenEstimator` (chars/4) the runtime budget pipeline
uses. The full surface is a live `SystemPromptComposer` compose
(compact prompt + always-loaded sandbox / agent-loop / capability-discovery
schema); the minimal surface is a stripped prompt + 3 ultra-lean tools.

| Surface                  | Prompt | Tools | Total | vs 4096 window     |
| ------------------------ | ------ | ----- | ----- | ------------------ |
| **Full agentic**         | 2080   | 1756  | 3836  | 94% — 260 left (6%)|
| **Minimal (3 tools)**    | 93     | 168   | 261   | 6% — 3835 left (93%)|

Reads:

- **Full surface @ 4096 = structurally infeasible.** 3836/4096 leaves 260
  tokens — not enough for a user message + multi-step transcript growth + the
  response reservation. This is the concrete reason the probe must keep
  Foundation `.tiny` (tools off) at the 4K baseline.
- **Full surface @ 8192 = fits.** 3836/8192 ≈ 47% leaves ~4356 tokens, so the
  probe-driven `.small` reclassification on 27.0+ hardware safely turns the
  **full** tool surface back on (memory stays off per `.small`).
- **Minimal surface @ 4096 = feasible.** A stripped 3-tool mode is only 261
  tokens (93% headroom), so a tiny-tool mode is **not** budget-blocked.

## Tiny-tool mode: go/no-go = **NO-GO (defer)**, with evidence

The budget proof shows a minimal mode *fits*, so this is an engineering
decision, not a structural block:

1. **Parallel dialect cost.** A Foundation-native tiny-tool loop bypasses the
   entire Osaurus tool registry, capability-discovery/load flow, and sandbox
   security model. It is a separate, separately-maintained tool surface for a
   single provider — high carrying cost for a narrow window.
2. **Cannot be proven to AGENTS.md grade on this host.** The authoritative
   native-tool budget (`LanguageModelSession.tokenCount(for: tools)`) requires
   macOS 26.4+; this host is 26.2. Shipping a tool path I cannot prove live
   (exact args, parseable JSON, tool-result continuation, no marker leakage)
   would violate the runtime-proof rules, so no flag is shipped on spec.
3. **Superseded by the probe.** On 27.0+'s 8192 window the **full** surface
   already fits and turns on automatically, so a throwaway minimal dialect
   only ever serves the shrinking population of 4K-only devices.

**Revisit trigger:** a device reporting `contextSize == 4096` **on macOS
26.4+** (so `tokenCount` gives an authoritative native-tool budget) **and**
real product demand for Foundation tool use on 4K-only hardware. At that point
build the minimal mode behind a flag and gate it on a live `tokenCount`-backed
proof, not the chars/4 estimate.

## Reproduction

Live window probe (works on macOS 26.0+ via `@backDeployed`) — save and run
with `swift fm_probe.swift`:

```swift
#if canImport(FoundationModels)
import FoundationModels
if #available(macOS 26.0, *) {
    let model = SystemLanguageModel.default
    print("isAvailable: \(model.isAvailable)")
    print("contextSize: \(model.contextSize)")
}
#endif
```

Classification + budget proofs:

```bash
OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 OSAURUS_TEST_ROOT=/tmp/osaurus-test \
  swift test --package-path Packages/OsaurusCore \
  --filter 'ContextSizeClassTests'             # probe-derived + pure boundary

OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 OSAURUS_TEST_ROOT=/tmp/osaurus-test \
  swift test --package-path Packages/OsaurusCore \
  --filter 'FoundationContextBudgetTests'      # the 4K budget numbers above
```

## Touched

- `Packages/OsaurusCore/Services/Inference/FoundationModelService.swift`
  (`defaultModelContextSize` memoized probe).
- `Packages/OsaurusCore/Services/Chat/ContextSizeClass.swift`
  (`sizeClass(forContextLength:)` + probe-driven Foundation branch).
- `Packages/OsaurusCore/Tests/Chat/ContextSizeClassTests.swift`
  (probe-derived Foundation tests + 8192→`.small` boundary).
- `Packages/OsaurusCore/Tests/Chat/FoundationContextBudgetTests.swift`
  (full-vs-minimal 4K budget proof).
