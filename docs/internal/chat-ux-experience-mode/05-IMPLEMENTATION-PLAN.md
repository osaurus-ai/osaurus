# Implementation Plan (phased)

> Staged execution for the chat UX redesign, memory default flip, and experience mode
> presets. Each phase is a reviewable atomic commit. Don't start Phase N+1 until Phase N
> is reviewed and merged (or at least agreed on).
>
> All phase changes will be logged in a new `06-CHANGE-AUDIT.md` using the same
> per-change format as the vmlx-cache-migration audit (C-001 style entries).

---

## Phase ordering rationale

The phases are ordered so each one is shippable on its own. If we stop partway through,
the app is still in a working state with a useful subset of the redesign applied.

- **Phase 1** adds data model scaffolding + resolver + memory default flip.
- **Phase 2** adds the Experience Mode concept in Settings.
- **Phase 3** adds the Tools popover in the chat bar.
- **Phase 4** adds the first-launch onboarding.
- **Phase 5** is cleanup, tests, and docs.

---

## Phase 1 — Data model + resolver + memory default off

**Goal**: Schema changes land. Nothing in the UI moves yet. All the new fields exist with
sane defaults. The single precedence resolver gets written. Memory defaults to off.

### Files changed

| File | Kind | Change |
|------|------|--------|
| `Models/Chat/ChatConfiguration.swift` | add | `experienceMode: ExperienceMode?` + `experienceOnboardingSeen: Bool` fields |
| `Models/Chat/ExperienceMode.swift` | new | Enum + preset table |
| `Models/Memory/MemoryConfiguration.swift` | edit | Default `enabled` → `false` |
| `Models/Agent/Agent.swift` | add | `memoryEnabled: Bool?` (per-agent override — see D-7) |
| `Managers/AgentManager.swift` | add | `effectiveMemoryEnabled(for:)` |
| `Services/Inference/ModelService.swift` | add | `GenerationParameters.chatToolOverride: ChatToolOverride?` |
| `Services/Chat/ChatToolOverride.swift` | new | New struct + enum |
| `Services/Chat/ChatConfigurationResolver.swift` | new | Single resolver for all precedence decisions |
| `Services/Chat/SystemPromptComposer.swift` | edit | Use resolver instead of reading config directly |
| `Services/Memory/MemoryContextAssembler.swift` | edit | Use resolver for `effectiveMemoryEnabled` |
| `Tests/Configuration/ChatConfigurationResolverTests.swift` | new | Precedence tests |
| `Tests/Configuration/ExperienceModePresetTests.swift` | new | Preset-to-field mapping tests |

### Change granularity

- **C-U01**: Add `ExperienceMode` enum + preset table (no callers yet).
- **C-U02**: Add new fields to `ChatConfiguration`. Default `experienceMode = nil`.
- **C-U03**: Flip `MemoryConfiguration.enabled` default to `false`. Preserve explicit JSON values.
- **C-U04**: Add `Agent.memoryEnabled: Bool?`. Default `nil`. Extend `AgentManager` with
  `effectiveMemoryEnabled(for:)`.
- **C-U05**: Add `GenerationParameters.chatToolOverride`. Default `nil`. Plumb through
  `ChatEngine → MLXService`.
- **C-U06**: Add `ChatToolOverride` struct.
- **C-U07**: Add `ChatConfigurationResolver` with the precedence rules from §6 of DESIGN.md.
  Unit tested.
- **C-U08**: Migrate `SystemPromptComposer.resolveTools` to use the resolver.
- **C-U09**: Migrate `MemoryContextAssembler.buildContext` to use the resolver.
- **C-U10**: Add tests for the resolver (every precedence path).
- **C-U11**: Add tests for the preset-to-field mapping.

### Verification

- `swift test --filter ChatConfigurationResolverTests` passes.
- `swift test --filter ExperienceModePresetTests` passes.
- Fresh install: memory is off, tools are on (auto), everything else matches
  current Balanced behavior.
- Existing user with `"enabled": true` in memory JSON: memory still on.

### Stops at

- No UI changes.
- No experience mode picker visible.
- No tools popover.

**This phase is shippable on its own** if the team wants memory default off ASAP without
waiting for the full redesign.

---

## Phase 2 — Experience Mode in Settings

