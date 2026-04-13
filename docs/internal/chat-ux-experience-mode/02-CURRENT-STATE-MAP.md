# Current State Map

> Where the relevant code lives today, verified via code search. Every reference is a
> file:line so reviewers can jump straight to it.

---

## A. Chat input bar (where the Tools button would go)

**Main file**: `Packages/OsaurusCore/Views/Chat/FloatingInputCard.swift`

| Element | Line | Notes |
|---------|------|-------|
| `FloatingInputCard` view | 13 | Top-level struct |
| `inputCard` property | 1738-1778 | VStack layout — queued banner, attachments, text field, button bar |
| Button bar HStack | 1957-1985 | Media button, voice button, keyboard hint, stop/resume, send |
| Voice button (`mic.fill`) | 1782-1807 | Existing affordance in the row — good precedent for a Tools icon |
| Media/attachment button | ~1960 | Opens file picker |
| Model selector chip | 1061-1123 | Uses `.popover(isPresented:, arrowEdge: .top)` — pattern to reuse |
| Model options selector chip | 1213 | Another popover precedent |
| Context breakdown popover | 1025 | Third popover precedent |
| Selector chip row | 942-977 | Thinking / Sandbox / Clipboard chips — this is where a "Tools" chip would slot in |
| `@Binding var text` | 15 | User input |
| `@Binding var activeModelOptions` | 22 | Per-request model options |
| `var agentId: UUID?` | 34 | Current agent (tools popover would query this) |
| `var workInputState: WorkInputState?` | 38 | Work vs chat mode flag |

**Popover reuse pattern** (from existing model picker):
```swift
@State private var showModelPicker: Bool = false
// ...
.popover(isPresented: $showModelPicker, arrowEdge: .top) {
    ModelPickerView(...)
}
```

A Tools popover would use the identical pattern.

---

## B. Tool selection — where it's read today

### Global config sources

| Setting | File | Line | Default |
|---------|------|------|---------|
| `ChatConfiguration.preflightSearchMode` | `Models/Chat/ChatConfiguration.swift` | 73 | `.balanced` |
| `ChatConfiguration.disableTools` | `Models/Chat/ChatConfiguration.swift` | 79 | `false` |

### Read sites

| Caller | File | Line | What it does |
|--------|------|------|--------------|
| `SystemPromptComposer.resolveTools` | `Services/Chat/SystemPromptComposer.swift` | 104 | `let mode = ChatConfigurationStore.load().preflightSearchMode ?? .balanced` |
| `PluginHostAPI.enrich` | `Services/Plugin/PluginHostAPI.swift` | 641 | Same pattern for plugin-dispatched requests |
| `ChatView.sendMessage` | `Views/Chat/ChatView.swift` | 821 | Passes `toolsDisabled: chatCfg.disableTools` into `composeChatContext` |
| `SystemPromptComposer.finalizeContext` | `Services/Chat/SystemPromptComposer.swift` | 96-146 | `toolsDisabled` parameter flows through, line 146 short-circuits: `guard !toolsDisabled else { return [] }` |

### Path from "user presses send" to "tools in request"

```
ChatView.sendMessage
  → SystemPromptComposer.composeChatContext(agentId, model, query, toolsDisabled: chatCfg.disableTools)
    → finalizeContext
      → resolveTools(agentId: , query: , toolsDisabled: )
        → reads ChatConfigurationStore.load().preflightSearchMode
        → PreflightCapabilitySearch.search(query:, mode:) — LLM picks tools
        → ToolRegistry.specs(forTools: [names])
        → ToolRegistry.alwaysLoadedSpecs(mode: , excludeCapabilityTools: )
  → ComposedContext { tools: [Tool] }
    → passed to API request as `tools:` field
```

**Conclusion**: There is **zero** per-chat override mechanism today. Everything reads from the
global `ChatConfigurationStore` at request time.

---

## C. Per-agent tool preferences (the one existing layer)

**File**: `Packages/OsaurusCore/Models/Agent/Agent.swift`

| Field | Line | Type | Notes |
|-------|------|------|-------|
| `toolSelectionMode` | 91 | `ToolSelectionMode?` | `.auto` or `.manual` |
| `manualToolNames` | 92 | `[String]?` | Explicit tool list when `.manual` |
| `manualSkillNames` | 93 | `[String]?` | Same for skills |

**Effective-value resolution** (`Managers/AgentManager.swift`):

| Method | Line |
|--------|------|
| `effectiveToolSelectionMode(for:)` | 347 |
| `effectiveManualToolNames(for:)` | 354 |
| `effectiveManualSkillNames(for:)` | 361 |

**Pattern** (line 347-353):
```swift
public func effectiveToolSelectionMode(for agentId: UUID) -> ToolSelectionMode {
    guard let agent = agent(for: agentId) else { return .auto }
    if agent.id == Agent.defaultId { return .auto }
    return agent.toolSelectionMode ?? .auto
}
```

