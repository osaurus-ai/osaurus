# Proposed Design

> Draft design for the three asks. Nothing here is final — every choice is up for discussion
> in `04-DECISIONS.md`. The implementation plan that executes this is in `05-IMPLEMENTATION-PLAN.md`.

---

## 1. Memory default off

### Change

Flip `MemoryConfiguration.enabled` default from `true` to `false`.

### Why

- Memory is not free: up to 9,300 tokens per request with default budgets.
- Most users never open the Memory management UI and don't know the feature is on.
- Users who want memory explicitly opt in (same pattern as Claude Projects, Cursor Memory, etc.).

### Migration

Two-phase:

1. **Encoder side**: `MemoryConfiguration.default.enabled = false`.
2. **Decoder side**: existing JSON files that explicitly have `"enabled": true` are preserved.
   Existing files that omit the field (or have `false`) get `false` as the new default.
3. **Onboarding nudge**: On first launch after upgrade, show a one-time notification
   ("Memory is now opt-in — tap here to enable persistent memory for your agents") —
   dismissible, stored in UserDefaults.

### Where memory gets turned on

New home for the toggle:

- **Option A**: New Memory section in Settings (dedicated).
- **Option B**: Inside the existing Chat section as a subsection.
- **Option C**: Top of the Agent editor (per-agent, not global).

`04-DECISIONS.md` covers which.

---

## 2. Tools popover in the chat input bar

### The chip

A new selector chip in the `FloatingInputCard` selector row (lines 942-977 of
`FloatingInputCard.swift`), next to existing chips (Sandbox, Thinking, Clipboard).

Icon: `wrench.and.screwdriver` or `hammer.fill`.
Label: "Tools" or just the icon (depending on available width).
Active state: highlighted when any tool override is in effect for this chat.

### The popover

Tapping the chip opens a popover (reusing the same `.popover(isPresented:, arrowEdge: .top)`
pattern as the model picker at line 1116).

**Contents**:

```
┌─ Tools ──────────────────────────────────┐
│                                          │
│  ○  Auto (let the agent decide)          │  ← radio 1
│  ●  Manual (pick specific tools)         │  ← radio 2
│  ○  Off (no tools this conversation)     │  ← radio 3
│                                          │
│  ── When "Manual" is selected ──         │
│                                          │
│  ▼ File system        [toggle per tool]  │
│    ☑ read_file                           │
│    ☑ edit_file                           │
│    ☐ delete_file                         │
│  ▼ Sandbox            [toggle per tool]  │
│    ☑ sandbox_pip_install                 │
│    ☐ sandbox_shell                       │
│  ▼ Search                                │
│    ☑ web_search                          │
│                                          │
│  ── Preflight search mode ──             │
│  Narrow / Balanced / Wide                │
│                                          │
│  ── Scope ──                             │
│  ( ) This message only                   │
│  (•) This conversation                   │
│  ( ) Save as agent default               │
│                                          │
└──────────────────────────────────────────┘
```

**Behavior**:

- **Auto** (default): current behavior, preflight picks tools per query
- **Manual**: user explicitly checks/unchecks tools, grouped by plugin/category
- **Off**: `disableTools: true` for this conversation
- **Preflight mode selector**: only shown when mode is Auto
- **Scope selector**:
  - "This message only" — override lives in the in-flight `GenerationParameters`
  - "This conversation" — override lives in `ChatWindowState` (ephemeral, resets on window close)
  - "Save as agent default" — writes to `Agent.toolSelectionMode` + `Agent.manualToolNames`
    via the existing agent update path

### Data model

New type in `Services/Chat/`:

```swift
public struct ChatToolOverride: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable {
        case auto       // preflight picks
        case manual     // explicit list
        case off        // toolsDisabled = true
    }
    public var mode: Mode
    public var manualToolNames: [String]?
    public var preflightMode: PreflightSearchMode?
    public var scope: Scope

    public enum Scope: String, Codable, Sendable {
        case message, conversation, agentDefault
    }
}
```

### State plumbing

**Ephemeral (conversation scope)**:
- Add `chatToolOverride: ChatToolOverride?` to `ChatWindowState`.
- On send, `ChatView.sendMessage` merges it with global config:
  - If override is set → use it
  - Else → fall back to `ChatConfiguration` globals (current behavior)

