# Capability-claims mechanism-vs-outcome audit (W2 eval-trust)

Audit of the `capability_claims` suite to fix the **measurement** before
optimizing against it (W2 of the Osaurus Optimization Loop). Two cases
forced a discovery *mechanism* (`mustCallTools:[capabilities_discover]`)
that a correct frontier model legitimately skips, so the ceiling model
was failing on eval design rather than behaviour.

- **Date:** 2026-06-19
- **Suite:** `Packages/OsaurusEvals/Suites/CapabilityClaims`
- **Ceiling model:** `xai/grok-4.3` (self-judged, `JUDGE_MODEL=xai/grok-4.3`)
- **Raw artifact:** `/tmp/capclaims-grok-postw2.json` (re-baseline run)

## What changed

Two cases relaxed from mechanism-policing to **outcome-based**, with the
rationale written into each case's `notes`:

| case | before | after | why |
|---|---|---|---|
| `capability_claims.discover` | `mustCallTools:[capabilities_discover]` + rubric | rubric only | The browser capability is installed **and named in the Enabled-capabilities manifest** (`requirePlugins`+`enableSkills`+`enableTools`). The suite's own `no-spurious-discover` and `by-intent` cases *forbid* `capabilities_discover` for that same grounded capability, so forcing it here was self-contradictory and failed correct manifest-grounded answers. |
| `capability_claims.honest-absence` | `mustCallTools:[capabilities_discover]` + `mustNotCallTools` + rubric | `mustNotCallTools` + rubric | No fax capability exists anywhere in the catalog/manifest. The contract is honest refusal + no fabrication (both preserved). Forcing a discovery round-trip for an obviously-absent capability is exactly the over-tooling we want small models to *avoid*. |

The discovery/load **mechanism** stays covered by:

- `load-then-confirm` / `skill-first` — require `capabilities_load` for an
  actionable browser request (and skill-first ordering).
- `no-spurious-discover` / `by-intent` — require the model to NOT discover
  a manifest-grounded capability.

## Judge hardening (same workstream)

- `CapabilityClaimsEvaluator.parseVerdicts` rewritten: string-aware balanced
  fragment scan (braces inside a `reason` and ```json fences no longer break
  it), accepts envelope / bare-array / single-object shapes, tolerant
  booleans (`"yes"`/`1`/`"pass"`), and **index-aligned graceful degradation**
  — a judge that returns 2 of 3 verdicts only zeroes the ungraded one instead
  of blanket-failing the case. 14 unit tests in `CapabilityClaimsJudgeParserTests`.
- `EvalJudgeModel` resolves the judge: explicit `JUDGE_MODEL` wins; when unset
  it auto-upgrades to a strong remote judge whose API key is exported
  (`XAI_API_KEY` → `xai/grok-4.3`, then Anthropic/OpenAI/Gemini); self-judge is
  the last resort and is **warned loudly** so an unreliable grade is never
  silent. 7 unit tests in `EvalJudgeModelTests`. Wired into both runners and
  the remote-provider bootstrap.

## grok-4.3 re-baseline (ceiling)

`PASS=5 FAIL=3` of 8.

- **Recovered by this audit (FAIL→PASS):** `discover`, `honest-absence`. ✅
- **Steady PASS:** `confirm`, `no-spurious-discover`, `impossible-but-distinct`.
- **Triage list (NOT a W2 regression):** `by-intent`, `load-then-confirm`,
  `skill-first` failed because the machine's **active agent during the run was
  the "Osaurus configuration agent"** (browser-less). These cases use
  `AgentManager.shared.activeAgent.id` (no isolation, since they have no
  `ensureToolsDisabled`), so `capabilities_load` loaded nothing (`loaded=[]`)
  and grok *honestly* reported it had no browser tools in a config-agent
  session. The failures are an active-agent/environment artifact, and a
  standing **eval-trust gap**: browser `capability_claims` cases silently
  depend on the host's active agent being browser-capable. Recommended
  follow-up: stand up an isolated browser-capable eval agent for these cases
  (mirror `installCapabilityClaimsAgent`), so the result no longer depends on
  machine state. Tracked, not force-passed.