**Read site**: `SystemPromptComposer.resolveTools` line 148.

**Important**: Agent-level overrides exist for *tool selection* but NOT for:
- `disableTools` (global)
- `preflightSearchMode` (global)
- Memory enable/disable (global)
- Memory budgets (global)

---

## D. Memory enable/disable

**File**: `Packages/OsaurusCore/Models/Memory/MemoryConfiguration.swift`

| Field | Line | Default |
|-------|------|---------|
| `enabled: Bool` | 53 | **true** (line 94) |

### Read sites

| Caller | File | Line |
|--------|------|------|
| `MemoryContextAssembler.buildContext` | `Services/Memory/MemoryContextAssembler.swift` | 46, 67 |
| `SystemPromptComposer.appendMemory` | `Services/Chat/SystemPromptComposer.swift` | 50 |

**Short-circuit behavior** (MemoryContextAssembler:46):
```swift
guard config.enabled else { return "" }
```

Returns empty string when disabled — the memory section of the prompt is effectively skipped.
The call still happens unconditionally from `finalizeContext` line 99, but it's a no-op.

### UI exposure

- **Nowhere visible** in `ConfigurationView.swift` — no UI toggle exists today. The only way
  to disable memory is editing the JSON config file directly at
  `OsaurusPaths.memoryConfigFile()`.

### Persistence

- `MemoryConfigurationStore.save(_:)` / `.load()` at lines 195-227.
- JSON file at `OsaurusPaths.memoryConfigFile()`.

### Per-agent memory settings

**None**. Memory config is fully global. No `Agent.memoryEnabled` field exists.

---

## E. Experience level / persona concept

**Search results**: ZERO matches for `experienceLevel`, `usageMode`, `profile`, `persona`
(other than serialization field naming), `preset`.

**Closest existing concept**: `ModelEvictionPolicy` in `ServerConfiguration.swift` has
`.strictSingleModel` vs `.manualMultiModel` — a two-way mode switcher. That's the only
preset-style field in the entire config surface.

**Hardware detection** (relevant for auto-picking a default persona):
`Services/ModelRuntime/RuntimeConfig.swift` already detects RAM:

| Method | Line | Behavior |
|--------|------|----------|
| `autoKVBits` | 52 | Checks `ProcessInfo.processInfo.physicalMemory` — returns 8 if headroom < 16 GB |
| `autoTurboQuant` | 61 | Same check — unconditionally true after C-002 |
| `defaultMaxKV` | 70 | Tiered: 8K / 16K / 32K / 65K by RAM |
| `defaultPrefillStep` | 83 | Tiered: 1K / 2K / 4K by RAM |

This is the foundation — we can reuse the same tiers for persona auto-selection.

---

## F. Settings UI top-level structure

**File**: `Packages/OsaurusCore/Views/Settings/ConfigurationView.swift`

| Section | Line | Contents |
|---------|------|----------|
| General | 112 | Hotkey, start at login, dock icon, beta updates, core model, CLI, storage, maintenance |
| Chat | 241 | System prompt, temperature, max tokens, context length, top P, max tool attempts, preflight search, disable tools, clipboard monitoring |
| Work | 376 | Agent temperature, max tokens, top P, max iterations |
| Server | 386 | Port, expose to network, CORS origins |
| Local Inference | 436 | Sampling, KV cache, disk cache, eviction policy |
| Voice | 578 | Voice settings |
| Notifications | 591 | Toast settings |

Layout: vertical scrolling `ScrollView` with `SettingsSection(title:icon:)` per group. Inside
each section, `SettingsSubsection()` groups related fields. Search filtering via
`matchesSearch()` at line 76.

Adding a new top-level section is low-cost: create a new `SettingsSection(title: "Experience Mode", icon: "slider.horizontal.3")` and place it.

---

## G. Chat window / session state

**File**: `Packages/OsaurusCore/Managers/Chat/ChatWindowState.swift` (approx)

Holds per-window state: session ID, agent ID, turns array, streaming flags, etc.
Currently **no per-session override fields** for tools / memory / preflight mode.

Any new per-chat override state has two possible homes:

1. **`ChatSession`** (the data model — persistent across window close/reopen if sessions are saved)
2. **`ChatWindowState`** (ephemeral — tied to the window, resets on close)

`04-DECISIONS.md` discusses which is right.

---

## H. Currently existing chips in FloatingInputCard selector row

`FloatingInputCard.swift` lines 942-977:

| Chip | Purpose | Scope |
|------|---------|-------|
| Model selector | Pick model | Per-message / session |
| Model options | Per-model knobs (e.g., aspect ratio) | Per-message |
| Thinking toggle | Enable/disable thinking mode | Per-message / session |
| Sandbox toggle (work mode) | Enable sandbox for work | Per-session |
| Clipboard toggle | Include clipboard context | Per-message |

A Tools chip would sit naturally alongside these. Pattern established.
