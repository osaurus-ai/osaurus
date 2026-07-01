# Open-issue fix sweep — triage

A pass over the open issue backlog to find genuinely reproducible defects, fix
the ones with a real code gap, and document the ones already resolved on `main`
(several of which are *fixed but unreleased* — they need a release tag, not a
code change).

## Genuine fixes in / tied to this sweep

| Issue | Title | Fix |
|------|-------|-----|
| #1719 | Plugin importer unauthenticated → large repos rate-limit and never finish | **This PR.** `GitHubSkillService` attaches a `GITHUB_TOKEN`/`GH_TOKEN` bearer token when present (60→5,000 req/hr) and the rate-limit error now tells the user how to raise the limit. Absent a token, behavior is byte-identical. |
| #358 | `Unsupported model type: hunyuan_v1_dense` | **vmlx-swift #97** (engine port) + osaurus pin bump (follows once #97 merges). Live-proven on `HY-MT1.5-7B-mlx-8Bit`: deterministic load+decode, clean EOS stop, no loop/leaks; EN→FR and EN→zh translations fluent and correct. |

## Already resolved on `main` — triage to close

Each was investigated against current `main` (HEAD `62f6d6ae`) by reading the
exact code path and confirming the fixing commit is an ancestor.

| Issue | Title | Disposition |
|------|-------|-------------|
| #1718 | MCP-provider tools need two turns (capabilities_load defers schema) | Fixed by #1760 (`CapabilitiesLoadTool.loadedSchemaBlock`, append-only, no KV-prefix change). |
| #416 | Command-based MCP (stdio) providers do not work | Fixed by #1126/#1524/#1541 — full host/sandbox stdio connect path, reachable from UI + Test, inherits app env + augments PATH. Residual: new stdio providers default to `.sandbox`; host-venv servers (e.g. FastMCP) need Execution Host → "Run on host". |
| #587 | Add support for local MCP server (command: node/npx/uv) | **Duplicate of #416** — the host stdio command path (incl. #1524 "Improve host stdio MCP command resolution" for node/npx/uv on PATH) already provides exactly this. Close as duplicate. |
| #1129 | MCP stdio `click_element`/`type_text` SIGSEGV (accessibility write) | Fixed by #1130 (`dbf4bd36`): AX-write tools routed onto the main actor (`ExternalTool.invocationIsolation` → `.mainActor`), regression-tested. Crash itself lived in the external `libosaurus-macos-use.dylib`. |
| #1228 | 0.18.29 Metal `MTLCommandBuffer` SIGABRT (uncaught C++ exception) | **Fixed but unreleased.** vmlx-swift #82 (`BatchEngine` drains GPU before finishing the stream) + osaurus #1736 (unload drain-before-free) are on `main` (pin `9e0b60f`); tagged releases still pin pre-#82. Needs a release tag, not a code change. |
| #443 | Support pre-downloaded HF models from local cache | Implemented via `ExternalModelLocator` (#1355/#1372/#1420/#1531): in-place discovery of `~/.cache/huggingface/hub`, configurable path, no copy, symlink-safe. |
| #647 | "no results whatsoever" | The one concrete defect (Gemini `additionalProperties` 400) is fixed + regression-tested (`geminiCompatibleSchema`, `9974a5bc`). Remainder is a stale multi-symptom report (too-many-tools config, vague tool-fidelity gripes). |
| #662 | Invalid request format | Resolved on main (request-encoding path). |
| #789 | Search tool never found by any model | Resolved on main. |
| #615 | Connect to local lemonade / OpenAI-compat server | Resolved on main. |
| #1496 | Gemma 4 weird output when tools enabled | Resolved on main (Gemma-4 tool path). |
| #903 | System prompts not injected at runtime | Resolved on main. |
| #823 | "I can't use tools" despite permissions | Resolved on main. |
| #1422 | XDG / Apple directory spec compliance | Resolved on main. |

## Follow-ups identified (not in this PR)

- **#416 residual** — default new stdio providers to `.host` (or auto-detect host
  interpreters) so FastMCP host-venv servers work without manually switching
  Execution Host. Needs maintainer call on the default.
- **#416 robustness** — parent holds the child's stdout *write* end open in the
  host stdio runner, so a child that dies mid-session only EOFs at the
  connect/discovery timeout. Currently masked by `withTimeout`.
- **#1228 release** — cut a release tag pinning vmlx ≥ `6b77b1e` so users off the
  current tagged build stop hitting the (already-fixed) Metal SIGABRT.

## Regression audit (past ~2 weeks) — chat template / loading / reasoning / tools

Audited the recent Mistral template overhaul (#85–#88), Gemma tool/attention
changes (#60/#61/#76), Qwen3 (#78), LFM2 (#90), Laguna (#77) for regressions in
incoherence/looping, chat templates, reasoning leak, tool use, system prompt,
and window/cache.

**Fixed (vmlx-swift #100 + #101, in the repin):**
- Mistral chat looping/incoherence — `convertTokenToId` unk-pitfall misrouted
  tool-bearing Mistral to a ChatML/Gemma template (#100, reroute ladder).
- Mistral catch-path fallback — a Mistral whose native template *throws* fell to
  the Gemma/Nemotron `orderedFallbacks`; added a Mistral arm (#101, F1).
- Mistral3/Pixtral image-token resolution round-trip-guarded (#101, F2).

**Verified CLEAN (no regression):** reasoning-leak gating (all fallbacks gate an
open `<think>` on `enable_thinking` with safe defaults), system-prompt doubling
(Mistral injects default once), strip-tool-markers (#62 control-token only),
Mistral tool-call render↔parse round-trip, Gemma routing/template/reasoning/tools
(channel→reasoning strip, `.gemma4` parser handles #61/#76/#62), Gemma SWA cache
(generic, no JANG dependency).

**Proper Gemma loading (the specific concern):** NOT neglected — plain bf16,
`q4_0-unquantized` (standard affine), MXFP4, JANG_4M all route to the same VLM
`Gemma4` class and inherit identical quant/upcast/template/cache handling.

**Documented gaps (not fixed — latent / low-priority, for follow-up):**
- **`Gemma4TextModel` (text-only LLM path) lacks the #60 fp32 long-context
  upcast** that its VLM sibling has → a text-only `gemma4_text` export would emit
  `<pad>` past ~26k tokens. Latent (no current bundle ships that top-level type).
  Fix: mirror `needsUpcast = fp16 || (bf16 && !isSliding)` into `Gemma4Text.swift`.
- gemma-3n could mis-fall-back to the Gemma-4 `<|turn>` template if its native
  template ever failed to parse (the `bos=="<bos>"` sniff matches both); not
  currently triggered.
- MiniMax-M2 fallback sits outside the `VMLX_CHAT_TEMPLATE_FALLBACK_DISABLE` guard
  in one macro copy (asymmetric opt-out); a dead duplicate Nemotron branch exists
  (cleanup).
- `#87` `[SYSTEM_PROMPT]`-marker gate could skip tool-grounding for a legacy
  Mistral bundle whose template uses `[INST]` without `[SYSTEM_PROMPT]` (modern
  Mistral all ship it; low risk).
