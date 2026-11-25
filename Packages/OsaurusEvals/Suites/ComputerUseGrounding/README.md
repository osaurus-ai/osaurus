# ComputerUseGrounding suite

Point-in-box grounding for Computer Use models. The runner shows the model the
same synthetic screens Computer Use calibrates with (`GroundingCalibration`):
five app windows sized to the model's own frame budget, each with a grid of
labeled buttons, and asks it to click one named button. The screens have no
element list, so the schema offers only `click` with a `target.point`; it and
the prompt name no coordinate convention, so the model answers in the frame it
was trained on. Every answer is scored under pixels, 0–1000, and 0–1 of the image.
Target boxes are placed so no two frames can both hit.

A row passes when one frame alone hits at least `minHitFraction` of the screens
(default two thirds, the same bar a run uses to adopt a frame), matches
`expectFrame` when the case pins one, and agrees with any frame the bundle
declares in `jang_config.json` or states in its config files. Every live row
records decode token/s.

## Running

```bash
# Live row against a local vision model:
make evals EVALS_SUITE=Packages/OsaurusEvals/Suites/ComputerUseGrounding MODEL=<model-id>

# Model-free rows only (what the deterministic lane runs):
OSAURUS_EVALS_SCRIPTED_ONLY=1 make evals EVALS_SUITE=Packages/OsaurusEvals/Suites/ComputerUseGrounding MODEL=<model-id>
```

## Cases

| Case | Lane | What it proves |
|---|---|---|
| `point-in-box` | live | The model points at named buttons in one consistent frame, with token/s. |
| `scripted-pixels` | model-free | Screens fit the model's budget; pixel answers hit only under pixels. |
| `scripted-normalized1000` | model-free | 0–1000 answers hit only under 0–1000. |
| `scripted-unit` | model-free | 0–1 answers hit only under 0–1. |

## Fields (`expect.computerUseGrounding`)

| Field | Meaning |
|---|---|
| `minHitFraction` | Fraction of screens the measured frame must hit. Default 2/3. |
| `expectFrame` | `pixels`, `normalized1000`, or `normalizedUnit` the model must point in. |
| `scriptedFrame` | Answer without a model, at each target's center in this frame. |

Row notes list the frame budget, the bundle's stated frame, hits per frame,
each screen's point and which frames it hit (or the raw `agent_action`
arguments when they carried no point), step errors, and mean decode tok/s. A failed row ends with an `attribution:` line.
