# Agent, Computer Use, and AppleScript 8B Proof Ledger

Last updated: 2026-07-16 (America/Los_Angeles)

Overall verdict: **PARTIAL.** Current `origin/main` contains earlier source
changes for spawned-agent tool selection, foreground app opening, and
AppleScript 8B catalog discovery. This branch adds the missing child execution
scope binding. The direct Calendar Agent row and two patched spawned rows ran
in the fresh isolated Release app with the exact MXFP8 control model after the
installed plugin was loaded. Computer Use app switching and AppleScript 8B
execution remain unverified, and a plugin hot-load stall plus test-root
isolation gap remain open adjacent findings.

## Scope and proof rules

- Runtime bundles come only from `~/models` (`/Users/eric/models`).
- Do not download, load, benchmark, or infer behavior from MXFP4 in this lane.
- Use the installed AppleScript 8B JANG_6M bundle for Computer Use proof:
  `/Users/eric/models/OsaurusAI/Osaurus-AppleScript-8B-JANG_6M`.
- A source row and a focused unit test are not live proof. Live claims require
  the exact Release candidate, an isolated bundle id and app root, visible UI
  settings, real model load/generation, and recorded output, token/s, physical
  footprint, and relevant tool/cache telemetry.
- Do not add forced prompts, hidden sampler overrides, parser repair, synthetic
  closers, silent output caps, or other behavior masking.
- Preserve unrelated vMLX and Osaurus work. The broad routing/hardware-guidance
  PR is not part of this follow-up.

## Current matrix

