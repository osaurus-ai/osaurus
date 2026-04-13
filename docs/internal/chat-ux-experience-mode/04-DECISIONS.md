# Open Decisions

> Every item here needs a yes/no or pick-one from the team before I start writing code.
> Ordered by blast radius, biggest first.

---

## D-1: Flip `MemoryConfiguration.enabled` default from `true` to `false`

**Severity**: High — behavior change for existing users.

**Proposal**: Default new configs to memory off. Users explicitly opt in.

**Pros**:
- Cuts up to 9,300 tokens per request for users who never opened the memory UI.
- Aligns with "simple / beginner" default experience.
- Memory is a power feature; users who want it know it exists.

**Cons**:
- Existing users who silently relied on memory lose it on upgrade.
- Losing memory may degrade agent behavior in subtle ways (agents that remember user
  preferences, long-running project context, etc.).

**Migration options**:

1. **Hard flip** — new installs get false, existing installs get their stored value preserved
   (nil in the JSON → treated as false going forward). Users who had `"enabled": true`
   explicitly in the file keep it.
2. **Soft flip with onboarding** — show a one-time modal asking "Do you want to keep memory
   enabled?" on first launch after upgrade.
3. **Conservative** — only flip for new installs, leave existing users on `true` forever
   via a `"memoryDefault": "legacy"` version marker.

**Recommendation**: Option 2 (soft flip with onboarding).

**Needed from team**: Pick 1 / 2 / 3. Confirm the onboarding modal copy.

---

## D-2: Per-chat tool override state location

**Proposal**: Add `ChatToolOverride?` to `ChatWindowState`.

**Alternatives**:

1. **`ChatWindowState`** (ephemeral, tied to the window)
   - Resets on window close.
   - Fine for the "this conversation" scope.
   - Simple.
2. **`ChatSession`** (if sessions persist across window open/close — need to verify)
   - Survives window close.
   - Better UX: user's tool choice is remembered when they reopen the same conversation.
3. **Both** — `ChatSession` for persistent state, `ChatWindowState` for the currently-displayed value.

**Question for the team**: Does `ChatSession` persist across window close today? If yes,
option 3 is the best UX. If no, option 1 is simpler.

**Needed from team**: Pick 1 / 2 / 3. If 2 or 3, confirm that `ChatSession` is the right
persistence layer (SQLite? JSON? in-memory only?).

---

## D-3: Experience Mode preset semantics

**Proposal**: Option A (one-shot apply).

See `03-DESIGN.md` §3 "Preset semantics — one-shot or persistent?" for the full framing.

**Summary**:

- **Option A** — Picking a mode copies values into individual fields. Mode is forgotten
  after application. Simple.
- **Option B** — Mode is a persistent layer. Individual fields can nil out to "use mode
  default" or override. Complex.

**Recommendation**: Option A. Ship it simple, upgrade later if users ask.

**Needed from team**: Confirm A, or make the case for B.

---

## D-4: Default experience mode on fresh install

**Proposal**: Balanced.

**Alternatives**:

- **Simple** — friendliest to new users, but surprising for anyone coming from a dev tool
  expecting tools to be on.
- **Balanced** — middle ground. Tools on (auto), memory off, compact sandbox.
- **Power User** — surprising for users on 8/16 GB Macs; their first experience could be
  laggy.
- **Hardware-detected default** — Simple on < 16 GB, Balanced on 16-32 GB, Power on > 32 GB.
  Smart but less predictable.

**Recommendation**: Balanced with a hint on the onboarding card that says
"Recommended for your hardware" when it matches.

**Needed from team**: Confirm Balanced, or pick another default.

---

## D-5: First-launch onboarding UX

**Proposal**: One-time modal on first launch after upgrade.

**Questions**:

1. Modal or inline banner in Settings?
2. Blocking or dismissible?
3. Show for existing users on upgrade, or only truly fresh installs?
4. Should the modal explain what "Experience Mode" means, or just present the four choices?

**Recommendation**:
- Dismissible modal on first launch after upgrade
- Short explanation (1 sentence per mode)
- Highlight hardware-recommended
- Default selection = Balanced if user dismisses without choosing
- Store `experienceOnboardingSeen = true` in ChatConfiguration to prevent re-show

