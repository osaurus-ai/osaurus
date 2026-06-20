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
| `press-key-submit` | type a query then submit with `press_key` (`expectVerbsInOrder: [type, press_key]`) |
| `replace-note` | overwrite a pre-filled editable field exactly (`set_value` / `clear`) |
| `find-among-duplicates` | locate one uniquely-labeled control in a large list with duplicate labels (`find`) |

### Scripted (deterministic, model-free — run in CI via the `AgentStepProvider` seam)

| Case | What it proves |
|---|---|
| `recover-after-invalid` | a malformed first action triggers a re-ask; the run recovers and finishes |
| `recover-after-driver-error` | a stale-ref click (`clickFailures`) recovers via the coordinate fallback |
| `async-wait-load` | an async reveal (`revealAfterCaptures`) requires a `wait` before the control appears |
| `drag-reorder` | the `drag` verb resolves both `target` (start) and `to` (destination) and issues one coordinate drag |

## Adding a case

Drop a `*.json` file here (copy a sibling). For a CI-deterministic case, set
`scriptedActions` to the exact `agent_action` arguments-JSON the loop should
receive — then it runs with no model and is covered by the unit test above.
Otherwise it's a live-model case scored only when you run the suite with a model.
