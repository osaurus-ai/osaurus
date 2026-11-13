# Chat window shell and chat surface

This is the source of truth for the chat window's layout, its information
architecture, and the chat surface's components. Change this document in the
same pull request as any change to the rules below.

The geometry lives in one place: `ChatShellLayout`
(`Packages/OsaurusCore/Views/Chat/ChatShellLayout.swift`). `ChatView` reads
the layout it computes for the window's width; it does not derive widths
inline. `ChatShellLayoutTests` covers every rule here across a matrix of window
widths.

## Information architecture

The window has one job per column, left to right, plus one floating card:

| Column | Holds | Scope |
| --- | --- | --- |
| Navigation rail | Destinations: Chat, Workflows; Usage and Settings at the bottom | The app |
| Sidebar | What you can open: the Orchestrator, Pinned chats, Agents, each agent's chats, agents on other Macs, workspace agents, agents shared with you | The Chat destination |
| Content | The conversation: title strip, thread, notices, composer | The chat on screen |
| Context panel (floating card) | File Changes for the chat on screen, only once it has some | The chat on screen |

Rules that follow from this:

- A destination owns the whole content area. The sidebar and context panel
  belong to Chat; Workflows hides both.
- The sidebar navigates. Opening a chat, starting one, or switching agents
  from it is navigation, so in a compact window the drawer closes on those
  picks (folding an agent or Show more keeps it open).
- Sidebar groups (Pinned, Agents, each agent) fold from anywhere on their
  row; a trailing action such as Agents' + keeps its own click. The
  Orchestrator is always the first row, in no group: it is the core agent
  and is always there. A pinned chat leaves its agent's list for the
  Pinned group below it, where its row carries the agent's avatar;
  unpinning returns it.
- The Agents header's ⋯ (hover-only, the same trigger and plain-text menu
  as a chat row's) holds the sidebar's list-level actions: Import
  Conversations (into the agent on screen) and Show/Hide Archived, which
  returns archived chats to their agent's
  list (and Pinned) with an archive glyph in the icon column; glyph and
  title use the disabled ink, lifted to tertiary on hover. Workflow runs move to the Workflows destination, not here.
- Sidebar rows share one grid (`NavigatorRowMetrics`): 32 points tall,
  content 8 in, a 24-point icon column (the agent's avatar, or empty under
  an agent), text 8 after it, hover actions 8 from the trailing edge. So a
  chat title starts under its agent's name and every hover control sits in
  one column.
- An agent without a custom image or mascot shows its initial in its own
  colour on a soft wash of that colour, borderless (`AgentAvatarView`), so
  letter avatars sit beside mascots as distinct agents rather than as
  keycaps.
- The context panel describes the chat on screen and never navigates away
  from it. It holds File Changes only, and exists only while the chat has
  recorded a change (`ChatWindowState.contextPane`): no empty panel, and
  no toolbar toggle until there is something to show. Past chats live in
  the sidebar, past workflow runs on the workflow's page. Workflows is a
  rail destination, not a context lens. The Architect's draft sits beside
  its chat in the Workflows split, so the Architect's chats have no
  context panel.