**Needed from team**: Confirm approach and copy.

---

## D-6: Popover scope UX

Three scopes proposed in `03-DESIGN.md`:

- "This message only"
- "This conversation"
- "Save as agent default"

**Questions**:

1. Is "this message only" actually useful? Users would rarely flip tools mid-conversation
   for a single message. Could be cognitive overhead.
2. Should "save as agent default" be a separate button outside the scope picker? It's a
   commitment, not a scope.
3. Should there be a "reset to agent default" option?

**Proposal revision**:
- Keep two scopes: conversation (default) and message.
- Make "save to agent" a separate explicit button: `[ Save as agent default ]`.
- Add `[ Reset to agent default ]` button that clears the override.

**Needed from team**: Confirm revision or propose alternative.

---

## D-7: Memory-off presets — what about agents that already had memory?

If Simple and Balanced modes default to memory off, what happens to users with agents that
had been relying on memory for weeks?

Options:

1. **Mode only controls new agents** — existing agents keep their memory setting.
2. **Mode is fully global** — turning Simple mode on kills memory for everyone.
3. **Per-agent memory override** — Agent gets a new `memoryEnabled: Bool?` field. Mode sets
   the default for new agents; existing agents with explicit overrides keep them.

**Recommendation**: Option 3. Add `Agent.memoryEnabled: Bool?` as a new field. Global
`MemoryConfiguration.enabled` becomes the default; agent override wins. This also gives
power users the ability to have memory on for specific agents (e.g., a journaling agent)
without flipping a global switch.

**Needed from team**: Confirm Option 3, or pick 1 / 2.

---

## D-8: Should "Developer" mode really opt out of presets entirely?

Developer mode as proposed says "respects whatever the user has explicitly set — no preset
layer". This means Developer users see all the advanced fields in Settings and have to
configure each one manually.

**Alternative**: Developer mode is just "Power User + show advanced fields". All presets
still apply, but the UI exposes more knobs.

**Recommendation**: Stay with the original proposal. Developer mode implies "I know what
I'm doing, don't touch my config".

**Needed from team**: Confirm.

---

## D-9: Preflight mode vs Tools popover mode — overlap resolution

The existing `ChatConfiguration.preflightSearchMode` enum (`.off, .narrow, .balanced, .wide`)
overlaps with the proposed `ChatToolOverride.Mode` (`.auto, .manual, .off`).

- `ChatToolOverride.mode == .auto` + `preflightMode == .off` → tools are auto but preflight
  is disabled. Meaning: only always-loaded tools are sent. Is this a useful state or a trap?
- `ChatToolOverride.mode == .off` → tools fully disabled. Preflight mode is irrelevant.
- `ChatToolOverride.mode == .manual` → user's explicit tool list. Preflight mode is irrelevant.

**Proposal**: The Tools popover shows the preflight mode selector **only** when
`ChatToolOverride.mode == .auto`. Otherwise hide it.

**Needed from team**: Confirm, or suggest clearer UX.

---

## D-10: Sandbox compact-by-default for remote models

Not strictly part of this UX work but surfaced by the prompt bloat audit. The sandbox
instructions are 1,050 tokens in full mode, 450 in compact. Local models get full, remote
get full too (currently).

**Question**: Should remote Claude / OpenAI / Gemini models default to compact sandbox to
save cloud tokens?

**Recommendation**: Yes. Add to Balanced and Power mode presets: "Use compact sandbox for
remote models". Leave a user override in Settings.

**Needed from team**: Confirm, or leave this out of the UX redesign and handle separately.

---

## Blocker — none of the above can proceed until

The previous branch's `swift-transformers 0.1.21` downgrade needs to be build-verified.
If that blocks the merge of `feat/vmlx-cache-migration`, this new work has to either
stack on an unmerged branch (awkward) or skip the vmlx cache migration entirely.

**Question for team**: Should I build the UX redesign on a fresh branch from `main`,
separate from vmlx-cache-migration? That way it can ship independently.

**Recommendation**: Yes, fresh branch. The two changes are fully orthogonal and one
shouldn't block the other.