| Priority | Reported or adjacent row | Source status | Focused test | Live visual status |
| --- | --- | --- | --- | --- |
| P0 | Direct Calendar Agent has its enabled calendar/plugin tools | Direct-agent scoping resolved the installed `osaurus.calendar` plugin through the live registry | Existing focused suite does not cover the installed plugin | **PASS (VISUAL):** custom Calendar Agent pinned to `gemma-4-12B-it-MXFP8`, Browser disabled, Calendar 4/4 assigned; live UI showed failed typo recovery, capability discovery/load, `Get events`, grounded empty result, TTFT 0.97s, 31.2 tok/s, 34 tokens |
| P0 | `spawn_agent` child inherits the target Calendar Agent's own tool policy | **ROOT CAUSE REPRODUCED AND LOCAL FIX LIVE-VERIFIED:** child request receives target schemas, but registry execution inherited the parent request's `ToolExecutionScope`; local patch publishes a child scope from the exact child schemas | **PASS:** all 13 `SpawnToolsetTests`, including `agentToolDispatchUsesChildExecutionScope`, passed in the focused Xcode run | **PASS (VISUAL, PATCHED):** after the registry exposed Calendar 4/4, two spawned MXFP8 rows completed with grounded Calendar results; the original “not available in this conversation” rejection did not recur |
| P0 | Direct vs spawned Calendar tool schema, exact JSON arguments, tool result, continuation, second call | Direct runtime log captured valid JSON `{"ids":["plugin/osasaurus.calendar"]}` followed by structured `not_found` and recovery; patched child debug traces showed 15 exact schemas while parent had 9 | **PASS:** focused scope regression and 12 neighboring spawn tests | **PASS (VISUAL, TWO TURNS):** 2099-01-01...02 returned no events; same-chat 2099-01-03...04 returned a real Birthdays event. Parent rows were 31.2 and 39.3 tok/s; child rows were 31.3 and 31.7 tok/s |
| P0 | Installed plugin survives isolated-app relaunch and is registered before agent use | **ADJACENT RISK FOUND:** `ToolsPaths.root()` ignores `OSAURUS_TEST_ROOT`, while the keychain-disabled app deliberately skips startup plugin loading | NOT RUN | **FAIL/PARTIAL:** Calendar remained installed on disk and visible in Settings, but the first post-relaunch child had only 11 schemas and omitted Calendar 4/4 until the user pressed Plugins -> Refresh; the first generation immediately after hot-load then stalled for 112.3s and was stopped, while the next two stable-registry runs passed |
| P0 | Computer Use can leave the last-viewed window and visibly switch to another app | ADDRESSED IN SOURCE ON MAIN by PR #2032 (`69726a371`); `ComputerUseLoop.swift:1008` calls the driver with `background: false` | `ComputerUseEvidencePackTests.testOpenVerbLaunchesForegroundSoTheWindowIsVisibleAndVerifiable` PASS through Xcode | NOT RUN; reported stale-window behavior not yet reproduced or cleared |
| P0 | Computer Use returns to the original app and continues multi-step work | Source audit pending | NOT RUN | NOT RUN |
| P0 | AppleScript 8B appears under Settings -> Computer Use -> Models | ADDRESSED IN SOURCE ON MAIN by PR #2046 (`504d174ab`); `AppleScriptModelCatalog.swift:82,101-106` names the installed 8B bundle | Existing catalog/search tests still to identify and rerun | **PASS (VISUAL DISCOVERY ONLY):** Settings -> Computer Use -> Models displayed installed Osaurus AppleScript 8B (7.95 GB); 16B was available but not installed |
| P0 | AppleScript 8B JANG_6M selects, loads, warms, and executes real Computer Use | Local 7.4 GB bundle exists; Zaya/JANG_6M runtime path still to trace | NOT RUN | NOT RUN |
| P0 | 8B stays selected after relaunch and does not silently fall back to 16B | RISK FOUND: `AppleScriptModelCatalog.swift:160` automatic selection uses `installedModels().first`; with the catalog ordering this can choose 16B unless 8B is explicitly selected | NOT RUN | **PASS (VISUAL SETTINGS PERSISTENCE):** after rebuilt-app relaunch the popup still showed Osaurus AppleScript 8B; 16B remained available/not installed; Confirm each script, Keep Warm After Job, and Fast reads off all persisted. Runtime model id still requires execution |
| P0 | Computer Use permissions/settings toggles actually change runtime behavior | Source audit pending | NOT RUN | **PARTIAL:** Setup visibly reports Accessibility and Screen Recording granted; AppleScript Automation reports “Not yet granted.” No grant/test button was pressed, so execution behavior remains unverified |
| P0 | Memory Safety warning -> user changes setting -> intended large model can load | Existing memory-admission work is on main; exact UI/runtime contract still to trace | NOT RUN | NOT RUN |
| P0 | Re-enabling the safer RAM setting restores refusal/warning | Source audit pending | NOT RUN | NOT RUN |
| P1 | AppleScript 8B Thinking off/on, plain task, multi-step task, tool error, retry, and multi-turn | Bundle declares tool and reasoning capabilities; parser/template wiring still to trace | NOT RUN | NOT RUN |
| P1 | AppleScript 8B cold/warm TTFT, token/s, physical footprint, stop/cancel cleanup | Runtime telemetry surfaces exist; exact path pending | NOT RUN | NOT RUN |
| P1 | Computer Use wrong app name, app absent, minimized window, multiple windows, permission denial, app launch delay | Source audit pending | NOT RUN | NOT RUN |
| P1 | Spawned agent with no tools, disabled plugin, missing permission, denied tool, exhausted tool budget | Source path identified | NOT RUN | NOT RUN |
| P1 | Spawn/delegation RAM admission and visible insufficient-RAM notification | Source audit pending | NOT RUN | NOT RUN |
| P1 | Image generation/editing model RAM admission and safety-setting behavior | Deferred from the emergency pin PR; still required | NOT RUN | NOT RUN |
| P1 | Gemma 4 rotating-SWA TurboQuant default off, explicit toggle, prefix/L2 disk restore and truthful GB growth | Deferred from the emergency pin PR; still required | NOT RUN | NOT RUN |
| P1 | Qwen 3.5/3.5 VL hybrid SSM/GDN rederive plus TurboQuant/prefix/L2 restore | Deferred from the emergency pin PR; still required | NOT RUN | NOT RUN |
| P1 | Gemma/Bonsai regression sweep after any shared runtime change | Prior narrow ledger exists; follow-up head not yet exercised | NOT RUN | NOT RUN |
| P2 | MXFP4 structurally cut-off output fallback | DOCUMENTED ONLY in the Gemma/Bonsai ledger; explicitly excluded without an exact user-provided reproduction | NOT RUN | NOT RUN |

