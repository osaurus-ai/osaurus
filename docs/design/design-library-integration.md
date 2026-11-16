# Design library integration status

Where the app stands against the design handoff
(`design/ux-library-handoff-oct28`, merged in `b445b9792`, followed by PRs
18 to 20). Update this page when a gap closes.

## Verdict

The library is shipped. `LibraryResources/design-library.json` holds the
handoff's tokens and every assignment that paints, the shared styling is
unconditional (the former `OSAURUS_DESIGN_SYSTEM` flag is gone), and System,
Light and Dark all resolve through `DesignThemeOverlay`.
Custom themes, the chat tour, Pairing and the Project inspector were removed
on purpose (`162919fb0`, `16ed0f119`); none of that is a regression.

What is not finished: a few library values are placeholders that need
design sign-off before any component uses them, inspector layout coverage
shrank during the Settings refactors, and the Workflows screens listed below
still have no new design.

## Token coverage

All 170 library tokens resolve onto a typed `CustomTheme` property in both
appearances. `DesignLibraryTokenCoverageTests` enforces this: a token that
lands nowhere fails the suite unless it is added to that test's `untyped`
allowlist with a reason (the list is empty).

The engineering seeds (`CustomTheme.lightDefault` / `.darkDefault`) equal the
library in every value they carry (`SemanticTokenConformanceTests`);
regenerate them with `scripts/design-handoff/sync-theme-seeds.py`. Seeds hold
no effect layers, and one seed serves both modes, so `type.labelEmphasis`
(line height 22 in Light, 13 in Dark) is the one style that matches only
Light. The library adds the rest; on the seeds those fields are empty or take
the library's Light values:

| Library tokens | Theme property |
| --- | --- |
| `color.action.<kind>.<state>.border` (10) | `colors.action.<kind>.<state>.border`; `action.border(kind, state)` falls back to `action.border` |
| `color.action.brand.*` (12) | `colors.action.brand` (not a `ThemeActionKind`) |
| `color.surface.inverse`, `color.surface.none` | `colors.surface.inverse`, `.none` |
| `color.border.none` | `colors.border.none` |
| `type.chatBody`, `bodyEmphasis`, `subheading`, `labelEmphasis` | `ThemeTextStyleRole` cases |
| `radius.pill` (`"capsule"`) | `radius.pill: ThemeCornerShape`, drawn with `ThemePillShape` |
| `stroke.hairline` (formula) | `stroke.hairlineRule`; every `theme.hairline` reads it |
| `effect.elevation.none`, `.1`–`.4`, `effect.bevel.*` (9) | `effects` (`ThemeEffectRole`); views opt in with `.themeEffect(_:radius:)` |

No component mapping was changed to reach this. Today the badge corner and
the two Workflows step-number discs read the typed values; nothing draws the
brand action, the per-state borders, the new text styles or the effect
recipes yet. All 21 `*.effect` mappings point at `effect.elevation.none`.
(The family-25 input's `effect.elevation.2` was an archived copy that routing
never read; it was pruned with the other archives.)

## Assignment format

One rule: a mapping that is present paints; an absent mapping leaves the
component its own recipe. The shipped file therefore holds 8,558 assignments,
not the editor's ~19,400. `DesignLibraryPruning` drops copies that never
paint: shared-control archives, legacy keys shadowed by an element key,
layout slots the designer never set, the bubble properties owned by rich text
(28/29), and unedited properties of the composite families
(10, 13–17, 57). The file also records `editedAssignments` and `editedTokens`,
so the app never loads the handoff baseline; `semantic-tokens.json`,
`component-mappings.json`, `primitive-colors.json` and `figma-sync.json` ship
only with the Inspector. The Inspector edits the full document and exports it
pruned; `freeze-design.py` rejects an unpruned export.
`DesignLibraryPruningTests` freezes the count and the invariants above.

## Values that need design review

These look like export placeholders. They are exposed as typed values but
must not be assigned to components until Neesh confirms them through an
approved library export (`design-library.json` changes only that way).

- Every per-state action border in Dark is `#FFFFFFFF`, including brand.
- In Light, the tertiary and destructive default/hover/pressed borders are
  also `#FFFFFFFF`, which disappears on light surfaces.
- Bevels are available in only one appearance: `bevel.inset.brand` and
  `bevel.raised.brand` are Light-only, `bevel.inset.neutral` is Dark-only.
  Only `bevel.raised.neutral` exists in both.

## Inspector layout coverage

`CatalogLayoutAssignments.swift` lost 1,182 of its 1,773 layout keys during
the Settings refactors. Views fall back to their own numbers, so painted
pixels did not change, but those properties no longer appear in the catalog
inspector and cannot be retuned from the library. Restoring them is
per-component work; add keys back as each surface is touched.

## Screens without a new design

From `docs/design-handoff/REMAINING.md`. `Views/Workflow` has no
`catalogFamily` scopes yet.

- Workflow run form, progress, results, errors, retry and rerun.
- Sharing and publishing, including sign-in requirements and
  published-workflow management.
- Starter and import preview and setup.
- Nested step editors, graphs, examples, test history and
  save/version/conflict states.
- Run history, output files, stored data and saved answers.
