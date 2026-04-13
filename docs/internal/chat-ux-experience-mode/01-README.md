# Chat UX Redesign — Tools Menu, Memory Default, Experience Mode

> **Status**: Design doc. No code written yet.
> **Scope**: UX redesign of tool enable/disable + memory default + new experience-level presets.
> **Related**: Supersedes the "just cut prompt bloat" direction. This is a structural rethink of how
> users control what goes into their prompts.
> **Base branch**: `feat/vmlx-cache-migration` (stacks on top)

---

## What the user asked for

Verbatim from the session:

> "ok i think these features have to be just easy togglelable - no automatic memory feature,
> simply within the chat bar there should be a button to open tools and then that opens submenu
> to enable disable tools, and let this all act in this manner. also maybe allow for an entire
> 'cloud api usage/fast computer owner' section like how lm studio has beginner/developer etc
> so that users can switch to a section where in these things are auto toggled on by default"

Three distinct asks:

1. **Memory: no longer automatic.** Off by default, user opts in explicitly.
2. **Tools: in-chat toggle.** A button in the chat input bar opens a popover where the user
   can flip individual tools (or whole tool categories) on/off per conversation, without
   diving into Settings.
3. **Experience Mode: presets.** LM-Studio-style beginner / developer / power-user modes that
   bundle the "sensible defaults" for that persona and auto-toggle tools + memory + context
   budgets accordingly. User picks a persona, everything else self-configures.

## Why this matters

Current state (audited in the prompt bloat review earlier this session):

- Memory is **enabled by default** and can inject up to 9,300 tokens per request even if the user has never opened the memory UI.
- Tool toggles live buried in Settings → Chat. A user can't flip tools on/off mid-conversation without leaving the chat.
- New users get the same prompt shape as power users — no progressive disclosure, no "just chat with the model" mode.
- There are 8 always-loaded capability tools that exist specifically so the model can discover other tools, but they're injected even when the user doesn't want auto-discovery.

All of this bloat is technically configurable in `ChatConfiguration` and `MemoryConfiguration`
JSON, but it's not discoverable. The redesign makes it easy.

---

## Folder contents

```
docs/internal/chat-ux-experience-mode/
├── 01-README.md              ← you are here
├── 02-CURRENT-STATE-MAP.md   ← what exists today (files, line numbers, state flow)
├── 03-DESIGN.md              ← proposed UX + data model + integration plan
├── 04-DECISIONS.md           ← open design decisions needing team input
└── 05-IMPLEMENTATION-PLAN.md ← phased execution order with per-change intent
```

Read in order. **Nothing is implemented yet** — everything is reviewable before I touch code.

## How this relates to the other open work

- `docs/internal/vmlx-cache-migration/` — the completed cache migration work. This new work stacks
  on top of that branch. Not merged yet either.
- If we land vmlx-cache-migration first, the chat UX work rebases cleanly on top.
- If we decide to ship chat UX first, they still don't conflict: the vmlx work touches
  ModelRuntime / CacheCoordinator / ServerConfiguration; this new work touches
  ChatConfiguration / MemoryConfiguration / FloatingInputCard / ChatView.

## Reviewer asks

Before I start building, I need team agreement on the items in `04-DECISIONS.md`. Specifically:

1. **Memory-off default** — this is a behavior change for existing users with no override. Confirm OK.
2. **Per-chat tool toggles** — where does the state live? ChatSession, ChatWindowState, or GenerationParameters?
3. **Experience Mode preset semantics** — are presets a one-shot "apply these values" or a persistent layer that overrides individual settings?
4. **Default persona** — what does a fresh install land on? Beginner, Balanced, or Developer?
5. **Migration for existing users** — do we show a onboarding prompt ("Pick your mode") on first launch after upgrade, or silently assign them Balanced?

See `04-DECISIONS.md` for full framing on each.
