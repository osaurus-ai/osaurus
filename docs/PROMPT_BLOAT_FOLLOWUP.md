# Prompt Bloat — TTFT Follow-Up (osaurus chat UI)

**Status:** Tracked, **out of scope for the vmlx `b9da180` bump PR**. Filed
as a distinct concern so a future PR can take it on without needing to
re-derive the analysis from scratch.

## Symptom

Reported on 2026-05-07 against the Release build of the vmlx-bump branch:

| Model | Reported TTFT | Reported chat history | Token budget shown |
|---|---|---|---|
| `Zyphra/ZAYA1-8B-MXFP4` | 43.57 s (turn 1, 9 tokens), 28.45 s (turn 2, 22 tokens) | 1 user msg | 2.8 k / 131 k |
| `JANGQ-AI/Ling-2.6-flash-MXFP4-CRACK` | similar | 1 user msg | 2.8 k / 131 k |

User-perceived effect: a single "hi" greeting routinely takes 25–45 s before the
first visible token. The `genTps` rate (24–58 tok/s) is healthy — the bottleneck
is **prompt tokens**, not decode.

## Root cause (proven)

The chat UI's `SystemPromptComposer` assembles a multi-section preamble for
every request. A 2026-05-07 trace through `Views/Chat/ChatView.swift` →
`Networking/HTTPHandler.swift` → `Services/ModelRuntime.swift:629` →
`MLXBatchAdapter.generate(...)` showed the production breakdown:

| Section (order in `SystemPromptComposer`) | Approx. tokens | Gate |
|---|---|---|
| `platform` (line 46–50) | ~10 | always |
| `persona` (line 52–53) | ~80 | always (default persona is ~60 tokens) |
| `soul` SOUL.md (line 562–570) | 0–800 | gated on sandbox execution mode |
| `modelFamilyGuidance` (line 577–586) | 100–200 | `!effectiveToolsOff` |
| `codeStyle` + `riskAware` (line 594–611) | ~200 | file-mutation tools in schema |
| `agentLoopGuidance` (line 618–627) | ~400 | `todo`/`complete`/`clarify`/`share_artifact` in schema |
| `sandbox` / `folderContext` (line 633–650) | 600–1200 | sandbox or folder mode active |
| `capabilityNudge` (line 656–666) | ~150 | auto + tools on + `capabilities_load` |
| **Tool schemas (function specs)** | **~2000–2500** | **always when tools enabled** |
| Memory injection (per-turn) | 0–300 | `enabled=false` by default in the trace user's config |

Of that ~3000–3500 token budget, the **JSON tool schemas dominate** — the
"always loaded" tool set (skills + sandbox + capability + tool index + …) ships
the full function `parameters` schema for every tool inline on every turn.

Verification:

* **Direct API path with a one-message prompt and no tools:**
  `submit: model=ling-2.6-flash-mxfp4-crack promptTokens=37`,
  TTFT 2.82 s.
* **UI path (same hardware, same model, single greeting):**
  `generateEventStream: stream created tokenCount=3419`, TTFT 27–43 s.

Same model, same vmlx pin, same generation params — the delta is entirely the
host-side prompt construction.

## Why this is *not* a vmlx bug

* `enable_thinking=false` is correctly forced for Ling. ZAYA1 is
  reasoning-capable: osaurus defaults it to `enable_thinking=false` only
  when the caller has not made an explicit choice, and preserves
  `disableThinking=false` as a real opt-in to reasoning mode.
* `installCacheCoordinator: hybrid=true` fires for both families.
* Decode tok/s is in the expected range for the bundle quant tier.
* A clean 37-token prompt produces correct multi-turn behaviour:
  Ling: 2.8 → 1.4 → 2.2 s TTFT, full recall + correct math, no stuck stream.
  ZAYA: 4.6 → 1.3 → 1.9 s TTFT, no "Osiris/mythology" persona drift.

## Why the persona drift goes away with a clean prompt