- The panel is a card at the window's top trailing corner, 12 points
  below the titlebar strip and in from the trailing edge
  (`ChatView.floatingContextCard`). Wide windows set a 384-point column
  aside for it (the card plus its insets, on the conversation's canvas),
  so the conversation re-centers beside it and nothing runs under it.
  Regular and compact windows let it float over the content's trailing
  edge (`ChatShellLayout.contextReservesColumn`).
- It is 360 wide (the content less its insets when narrower), rounded,
  bordered and lifted with the overlay elevation. It hugs its list and
  caps at 560 tall or the room above the composer, whichever is less
  (`ChatShellLayout.floatingContextSize`); past that the list scrolls.
- Header: "File Changes" over the "N files changed · M changes" summary,
  and an overflow menu (…) holding Revert All, the one action over the
  whole chat. Under it, Timeline | Files on one quiet track, each tab
  with its count; then a divider and the list.
- Rows highlight with an inset rounded fill on hover, and their actions
  (Revert or Undo on a Timeline row; Reveal in Finder and Revert File on
  a Files row) appear on hover and are always in the row's context menu.
  A Files row marks its kind with a tinted glyph (plus, pencil, minus)
  rather than a text pill.
- The toolbar toggle uses a change-list glyph (`list.bullet.rectangle`).
- The toolbar's context button shows and hides it: the card grows from
  that corner (scale from the top trailing anchor with a fade) and
  shrinks back into it.
- The panel is asked for by default, so it appears with a chat's first
  change. Closing it from the toolbar keeps it closed across chats in that
  window until the toggle opens it again.
- Search in the sidebar finds agents by name and chats by title. While a query
  is active, each agent opens on its matching chats and the Agents section's
  fold is ignored.
- The chat's title is always on screen, centered in the content column's
  title strip, with the agent name beside it in the quieter style.

## Breakpoints

Breakpoints are measured on the room beside the rail (window width minus 44).

| Breakpoint | Room beside rail | Sidebar | Context panel | Content |
| --- | --- | --- | --- | --- |
| Compact | under 760 | Drawer over the content | Floating card, opened from the toolbar only | Full room |
| Regular | 760 to 1199 | Docked, clamped so content keeps 480 | Floating card over the content | Remainder |
| Wide | 1200 and up | Docked | Card in a 384-point column of its own | Remainder |

- The window's minimum content size is 560 by 480, clamped to what the screen
  can show (`ChatWindowState.minimumContentSize`).
- Sidebar width is user-resizable between 240 and 460. Stored widths are
  clamped on read.
- The rail, sidebar, content and (wide only) the card's column always add
  up to the window. The sidebar step-aside never triggers for the card's
  column: a wide window always holds sidebar, readable content and the
  card.
- The compact drawer leaves 56 points of content uncovered, so the chat
  still reads behind the scrim and a click there dismisses.

## Overlays (compact)

- One overlay at a time: opening the drawer closes the context card, and
  opening the card closes the drawer.
- Dismiss by clicking the scrim, pressing Escape (drawer first, then the
  context card), or picking something in the drawer.
- The drawer has its own open state (`isCompactSidebarPresented`), always
  starts closed, and never rewrites the docked choice.
- Crossing into or out of compact closes the drawer. Entering compact also
  closes the context card, and widening brings it back if it was open; the
  card never opens on its own in a compact window.

## The readable column

The thread, the notices above the composer, the composer card, inline agent
blocks (Todo / Done) and prompt cards share one column:

- Outer width: at most 800 (`readableColumnWidth`), centered in the content.
- Inset: 20 on each side (`columnInset`). Bubbles, notice text and the
  composer card share the same left and right edges at every width.
- The composer view keeps 12 points of its own padding around its card, so
  its frame is the readable width less 16 (`composerFrameWidth`); the card
  then lands on the thread's edges.
- Rows use `.readableColumnRow()` rather than repeating the inset and cap.
- The thread has one gutter: the column inset. Message rows add none of
  their own (`CellRenderingContext.threadRowInset` is 0), so the assistant
  header, reply text, tool and status cards, activity groups, artifacts,
  charts and diffs share the left and right edges of the user bubble and
  the composer card. Component padding tokens set vertical rhythm only; a
  horizontal inset belongs inside a card, never around a row. The typing /
  status card spans the full row like a tool card, so the two are the same
  width.
- The Workflows chat (`fullWidthMessages`) gets its outer padding from its
  panel instead, and its user bubbles fill the available width.

## Titlebar strip and toolbar

- The toolbar has three items: the sidebar toggle (leading), a flexible
  space, and one trailing item holding Inbox (only while something waits)
  and the context panel toggle (only while the chat has file changes).
  Find has no toolbar button; it opens with
  ⌘F. Every toolbar button is a
  `HeaderActionButton`: same size, same hover, same active state.
- The context toggle mirrors the sidebar toggle. It reads active while the
  panel is open and carries the changed-files badge while it is closed (local
  chats only).
- The window controls (close, minimize, zoom) are re-centered vertically on
  the 44-point strip so they share one line with the toolbar buttons
  (`ChatPanel.alignTrafficLightsWithHeader`). AppKit lays the titlebar out
  again on resize, key changes, screen changes and full-screen exit, and
  each re-applies the alignment.
- The title is centered over the content column. Both sides keep the larger
  of two clearances: the leading window chrome (124 points from the window's
  leading edge) when no sidebar pushes the column right, and the trailing
  toolbar buttons (96 points). Equal
  insets keep it centered; a long title truncates. The strip is not
  hit-testable, so it still drags the window.

## Chat surface components

**Find bar.** Docks at the top-trailing edge of the readable column and grows
to fill it up to 360. The thread's top inset grows by the bar's height, so the
bar never covers the first message. Escape closes it first (only an open
slash-command menu takes Escape before it).

**Prompt cards** (questions, secrets, approvals). Scoped to the chat column,
never over the sidebar, context panel or workflow draft. The card uses the
readable column. The header pill is neutral (secondary text on a subtle
surface): the card standing in for the composer over a scrim already says
"this needs you".

**Computer Use confirmations.** Scoped to the content column.

**Greeting.** The subtitle is the agent's description, trimmed to the leading
whole sentences that fit 160 characters (`ChatEmptyState.greetingSubtitle`),
up to three lines in at most 560 points. A first sentence longer than that
stays whole and is left to the line limit.

**Composer anatomy**, left to right: attach, then the chips (model, folder,
sandbox and others), then the trailing group: context ring, mic, send / stop.

- The model chip hugs its label with the chevron beside it; the label is
  capped at 200 (`modelChipMaxLabelWidth`).
- The context ring's track is as thick as its arc and drawn in a text token,
  so it reads at every usage level. (A zero-width track left a short arc that
  read as a stray dash at low usage and as a spinner at higher usage.)
- Chips collapse to icons at the compact breakpoint only
  (`usesCompactComposer`), and always inside the workflow-creation chat.

**Tool-call cards** are collapsed by default; expanded arguments and results
render as pretty-printed JSON when they parse. Raw JSON that a model writes in
its visible answer is message text and is shown as written. The card title
takes the tool family's label style; the duration and source tag after it
keep the caption style.

**Agent avatar.** One rule everywhere an agent appears (sidebar rows, the
pinned group, the assistant message header): `AgentAvatarView` is tinted
with the agent's own color (`agentColorFor(name)`). A monogram sits on that
color at 18% opacity; it never falls back to the neutral text color.

**Status chips.** Transient counters in the thread (the prefill progress
chip on the typing row) use the shared badge (`StatusChip`, family 10) with
tabular digits, so the count does not jitter as it climbs.

## Workflow creation split

The Architect's chat and the draft editor share the Workflows content area.

- At 760 points of content and up they sit side by side: the chat takes 40%
  of the content, clamped to 340 to 520; the draft takes the rest.
- Below 760 they stack behind a Chat / Workflow switch. A question from the
  Architect brings the Chat half forward.

## Why these numbers are not catalog tokens

The design library's layout assignments resolve to spacing tokens (0 to 64
points). Column widths, breakpoints and caps are layout geometry outside that
range, so they live as named constants in `ChatShellLayout`. Spacing inside
components (gaps, paddings) still comes from the catalog.

## Known gaps (next phases)

The design-library integration status (token coverage, placeholder values
awaiting design review, inspector layout coverage and open Workflows
screens) lives in [design-library-integration.md](design-library-integration.md).

- Workflows destination polish beyond the split: library, run tabs, and the
  workflow guide topics that still describe the old inspector lenses.
- Project pages are not reachable from the shell since the handoff removed
  their mount; they need an IA decision before they return.
- Settings and the management window are not yet on this column model.