## Known current source evidence

### Current build and test state

The isolated app build started from exact Osaurus head `d16b06763` under
the proof bundle id `com.dinoki.osaurus.agentcuapplescriptproof`. Xcode resolved
the app's `vmlx-swift` dependency to implementation revision
`a26c7ecec950f18e3d07c8402fbd8c80f40ac764`. The ad-hoc signed Release app
launched with isolated root `/tmp/osaurus-agent-cu-applescript-root-d16b` and
local-model root `/Users/eric/models`. The patched Release executable was
regenerated at 2026-07-16 23:09 PDT and re-sealed ad hoc; `codesign --verify
--deep --strict` passed before relaunch. The direct and spawned Calendar rows
below use the same base and dependency revisions; the spawned rows use the
patched executable, while the direct row was captured from the pre-patch
Release artifact.

The first focused command used bare `swift test` and reached the test target,
but did not execute behavior tests because the selected toolchain could not
import Swift Testing (`no such module 'Testing'` from
`AgentCapabilityRowBuilderTests.swift:20`). That invocation is **BLOCKED**, not
a failure or pass of the spawn/Computer Use behavior. The equivalent selected
tests were then executed through the `OsaurusCoreTests` Xcode scheme at the
same head and vMLX resolution: all 12 existing `SpawnToolsetTests` and the
selected Computer Use foreground test passed. Xcode result bundle:
`/tmp/osaurus-agent-cu-applescript-focused-tests/Logs/Test/Test-OsaurusCoreTests-2026.07.16_22-32-19--0700.xcresult`.
These tests do not cover the legacy `nil` spawn mismatch or live app switching.

After the live failure isolated the child-versus-parent execution-scope bug, the
local patch added a focused regression and reran the complete selected spawn
suite. All 13 `SpawnToolsetTests` passed, including
`SpawnToolsetTests/agentToolDispatchUsesChildExecutionScope()`. Xcode result
bundle:
`/tmp/osaurus-agent-cu-applescript-focused-tests/Logs/Test/Test-OsaurusCoreTests-2026.07.16_22-56-25--0700.xcresult`.
That result was source/test evidence only; the separate patched Release live
evidence is recorded below.

The final combined run added the five `ToolExecutionScopeTests` and both
`ToolExecutionScopeWiringTests` to the same 13 spawn tests. Xcode reported
20 passed, 0 failed, and 0 skipped. Result bundle:
`/tmp/osaurus-agent-cu-applescript-focused-tests/Logs/Test/Test-OsaurusCoreTests-2026.07.16_23-25-22--0700.xcresult`.

### Spawned-agent capability ownership

Current main's `TextSubagentKind.resolveAgentTarget` stores the target agent's
own enabled tool specs using `agentChildToolSpecs(agentId:)`. The child toolset
combines those target-agent tools with any separately granted read-only tools,
deduplicates names, enforces a per-run call budget, and dispatches through
`ToolRegistry.shared.execute`. This is the correct ownership direction for the
reported Calendar case, but live proof must still show that the installed
calendar plugin is registered when the target agent is resolved and remains
available for each spawned iteration.