ZAYA1 8B is small enough that the heavy 3500-token preamble (sandbox blocks,
agent-loop discipline, ~20 tool schemas) appears to push the model into a
roleplay-y completion ("Hello! I'm Osiris, your friendly AI assistant
specializing in ancient myth and history…") rather than the canonical assistant
greeting. Stripping the preamble eliminates the drift — proven with the
no-system-prompt API test that returned "Hello! I am an AI-powered
conversational entity…".

## Recommended fix shape (separate PR)

1. **Lazy tool schemas.** Ship only the *names* + one-line descriptions of
   always-loaded tools in the system prompt; expose
   `capabilities_load(tool_id)` (already wired) as the on-demand schema fetch.
   This alone removes ~2000 tokens from a typical greeting.

2. **Conditional `agentLoopGuidance`.** Today it fires whenever `todo` /
   `complete` / `clarify` / `share_artifact` appear in the resolved schema,
   which is "always" for non-trivial sessions. Promote it to a
   "first-call-needed" cheat sheet that's omitted when no `todo`/loop tool has
   been invoked in the current session.

3. **Sandbox section size cap.** Cap the `SandboxToolGuide` rendering at
   ~400 tokens, push the long-form runtime hints into individual tool
   descriptions where they're only paid for if that tool's schema is actually
   loaded.

4. **Preflight skip on trivial inputs.** In `auto` mode, skip preflight
   capability search for inputs under ~10 chars or matching common
   non-discovery patterns ("hi", "hello", "thanks").

Each of these is independent and can land separately. Priority is **#1**;
that's where ~70% of the budget goes.

## Why this isn't blocking the bump PR

The vmlx `b9da180` bump fixes:

* Ling B>1 RoPE / per-slot offsets / `BailingHybrid.applyRotaryPosition`
* ZAYA1 CCA-attention hybrid wiring (`ZayaCCACache`, eager `setHybrid(true)`)
* `ReasoningParser.forPrompt` prompt-tail derivation (closes the 2026-05
  Ling Stop-stuck regression)
* `BailingLinearAttention.recurrentGLA` fused Metal kernel (closes the
  Ling JANGTQ2 long-prompt `EXC_BAD_ACCESS`)
* `BatchEngine` lifecycle: `isShutdown`, `controlPlaneYieldInterval`,
  `updateMaxBatchSize(_:)` (host-side hot-resize support)
* `Evaluate.swift` yields `.info` BEFORE post-generation `cacheStoreAction`
* Audio MediaSalt + DSV4 reasoning_effort strip (smaller fixes)

Those are correctness fixes against the runtime. The TTFT pain is a
host-side **prompt-shape** issue that's been latent since long before this
bump and that holds at every prior commit. Bundling it in here would balloon
this PR past the bump-and-wire scope it has now and make CI / review
substantially riskier.

## Pointers for the follow-up author

* `Packages/OsaurusCore/Services/Prompt/SystemPromptComposer.swift` — entry
  point for the per-section assembly. The token-budget pre-flight already
  exists at `ContextBudgetPreview`; the disable-info path it emits can be
  reused to gate the heavier sections.
* `Packages/OsaurusCore/Services/Tool/ToolSearchService.swift` and
  `ToolIndexService` — already index tools for capability search, so the
  on-demand schema fetch infrastructure is partially in place.
* `Packages/OsaurusCore/Services/Context/PreflightCapabilitySearch.swift` —
  already runs ahead of generation; would be the natural place to short-circuit
  for trivial inputs.
* `Packages/OsaurusCore/Tests/Service/PromptSectionOrderingTests.swift`,
  `ContextBudgetPreviewTests.swift`,
  `SystemPromptComposerToolResolutionTests.swift` — existing coverage that
  any refactor will need to pass.

When picking this up, capture before/after `tokenCount=` on the same
greeting + agent profile and a TTFT measurement for each — that's the
unambiguous regression / improvement signal.