**Goal**: Users can pick a mode in Settings. Picking a mode rewrites the individual
fields (one-shot apply semantics per D-3 Option A). Onboarding modal is NOT in this phase.

### Files changed

| File | Kind | Change |
|------|------|--------|
| `Views/Settings/ConfigurationView.swift` | add | New `ExperienceModeSection` between General and Chat |
| `Views/Settings/Components/ExperienceModeCard.swift` | new | Single card (radio + description) |
| `Views/Settings/Components/ExperienceModePicker.swift` | new | Four cards + Apply button |
| `Services/Chat/ExperienceModeApplier.swift` | new | `apply(_ mode:to: &ChatConfiguration, &MemoryConfiguration)` |

### Change granularity

- **C-U12**: New SwiftUI components for the mode picker cards.
- **C-U13**: `ExperienceModeApplier` — takes a mode + mutates configs to match.
- **C-U14**: `ConfigurationView` new section. Reads current mode (if any), shows four cards,
  Apply button writes new config.
- **C-U15**: Search keywords in `matchesSearch()` include "Experience Mode", "Beginner",
  "Developer", "Simple", "Power User".
- **C-U16**: Hardware recommendation helper — reuse `RuntimeConfig` RAM tiers to highlight
  the recommended mode for the user's hardware.

### Verification

- Open Settings → Experience Mode section visible.
- Click "Power User", Apply: memory on, preflight wide, max context 32K etc.
- Reload Settings: values persisted.
- Click "Developer", Apply: individual fields unchanged from prior state (developer
  mode opts out of presets).

---

## Phase 3 — Tools popover in the chat input bar

**Goal**: The chat bar has a Tools chip. Tapping it opens the popover. Users can override
tool behavior per conversation or per message.

### Files changed

| File | Kind | Change |
|------|------|--------|
| `Views/Chat/FloatingInputCard.swift` | edit | New Tools chip in selector row |
| `Views/Chat/Components/ToolsMenuPopover.swift` | new | The popover contents |
| `Views/Chat/Components/ToolToggleList.swift` | new | Grouped tool toggles |
| `Managers/Chat/ChatWindowState.swift` | add | `@Published var toolOverride: ChatToolOverride?` |
| `Views/Chat/ChatView.swift` | edit | Pass window state's override into `composeChatContext` |
| `Services/Chat/SystemPromptComposer.swift` | edit | Accept override param, pass to resolver |

### Change granularity

- **C-U17**: `ChatWindowState.toolOverride` field + Published binding.
- **C-U18**: `ToolToggleList` view component — groups tools by plugin, toggles individual.
- **C-U19**: `ToolsMenuPopover` — mode radio + conditional toggles + scope picker.
- **C-U20**: New chip in `FloatingInputCard` selector row.
- **C-U21**: `ChatView.sendMessage` reads `chatWindowState.toolOverride`, passes into
  `composeChatContext`.
- **C-U22**: `SystemPromptComposer` accepts `toolOverride` param (non-breaking — default nil).
- **C-U23**: "Save as agent default" button in popover writes via `AgentManager.updateAgent`.

### Verification

- Open chat, tap Tools chip — popover appears.
- Pick Manual mode, check 2 tools, set scope to Conversation — overridden tool list
  appears in the prompt (verify via debug log).
- Close the window, reopen — override is gone (ChatWindowState is ephemeral).
- Pick Manual, "Save as agent default" — closing + reopening keeps the tools because
  the agent was updated.

---

## Phase 4 — First-launch onboarding

**Goal**: Fresh installs and upgrades see a one-time modal prompting them to pick an
experience mode.

### Files changed

| File | Kind | Change |
|------|------|--------|
| `Views/Onboarding/ExperienceModeOnboardingView.swift` | new | The modal UI |
| `AppDelegate.swift` | edit | Show modal on launch if `!experienceOnboardingSeen` |
| `Models/Chat/ChatConfiguration.swift` | (no change — field already added in C-U02) | |

### Change granularity

- **C-U24**: Onboarding view.
- **C-U25**: Launch hook in AppDelegate.
- **C-U26**: Mark `experienceOnboardingSeen = true` on dismissal, write via
  `ChatConfigurationStore.save`.

### Verification

- Fresh install: modal shows on first launch.
- Dismiss without picking: Balanced applied, flag set.
- Pick Power User: applied + flag set.
- Relaunch: modal does NOT show again.
- Reset onboarding via debug menu (hidden) — modal shows again.