There is an uncovered legacy-state mismatch on the same path.
`AgentManager.effectiveEnabledToolNames(for:)` deliberately returns `nil` for
an unseeded agent, and direct chat interprets that as unrestricted access to
the current live registry. `TextSubagentKind.agentChildToolSpecs`, however,
uses `?? []`, turning the same legacy `nil` into a text-only spawned child.
Existing `SpawnToolsetTests` prove explicit `agentSpecs` union, allowlisting,
and call budgets; they do not exercise this manager-to-registry fallback. This
is a source-trace risk, not yet a reproduced live root cause. The visual matrix
must keep an explicit empty list distinct from legacy `nil`: disabled tools
must remain disabled while only the compatibility fallback gets parity.

The fresh-agent live reproduction found an additional, immediate failure after
schema construction. `/tmp/osaurus_debug.log` recorded the parent Assistant
request with 9 schemas (`spawn_agent` but no `get_events`) and the child request
with 15 schemas including `get_events`. `ToolRegistry.execute` enforces the
request's `ChatExecutionContext.toolExecutionScope`; `TextSubagentKind` built a
child allowlist but did not publish a child execution scope before dispatch, so
the child inherited the parent scope and received the registry's exact
`get_events is not available in this conversation` envelope. The local patch
creates one `ToolExecutionScope` from the child schemas and binds it around
every child dispatch. The one-scope-per-run lifetime preserves additive
`capabilities_load` activation. The focused child-scope regression and two
patched Release UI rows now pass. This evidence is specific to a freshly seeded
agent with the live Calendar registry present; legacy `nil` compatibility is
still a separate source risk.

### Patched spawned-Calendar live evidence

On patched Release relaunch, the chat label visibly remained `Gemma 4 12B it
MXFP8`. Runtime debug reported model id
`OsaurusAI/gemma-4-12B-it-MXFP8`, and `lsof` showed the process mapping the
13-shard local bundle at
`/Users/eric/models/OsaurusAI/OsaurusAI--gemma-4-12B-it-MXFP8`. The model
warmup completed in 4.35 seconds. This resolves the duplicate-display-name
ambiguity with process evidence; no MXFP4 bundle was loaded.

The keychain-disabled proof mode intentionally skipped plugin loading at
startup, so the first post-relaunch child had 11 schemas and no Calendar tool.
Settings -> Plugins still visibly showed Browser and Calendar installed. The
user-visible Refresh action loaded them and increased Tools from 59 to 84;
the live `/mcp/tools` surface then contained `create_event`, `get_events`,
`open_event`, and `search_events`. This is a proof-harness limitation plus a
real test-root isolation gap: `ToolsPaths.root()` resolves `~/.osaurus` instead
of honoring `OSAURUS_TEST_ROOT`.

The first generation immediately after that hot-load received all 15 child
schemas but produced no child delta or tool call for 112.3 seconds. It was
stopped from the UI and persisted the honest cancellation envelope. The next
clean new-chat retry completed:

- parent spawn JSON targeted `Calendar Agent` with the exact 2099-01-01 through
  2099-01-02 task;
- child ran 2 iterations in 3.49 seconds on
  `OsaurusAI/gemma-4-12B-it-MXFP8`, returned the grounded empty result, and
  reported 31.3 tok/s for 259 worker tokens;
- parent finished in 5.15 seconds with TTFT 1.19 seconds and 31.2 tok/s;
- cache telemetry reported 12 disk-L2 hits, 47 misses, and 18 stores.

A second prompt in the same chat delegated 2099-01-03 through 2099-01-04. It
returned a real all-day event from the Birthdays calendar, with the personal
title redacted from this GitHub-visible ledger. The child ran 2 iterations in
7.90 seconds at 31.7 tok/s for 428 worker tokens; the parent tool call took
9.59 seconds and its final row showed TTFT 1.08 seconds and 39.3 tok/s. Cache
telemetry reported 16 disk-L2 hits, 82 misses, and 25 stores. Post-run
`footprint` measured 2,071 MB physical footprint with a 4,738 MB peak for the
proof process.

