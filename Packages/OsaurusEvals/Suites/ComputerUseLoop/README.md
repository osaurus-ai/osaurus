# ComputerUseLoop suite

End-to-end Computer Use evals. The real `ComputerUseLoop` drives a deterministic,
in-memory `ScriptedCUDriver` (a fake macOS accessibility tree that mutates in
response to actions); the runner scores the resulting world state plus loop
telemetry. The model sees only the rendered `AgentView` (numbered marks, roles,
labels, values), never element ids or this scene definition.

See the schema reference (`expect.computerUseLoop` fields, driver knobs, scoring)
in the top-level [`README.md`](../../README.md#computer_use_loop-domain).

## Running

```bash
# Whole suite against a model (live-model cases need this; scripted cases ignore it):
make evals EVALS_SUITE=Packages/OsaurusEvals/Suites/ComputerUseLoop MODEL=foundation

# One case while iterating:
make evals EVALS_SUITE=Packages/OsaurusEvals/Suites/ComputerUseLoop FILTER=scroll-to-find MODEL=foundation
```

The scripted (model-free) cases below also run deterministically — with no model
— under the eval-kit unit tests in
`Packages/OsaurusEvals/Tests/OsaurusEvalsKitTests/ComputerUseLoopEvalTests.swift`,
which loads this directory, guards every scene from a decode regression, and
asserts each scripted case passes.

## Cases

### Live-model (exercise the model's planning / targeting / JSON discipline)

| Case | What it proves |
|---|---|
| `type-into-field` | basic perceive → type → verify |
| `compose-and-send` | multi-field fill then a consequential send |
| `toggle-switch` | flip a switch and confirm the toggled state |
| `reveal-then-set` | click to reveal a hidden control, then target the new field |
| `archive-not-delete` | precision among lookalikes + honoring a negative constraint (`failIfClicked`) |
| `read-and-report` | pure read: surface a value in the `done` summary, no mutation |
| `impossible-give-up` | recognize an unreachable goal and `give_up` cleanly |
| `scroll-to-find` | scroll a below-the-fold control (`revealOnScroll`) into view, then click it (`expectVerbsInOrder: [scroll, click]`) |
| `press-key-submit` | type a query then submit with `press_key`; Return on the focused field fills the results line (`onReturn`) so the submit is a verifiable change (`expectVerbsInOrder: [type, press_key]`) |
| `replace-note` | overwrite a pre-filled editable field exactly (`set_value` / `clear`) |
| `find-among-duplicates` | locate one uniquely-labeled control in a large list with duplicate labels (`find`) |

### Scripted (deterministic, model-free — run in CI via the `AgentStepProvider` seam)

| Case | What it proves |
|---|---|
| `recover-after-invalid` | a malformed first action triggers a re-ask; the run recovers and finishes |
| `recover-after-driver-error` | a stale-ref click (`clickFailures`) recovers via the coordinate fallback |
| `async-wait-load` | an async reveal (`revealAfterCaptures`) requires a `wait` before the control appears |
| `drag-reorder` | the `drag` verb resolves both `target` (start) and `to` (destination) and issues one coordinate drag |
| `web-form-proof-lab` | local static form fixture: fill fields, accept terms, confirm consequential submit, verify state, and keep evidence redacted |
| `done-without-verify-rejected` | a click the driver accepted but nothing observably changed; two `done`s → one challenge, then `gaveUp` ("could not be verified"), never success (`requireVerifiedChangeForDone`, `minUnverifiedActs`) |
| `unverified-act-reported` | the verify step reports a posted-but-unobserved input as unverified (feed "No visible change (input unverified)"), not "Action succeeded" |
| `open-not-ready-fails` | `open` whose readiness poll exhausted (`openNotReady`) + empty capture is reported "not ready", not "Opened" |
| `confirm-pause-extends-deadline` | a 1.2s user delay on the confirm card inside a 1s wall clock still ends `done` — confirm time is credited back (`wallClockSeconds`, `confirmDelaySeconds`) |
| `confirm-unavailable-fails-fast` | no surface can render the confirm card (`confirmUnavailable`) → gated action does not run, run ends `gaveUp` with the reason |
| `target-app-opened-behind` | the `app` argument (`targetApp`) opens the app before the first step, with no takeover question, and the click lands there (`expectVerbsInOrder: [open, click]`) |
| `takeover-declined` | no `app`: the user declines "Take over Mail?" (`declineTakeover`) → run ends `declined` with nothing perceived or clicked (`maxActsAttempted: 0`) |
| `return-submit-verified` | type → Return on the focused field applies the element's `onReturn` effect (two verified changes), so the following `done` is evidence-backed and the run ends `done` |
| `batch-stops-at-failure` | a `batch` runs its steps in order and stops at the first failure (`select` on a control with no option list); the step after it never runs, the edit before it stands |
| `batch-gates-each-action` | under `trusted`, each batch step passes the gate on its own: the navigate click runs, Delete confirms once and runs, then the batch stops before Archive (`minConfirms`/`maxConfirms: 1`) |
| `coordinate-click-classified` | `screenshot` then a `target.point` click (`vision: local`): the point maps to the Delete button, so the gate confirms Delete even though `describe` names Next |
| `zoom-is-read-only` | `screenshot` and `zoom` post nothing and request no confirm (`maxActsAttempted: 0`, feed "Zoomed in") |
| `select-and-hover` | `hover` posts a pointer move only; `select` picks a listed option (element `options`) case-insensitively in one step |
| `pixels-by-default` | with `vision: local` the first decision already carries a marked screenshot, so a `target.point` click works without a `screenshot` step |

Scene knobs added for these: `openNotReady`, `targetApp`, `declineTakeover`, `wallClockSeconds`,
`confirmDelaySeconds`, `confirmUnavailable`, `requireVerifiedChangeForDone`,
`vision` (`"local"` attaches screenshots as for an on-device image model,
`"none"` keeps every pixel from the model; unset, a model-driven case uses the
model's own vision posture with cloud-vision consent off, and a scripted case
gets no pixels),
element `onReturn` (effect of Return while that field is focused), element
`options` (titles `select` can pick); scoring fields: `minUnverifiedActs`,
`minVerifyChanged`, `feedTitleContains`, `minConfirms`, `maxConfirms`,
`maxActsAttempted`.

The scripted world lays elements out in a vertical stack inside a 1200×800
window: element *i* (0-based, in declaration order) spans x 40–240 and
y 60 + 40·*i* to 88 + 40·*i* in screen points. Screenshots are 600×400 pixels
(half scale), so a `target.point` of (x, y) lands at screen (2x, 2y). A `zoom`
renders its region at one pixel per point.

This suite is part of `make evals-deterministic` (floors: `ComputerUseLoop: 1.0`).
That lane sets `OSAURUS_EVALS_SCRIPTED_ONLY=1`, so the live-model cases above
SKIP (excluded from the pass rate) and only the scripted rows are scored — no
model is loaded.

A failed row's notes include a `trace:` line — every feed event as
`kind:title` in order (perceive/propose/act/verify/outcome) — so a live-model
failure can be attributed from the report without a re-run.

## Adding a case

Drop a `*.json` file here (copy a sibling). For a CI-deterministic case, set
`scriptedActions` to the exact `agent_action` arguments-JSON the loop should
receive — then it runs with no model and is covered by the unit test above.
Otherwise it's a live-model case scored only when you run the suite with a model.