**Per-message scope**:
- Passed via `GenerationParameters.chatToolOverride`.
- The `ChatView.sendMessage` path sets it when the popover's scope is "this message only".

**Agent default scope**:
- The popover's save-to-agent action calls `AgentManager.updateAgent(...)` with
  `toolSelectionMode` / `manualToolNames` set.
- No new state needed — the existing agent-level layer is reused.

### Read-site changes

`SystemPromptComposer.finalizeContext` at line 96 gains a new parameter:

```swift
func finalizeContext(
    agentId: UUID,
    model: String?,
    query: String,
    toolsDisabled: Bool,
    toolOverride: ChatToolOverride?  // ← NEW
) async -> ComposedContext
```

Resolution order (highest precedence first):
1. `toolOverride.mode == .off` → return empty tools
2. `toolOverride.mode == .manual` → use `toolOverride.manualToolNames`, skip preflight
3. `toolOverride.mode == .auto` → run preflight with `toolOverride.preflightMode` if set, else global
4. No override → current behavior (read global config)

---

## 3. Experience Mode presets

### The enum

```swift
public enum ExperienceMode: String, Codable, CaseIterable, Sendable {
    case simple       // "Just chat — minimal features"
    case balanced     // "Recommended for most users" (DEFAULT)
    case power        // "Power user — cloud API / fast hardware"
    case developer    // "Expert — I control everything"
}
```

### What each mode implies

| Setting | Simple | Balanced | Power | Developer |
|---------|--------|----------|-------|-----------|
| Memory default enabled | off | off | on | user choice |
| Memory budgets | 500/500/500/100 | 1000/1000/1000/150 | 3000/3000/3000/300 | user choice |
| Tools default | off | auto (balanced) | auto (balanced) | user choice |
| Preflight mode | off | balanced | wide | user choice |
| Always-loaded capability tools | skip | skip | include | user choice |
| TurboQuant | on | on | on | user choice |
| Disk cache | on | on | on | user choice |
| Max context length | 4096 | 8192 | 32768 | user choice |
| Show advanced fields in Settings | hide | hide | show | show |

"User choice" in the Developer column means: Developer mode does NOT apply any preset — it
respects whatever the user has explicitly set. It's an "opt out of the persona system"
flag.

### Preset semantics — one-shot or persistent?

Two options, `04-DECISIONS.md` picks one:

**Option A — One-shot "apply"**:
- Clicking a mode button copies the preset values into the individual fields.
- After application, the mode is effectively forgotten; the user's config is just a bag of
  individual field values.
- Switching modes applies a new preset, overwriting previous values.
- **Pro**: Simple mental model, no precedence puzzle.
- **Con**: User loses any custom tweaks they made after picking a mode.

**Option B — Persistent layer**:
- The mode is a first-class field on `ChatConfiguration` / a new `AppConfiguration`.
- Each individual setting has a tri-state: `nil` means "use mode default", non-nil means
  "user override".
- Switching modes changes the default layer; overrides persist.
- **Pro**: User can "edit a preset" without losing their changes when switching modes.
- **Con**: More complex precedence rules; the UI has to show "default from mode" vs "user-set".

**Recommendation**: Start with Option A (simple). If users complain about losing tweaks,
upgrade to Option B.

### The Settings UI

New top-level section between "General" and "Chat":

```
┌─ Experience Mode ─ ⚙ ──────────────────────┐
│                                            │
│  Pick the setup that fits your workflow.   │
│  You can always change individual settings │
│  afterward.                                │
│                                            │
│  ┌─ ( ) Simple ──────────────────────┐    │
│  │   Just chat. No tools, no memory. │    │
│  │   Lightweight, fast responses.    │    │
│  └───────────────────────────────────┘    │
│                                            │
│  ┌─ (•) Balanced ────────────────────┐    │
│  │   Auto tool discovery, memory off.│    │  ← selected
│  │   Good on 16 GB Macs.             │    │
│  └───────────────────────────────────┘    │
│                                            │
│  ┌─ ( ) Power User ──────────────────┐    │
│  │   Memory on, wide tool search,    │    │
│  │   large context. For fast hw      │    │
│  │   or cloud-backed setups.         │    │
│  └───────────────────────────────────┘    │
│                                            │
│  ┌─ ( ) Developer ───────────────────┐    │
│  │   I manage every setting myself.  │    │
│  │   Presets stop applying.          │    │
│  └───────────────────────────────────┘    │
│                                            │
│  [ Apply ]  [ Reset to Balanced ]          │
│                                            │
└────────────────────────────────────────────┘
```