---

## Phase 5 — Polish, tests, docs

**Goal**: Everything tested and documented.

### Files changed

| File | Kind | Change |
|------|------|--------|
| Various tests | add | Integration tests for the chat bar popover path |
| `docs/internal/chat-ux-experience-mode/06-CHANGE-AUDIT.md` | new | Full per-change audit log |
| `docs/OpenAI_API_GUIDE.md` | edit | Document that per-chat tool overrides don't cross the API boundary |
| `docs/FEATURES.md` or similar user-facing doc | edit | Explain experience modes |
| `CHANGELOG` | edit | Release notes |

### Change granularity

- **C-U27**: `06-CHANGE-AUDIT.md` catches up (ideally written incrementally during phases 1-4).
- **C-U28**: Integration test suite for end-to-end chat tool override path.
- **C-U29**: User-facing docs.
- **C-U30**: CHANGELOG entry.

---

## Shared concerns across phases

### Schema backward compatibility

Every new field on `ChatConfiguration`, `MemoryConfiguration`, `Agent` is optional with a
safe default. Existing JSON files from prior versions decode without error.

Test this explicitly: take a `ServerConfiguration.json` + `MemoryConfiguration.json` +
`agents.json` from the current main branch, decode with the new schemas, verify all
values round-trip.

### The resolver is the single source of truth

Every "should we do X" check goes through `ChatConfigurationResolver`. No direct reads
of `ChatConfiguration.preflightSearchMode`, `.disableTools`, or `MemoryConfiguration.enabled`
outside the resolver file. Tests enforce this (grep for forbidden patterns in CI).

### No changes that affect the HTTP API

`ChatCompletionRequest` / `ChatCompletionResponse` are untouched. The new overrides are
purely internal — they only exist between the UI and `ComposedContext`. HTTP clients see
exactly what they see today.

### No changes to vmlx-swift-lm

This entire redesign is osaurus-side. The package reference stays at whatever the
`feat/vmlx-cache-migration` branch set it to. If we ship this work on a separate branch
from `main`, the vmlx cache work is not a dependency.

### Experience mode migration for users without it

On first load of the new code, `ChatConfiguration.experienceMode == nil`. The resolver
treats nil as "use individual field values" — current behavior. The Settings UI will
show "No mode selected" if the user opens Experience Mode before picking one. The
onboarding modal (Phase 4) handles new-user selection; existing users who skip it stay
on their individual field values forever unless they explicitly pick a mode.

---

## Risk / blast radius summary

| Phase | Risk | Blast radius | Reversible? |
|-------|------|--------------|-------------|
| 1 | Memory default flip could confuse existing users | All generation paths | Yes, reset memory JSON |
| 2 | Experience Mode apply button rewrites multiple config fields | Global config file | Yes, restore JSON backup |
| 3 | FloatingInputCard is high-traffic UI — visual regression risk | Chat UI | Yes, feature flag the chip |
| 4 | Onboarding modal could annoy users who upgrade frequently | First-launch UX | Yes, allow dismiss-forever |
| 5 | Docs / tests only | None | Yes |

---

## Estimated effort (rough, don't quote me)

- **Phase 1**: Data scaffolding + resolver + memory flip. ~800 LoC added, ~200 modified.
- **Phase 2**: Experience Mode settings section. ~500 LoC.
- **Phase 3**: Tools popover. ~700 LoC (popover is the biggest new UI surface).
- **Phase 4**: Onboarding. ~400 LoC.
- **Phase 5**: Tests + docs. ~400 LoC tests, docs varies.

Total: ~3,000 LoC across the feature. Mostly additive, not replacing existing code.

---

## What I need from the team before starting

1. **Decisions** — every item in `04-DECISIONS.md` has a "Needed from team" line. None of
   them block individually, but a few (D-1, D-2, D-7) will reshape the data model.
2. **Branch strategy** — ship on a fresh branch from main, or stack on
   `feat/vmlx-cache-migration`? (D-Blocker)
3. **Phase review points** — do you want to review after each phase, or batch reviews
   (e.g., 1+2 together, 3+4 together, 5 separately)?
4. **Onboarding copy** — happy for me to write draft copy, or does the team want to
   provide the exact wording?

Reply in the PR or ping me directly. Nothing happens until you give the go-ahead on
at least D-1 through D-4.