### Direct Calendar live evidence

The isolated Release UI created `Calendar Agent` with an explicit
`gemma-4-12B-it-MXFP8` model selection. Its tool picker visually showed
Calendar 4/4 assigned and Browser 0/21. The read-only prompt requested events
from 2099-01-01 through 2099-01-02. Gemma first emitted a syntactically valid
`capabilities_load` call with the wrong semantic id
`plugin/osasaurus.calendar`; the host returned structured `not_found`, after
which the same run visibly showed `Searched capabilities`, `Loaded
capabilities`, and `Get events`. The final answer reported no events for that
range. The UI displayed TTFT 0.97s, 31.2 tok/s, and 34 tokens. This proves the
direct tool route and error recovery for this one prompt. The separate patched
spawned rows above prove fresh seeded-agent parity and a same-chat second turn;
legacy-agent compatibility remains unverified.

### Computer Use app switching

PR #2032 is present on main and is described as foregrounding apps on the
Computer Use open path. The actual driver, frontmost-app tracker, wait/observe
sequence, app-name resolution, and multiple-window behavior still need an
end-to-end trace. The report "stuck on the last window" remains unresolved
until a live run visibly switches apps and subsequent screenshots/AX context
track the new frontmost app.

### AppleScript 8B discovery

PR #2046 is present on main and added the Osaurus AppleScript 8B catalog row,
moved AppleScript model discovery to Settings -> Computer Use -> Models, and
redirected matching searches/imports away from the generic model catalog. The
exact local test bundle is installed and complete enough for runtime proof:
eight safetensor shards, tokenizer/template/config files, and 7.4 GB on disk.
Catalog visibility alone does not prove selection, load, execution, RAM, or
Computer Use app switching.

## Real-user questions that must be answered before promotion

1. Does the exact same Calendar Agent expose the same tool names and schemas in
   direct chat and when reached through `spawn_agent`?
2. If its plugin is disabled, unloaded, denied permission, or removed after
   agent creation, does both direct and spawned execution fail honestly rather
   than role-play success?
3. Does a spawned child retain its tools after one tool-result round and make a
   second grounded call without losing schema state?
4. Does Computer Use `open` make the requested app frontmost, wait until its
   window is actionable, and refresh both screenshot and AX context before the
   next model step?
5. What happens for an already-running app, minimized app, multiple windows,
   a localized/display-name mismatch, a missing app, and a delayed launch?
6. Can the model switch A -> B -> A in one run without acting on a stale frame
   or falsely reporting success?
7. Is AppleScript 8B discoverable from the documented Computer Use settings
   surface, selectable, persistent across relaunch, and never replaced by 16B
   without an explicit visible choice?
8. Does JANG_6M load through the exact bundled vMLX revision, produce coherent
   visible output and real AppleScript/Computer Use actions, report token/s,
   and remain within the intended physical-footprint gate?
9. Do Thinking, confirmation, screenshot/vision, automation permission, and RAM
   safety toggles all reach the runtime that actually performs the next task?
10. When Memory Safety blocks a model, does changing the documented user
    setting permit the next load, and does restoring the safer setting restore
    the warning/refusal without hidden MLX memory throttling?
11. Do cancellation, close-chat, and quit during 8B load or execution cleanly
    release the model and leave no zombie work?
12. After any shared fix, do Gemma and Bonsai still load, use tools, continue
    after tool results, avoid loops/marker leakage, and preserve truthful cache
    and RAM telemetry?

## Related prior evidence

`docs/GEMMA_BONSAI_EMERGENCY_PROOF_2026-07-15.md` is the authoritative prior
ledger for the merged schema-1 JANG loader pin, the still-partial Ornith
multi-step semantic failure, the deferred cache/RAM matrix, and why the
reported JANG_4M/MXFP8 behavior did not support a content-delta or tool-JSON
assembler diagnosis.