Hardware detection: when the section first renders, optionally highlight the recommended
mode based on `RuntimeConfig` RAM tiers:

- `< 16 GB`: recommend Simple
- `16-32 GB`: recommend Balanced
- `> 32 GB`: recommend Balanced (with "Power User also works" hint)

### First-launch onboarding

On first app launch after upgrade to this version:

- Show a modal: "Osaurus has new experience modes. Pick how you want to use it — you can
  always change later in Settings."
- Four cards matching the Settings picker.
- Highlight the hardware-recommended option.
- Dismissing or picking writes to `UserDefaults` (flag) + applies the preset.

---

## 4. Cross-cutting integration

### `ChatConfiguration` schema changes

New fields:

```swift
public struct ChatConfiguration {
    // ... existing fields ...

    /// User's selected experience mode. nil = no mode applied, use individual field values.
    public var experienceMode: ExperienceMode?

    /// Whether the first-launch onboarding modal has been shown.
    public var experienceOnboardingSeen: Bool

    // MODIFIED (both already exist):
    // preflightSearchMode: PreflightSearchMode? — nil means "follow experience mode default"
    // disableTools: Bool — unchanged
}
```

### `MemoryConfiguration` schema changes

```swift
public struct MemoryConfiguration {
    // MODIFIED:
    public var enabled: Bool  // default: false (was true)
    // ... existing fields ...
}
```

### `GenerationParameters` schema changes

```swift
public struct GenerationParameters: Sendable {
    // ... existing fields ...

    /// Per-message tool override from the chat input bar. nil = use window state / global.
    public let chatToolOverride: ChatToolOverride?
}
```

### `ChatWindowState` schema changes

Add a per-window override:

```swift
public final class ChatWindowState {
    // ... existing fields ...

    /// Active tool override for the current conversation. Reset when the window closes
    /// or when the user picks "This message only" scope.
    @Published public var toolOverride: ChatToolOverride?
}
```

### No changes needed to

- `vmlx-swift-lm` package — this is 100% osaurus-side
- `CacheCoordinator` / model runtime — cache is untouched
- Network layer — API schema unchanged (chatToolOverride doesn't cross the wire)
- Remote provider path — non-MLX services still use global config

---

## 5. Non-goals / things explicitly NOT changing

- **API compat**: `ChatCompletionRequest.cache_hint`, `session_id`, etc. stay unchanged.
  The new overrides are internal-only and don't leak to the HTTP surface.
- **Preflight algorithm**: still LLM-driven tool picking when mode is auto. We're not
  replacing it.
- **Agent settings**: agents still have `toolSelectionMode` / `manualToolNames` as their
  own layer. The new override system doesn't replace them — it's a per-chat layer on top.
- **vmlx cache migration**: untouched. This work stacks on top of that branch.

---

## 6. Proposed precedence rules (critical — review carefully)

When multiple layers want to answer "should tool X be in the request?", the order is:

1. **Per-message override** (GenerationParameters.chatToolOverride) — if set, wins
2. **Per-conversation override** (ChatWindowState.toolOverride) — next
3. **Agent default** (Agent.toolSelectionMode / manualToolNames) — next
4. **Experience mode preset** (resolved from ChatConfiguration.experienceMode) — next
5. **Individual global setting** (ChatConfiguration.preflightSearchMode, .disableTools) — fallback
6. **Hardcoded default** (`.balanced`, tools enabled) — last resort

Same order applies to memory:

1. (No per-message or per-conversation memory override — one bigger rock)
2. Agent default (future: Agent.memoryOverride — not in scope yet)
3. Experience mode preset
4. Global `MemoryConfiguration.enabled`
5. Hardcoded `false`

This precedence has to be implemented as a single resolver function, not sprinkled across
call sites. Proposed location: `Services/Chat/ChatConfigurationResolver.swift` (new file).
