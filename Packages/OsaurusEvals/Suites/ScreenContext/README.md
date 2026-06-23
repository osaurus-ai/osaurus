# ScreenContext suite

Distillation evals for the ambient `[Screen Context]` block. Each case replays a
frozen macOS screen state (a `ScreenContextFixture`) through the real
`ScreenContextDistiller` via the read-only `FixtureCUDriver`, then scores the
rendered block. The distiller is pure over `MacDriver`, so a fixture replay is
fully deterministic — no real Accessibility, SkyLight, or Screen Recording.

This is the regression guard for the screen-context overhaul: it pins that the
distiller surfaces **what the user is looking at** (focused editor/input,
selection, on-screen content) and **drops chrome noise** — the Xcode
package-version sidebar (`9.15.0`, `0.3.11`, …) that motivated the work.

See the schema reference (`expect.screenContext` fields, fixture format, scoring)
in the top-level [`README.md`](../../README.md#screen_context-domain).

## Running

```bash
# Whole suite (deterministic, no model needed):
make evals EVALS_SUITE=Packages/OsaurusEvals/Suites/ScreenContext

# One case while iterating, with the rendered block in the output:
make evals-verbose EVALS_SUITE=Packages/OsaurusEvals/Suites/ScreenContext FILTER=xcode
```

The deterministic matchers run with **no model**, so the suite is CI-safe. An
optional per-case `rubric` is graded by an LLM judge only when a strong/explicit
judge resolves (`JUDGE_MODEL` or a `*_API_KEY`); otherwise it's skipped and
noted, so CI stays free.

## Cases

| Case | What it proves |
|---|---|
| `xcode-editor-over-version-noise` | the reported bug: the editor's code (`Viewing:`) leads and the package-version sidebar numbers are dropped |
| `xcode-navigator-chrome-dropped` | the faithful bug: Xcode's navigator file rows are editable `textfield`s + a blame `statictext` commit hash — both dropped while the code leads |
| `xcode-selection-and-viewport` | the selection (`Selected text:`) and the cursor-centered viewport (`Viewing:`) both surface verbatim |
| `cursor-electron-editor-inaccessible` | Electron/Monaco's "editor is not accessible" sentinel + lone `/` viewport are dropped; the buffer is the AX ceiling, so behavior comes from the reliable layer instead — the title names the file (`Active: editing …`) and the status bar's git branch surfaces (`Status: main*`) |
| `cursor-working-state` | a fuller Cursor working state: the (unsaved-marked) title names the active file and the bottom status bar composes a `Status:` line — git branch, problems count, language, cursor position — while the inaccessible code body stays absent |
| `safari-article-beats-chrome` | with no focused input, the large article body leads `On screen:` ahead of nav chrome; bare version tokens dropped |
| `chrome-webarea-article` | a browser page under an `AXWebArea`: the heading + body paragraphs surface ahead of chrome, while nav links, a single-token nav label, a leaked ARIA `true`, and a bare version token are dropped |
| `browser-form-checkout` | a browser form with a focused text field surfaces its value, the page title, and relevant sibling form context |
| `slack-draft-and-selection` | the active channel surfaces (`Active: channel #…`), and the focused composer's draft + selection surface for a non-editor app (text field, no viewport); messages show as on-screen content |
| `slack-scrolled-messages` | a scrolled channel with no focused composer: the active channel surfaces from the title, the message rows inside the scroll area surface as content, while single-token sidebar chrome (Threads / Drafts) is dropped |
| `chat-shell-compose` | a generic Slack-like Electron shell pins active-channel parsing, focused draft text, selection text, and message-row context |
| `mail-compose-reply` | a native Mail compose window surfaces the focused message body, selected draft text, and nearby reply context |
| `finder-selected-file` | a Finder outline/list shape preserves the selected file and useful surrounding file names while dropping sidebar chrome |
| `terminal-system-settings-dangerous` | a Terminal/System Settings shaped desktop remains read-only screen context evidence and does not imply action-policy permission |
| `secure-field-never-leaks` | secure text fields keep role/focus context while dropping secure values, selections, and viewport text |
| `empty-input-minimal` | an empty focused field stays minimal — no fabricated `Viewing:` / `Selected text:` (uses an INLINE `scene`, exercising that path) |

## Fixtures (`../../Fixtures/ScreenContext/`)

Committed fixtures are hand-authored, **synthetic** trees that reproduce real AX
*shapes* (captured from real apps, then sanitized) without real personal content:

- `xcode-storagemutationgate.json` — a focused editor `textarea` + ~8 tiny
  version `statictext`s + sidebar labels (the Xcode shape).
- `xcode-navigator-chrome.json` — a focused editor `textarea` (code) + navigator
  file-name `textfield` rows + a commit-hash `statictext` (the real navigator).
- `cursor-electron-inaccessible.json` — Monaco's inaccessible-editor sentinel as
  the focused `textarea` label/value + a `/` viewport + a bottom status bar
  (branch `main*`, formatter) (the Electron shape).
- `cursor-working-state.json` — the same inaccessible buffer + an unsaved-marked
  title (`● AgentLoop.swift`) + a fuller bottom status bar (git branch, problems,
  language, cursor position) — the behavior-signal source when code is unreadable.
- `safari-article.json` — a heading + a large article `statictext` body + small
  nav chrome + bare version tokens.
- `chrome-webarea-article.json` — an `AXWebArea` page (heading + body paragraphs)
  under browser chrome (address bar, reload) + nav link/label, a leaked ARIA
  `true`, and a labeled version token (the real Chrome shape).
- `browser-form-checkout.json` — a browser form with focused-field value, sibling
  field labels, page heading, and call-to-action context.
- `slack-thread.json` — a focused composer `textfield` (draft + selection) +
  message `statictext`s.
- `slack-scrolled-messages.json` — a `scrollarea` of message `statictext` rows +
  single-token sidebar labels, with no focused composer (the scrolled-history
  shape).
- `chat-shell-compose.json` — a generic Electron chat shell with channel title,
  composer draft/selection, and message rows.
- `mail-compose-reply.json` — a native Mail compose/reply shape with selected text
  and viewport text in the focused message body.
- `finder-selected-file.json` — a Finder outline/list shape with selected file
  text and surrounding file rows.
- `terminal-system-settings-dangerous.json` — a Terminal window plus System
  Settings window metadata for read-only distillation proof.
- `safari-secure-login.json` — a secure-field shape that proves password-like
  values never surface in rendered screen context.

## What the distiller does with real apps (the AX reality)

The captures behind these synthetic fixtures exposed three app families, which
the distiller now handles:

- **Native (Xcode, TextEdit, Mail, …):** AX carries the editor/buffer, so the
  focused code/text surfaces as `Viewing:` / `Selected text:`. Sidebar and
  status chrome (navigator file rows, version/commit tokens) is dropped.
- **Browsers (Chrome, Safari):** the page body now reads. The tree builds
  asynchronously after the AX flags flip, and the toolbar materializes long
  before the `AXWebArea`, so the readiness gate
  (`AccessibilityManager.prepareAndAwaitTree` → `focusedWindowHasContent`) waits
  for *readable text* (a built web area, a focused value, or real static/heading
  text) rather than a bare node count — otherwise the one-shot capture declared
  the page "ready" on its toolbar alone and returned only the address bar. WebKit
  needs `AXEnhancedUserInterface` (set alongside `AXManualAccessibility`). When
  the depth-first budget still exhausts on chrome before the web area, a targeted
  `find(statictext/heading/webarea)` recovers the body. Headings + paragraphs
  surface; nav links/labels, ARIA `true`/`false` leakage, and version tokens are
  dropped.
- **Electron (Cursor/VS Code, Slack, …):** same async-tree wait. Monaco still
  exposes only an "editor is not accessible" sentinel for the buffer, which is
  dropped, and Slack's message list is **virtualized** (rows aren't materialized
  into AX without an active screen reader) — both genuine text-only ceilings,
  not distiller bugs. So for these app shells the distiller mines the **reliable
  interactive/titled layer** instead (the same surface Computer Use *acts* on —
  it can type into Slack's composer because that control is in AX even though the
  history isn't):
  - **`Active:`** — structured context parsed from the window title with
    high-precision patterns only: the channel (`#engineering`) for chat shells,
    the file (`AgentLoop.swift`, unsaved-marker stripped) for editors. A plain
    document/site title yields nothing rather than a guessed label.
  - **`Status:`** — labeled controls read from the focused window's bottom
    status-bar strip (git branch, problems count, language, cursor position) —
    short tokens the on-screen sampler drops as chrome, surfaced here as
    behavior. Geometry-gated, so it's inert without frames and never mistakes the
    editor body for a status item; bare version/commit tokens stay dropped so the
    status line never reintroduces the version noise.
  `cursor-working-state` pins that this composes a useful read of what the user
  is doing even when no code/message text is accessible; `slack-scrolled-messages`
  pins that *when* message rows are present, they still surface as content.

## Privacy boundary (hybrid fixtures)

- **Committed (CI):** the synthetic fixtures above and the cases here. No real
  personal content.
- **Local (tuning only):** real captures from `osaurus-evals capture-screen`
  land in the gitignored `../../Fixtures/ScreenContext/local/` directory because
  they contain your actual on-screen code/text. Never commit them.

## Tuning loop

```bash
# 1. Capture a real app AND print the exact injected block in one shot
#    (--render replays the capture through the distiller). Needs Accessibility
#    permission; local-only, never CI:
swift run --package-path Packages/OsaurusEvals osaurus-evals capture-screen --app Xcode --render
#    fixture → Packages/OsaurusEvals/Fixtures/ScreenContext/local/xcode-<timestamp>.json
# (or `make evals-capture-screen APP=Xcode` to just write the fixture)

# 2. Point a scratch case's `fixture` at it (relative to Fixtures/ScreenContext/,
#    e.g. "local/xcode-<timestamp>.json") and read the rendered block:
make evals-verbose EVALS_SUITE=Packages/OsaurusEvals/Suites/ScreenContext FILTER=my-scratch

# 3. Adjust the distiller heuristics/budgets in OsaurusCore, repeat. Promote the
#    durable signals into a committed, sanitized case + synthetic fixture.
```

## Adding a case

Drop a `*.json` file here (copy a sibling). Reference a committed fixture by
`fixture` path (relative to `Fixtures/ScreenContext/`) or inline a `scene`. Keep
committed cases deterministic (no `rubric`) so they gate CI; add a `rubric` for
local semantic grading when you have a judge configured.
