# Open PR and Bug Development Plan

Snapshot update: 2026-07-02 13:30 UTC, repo `osaurus-ai/osaurus`.

This snapshot supersedes the older channel sections below for the Agent Channel
testing question.

## Agent Channel Readiness - 2026-07-02

Maintainer question: "how are you doing with the agent channels? is it ready for
testing?"

Current answer:

- Slack Agent Channel (#1707) is draft, merge-clean, and green on required CI.
  It provides the Slack adapter, credential storage, allowlists, read/search/send
  routing, inbound normalization, and service/security tests.
- Telegram Agent Channel (#1709) is draft, merge-clean, and green on required
  CI. It provides the Telegram adapter, token storage, chat/topic allowlists,
  read/search/send routing, update dedupe, message storage, and service/security
  tests.
- The shared `agent_channel_*` action vocabulary existed on `main`, but the
  native tools were not registered in `ToolRegistry`. That made the adapters
  service-testable but not end-to-end testable from the agent tool path.

Goal:

- Make Agent Channels ready for maintainer service-level testing through the
  provider-neutral `agent_channel_*` tools, while keeping WIP settings UI hidden
  and preventing external API/MCP callers from sending channel messages.

Execution plan:

1. Shared readiness PR:
   - Register the provider-neutral Agent Channel tools as native dynamic tools.
   - Keep them out of the always-loaded prompt baseline.
   - Keep them off external surfaces through `externallyDeniedToolNames`.
   - Prove no Discord-specific phantom tools are introduced.
   - Run focused channel, registry, and external-denial tests.
2. Adapter PR refresh, parallel after the shared readiness PR is available:
   - Keep #1707 and #1709 draft until the shared tool registration branch is
     merged or explicitly used as their base.
   - Rebase Slack and Telegram independently after the shared registration path
     lands.
   - Re-run the adapter tests plus one shared Agent Channel tool-path smoke for
     each adapter.
3. Testing boundary:
   - Ready for maintainer testing means app-surface `agent_channel_*` calls can
     list connections, inspect diagnostics, read/search permitted messages,
     draft outbound messages, and send/reply only when the connection policy
     allows it.
   - Live Slack/Telegram tests still require real bot credentials and
     workspace/chat allowlists.
   - Production webhook receiver, background poller, and final visible settings
     placement remain follow-up integration work.

Parallelization notes:

- The shared readiness PR owns only `ToolRegistry`, focused registry/security
  tests, and this plan update.
- Slack and Telegram adapter branches stay independent once they consume the
  shared registration behavior.
- Inbox/audit UI and remote Computer Use-over-channel work should remain
  separate until at least one native adapter completes service-level testing.

Snapshot update: 2026-06-16 23:11 UTC, repo `osaurus-ai/osaurus`.

This section is the current actionable plan. Older dated sections remain below
as history and should not override this snapshot.

## Current Live State - 2026-06-16 23:11 UTC

- `origin/main` is `b768bbcb2a86e7cf577e69fe15040c3e1ba20c22`
  (`fixed anthropic api failing on remote providers (#1540)`).
- The local checkout and `mimeding/osaurus` fork `main` are synced to the same
  commit.
- Recently landed work since the last active planning pass includes #1528,
  #1529, #1530, #1531, #1532, #1538, #1540, and the 0.20.2 tag/appcast work.
- Current author-owned review stack is ready and green:
  - #1527, system prompt injection proof trace: `CLEAN`, checks `SUCCESS`.
  - #1533, agent defaults and team API: `CLEAN`, checks `SUCCESS`.
  - #1536, MCP OAuth global proxy routing: `CLEAN`, checks `SUCCESS`.
  - #1475, voice input and speech output controls: `CLEAN`, checks `SUCCESS`.
- Newly actionable bug: #1539 reports that `osaurus mcp` returns an empty tool
  list when Server > Network exposure disables loopback auth bypass. Current
  source confirms the stdio bridge calls `/mcp/tools` and `/mcp/call` without
  an `Authorization` header.
- Evidence-request comments were posted on bugs needing reporter confirmation:
  #1496, #1161, #1129, #662, #1225, #615, and #903.

## Immediate Execution Order - 2026-06-16

1. Publish the #1539 fix as a focused PR:
   - Preserve zero-config behavior for local-only servers.
   - Let `osaurus mcp` attach `Authorization: Bearer ...` from
     `OSAURUS_MCP_ACCESS_KEY`, compatible env names, or `--access-key`.
   - Update README / MCP docs and add CLI tests for token parsing and request
     header construction.
2. Ask `tpae` to review the green stack in small groups:
   - #1527: bug-proof and runtime validation trace.
   - #1533: agent defaults and team API.
   - #1536: MCP OAuth global proxy coverage.
   - #1475: voice input/output controls.
3. Keep all issue threads awaiting reporter evidence in watch mode. Do not
   claim those bugs fixed until new reporter evidence or local reproduction
   confirms current-main behavior.
4. After #1536 and the #1539 PR land, reassess remaining global proxy and MCP
   gaps. Likely candidates are CLI pull, theme/router clients, repository
   fetches, and any remaining bespoke `URLSession` creation outside shared
   proxy policy.
5. Defer broad document-stack, historical conflict, localization, voice, and
   runtime research lanes until the current green stack receives maintainer
   direction or merges into `main`.

## Discord Review Message - 2026-06-16

Suggested message:

```text
@tpae quick review request when you have a window: the current author-owned stack is green and CLEAN.

- #1527: system prompt injection proof trace / runtime validation evidence.
- #1533: agent defaults and team API.
- #1536: MCP OAuth global proxy coverage.
- #1475: voice input and speech output controls.

I also picked up #1539 as the next focused bug fix: `osaurus mcp` needs to pass a Bearer access key when network exposure disables loopback trust, otherwise stdio clients see an empty tools list from HTTP 401.
```

Snapshot update: 2026-05-16 07:33 UTC, repo `osaurus-ai/osaurus`.

This section is the current consolidated automation plan. It supersedes every
older dated section below; keep the older sections only as history.

## Current Live State - 2026-05-16 07:33 UTC

- `origin/main` is `bb2e7f7cc079afa3c1c56bb3a92cef0b1e2bad2f`
  (`edit pasted content (#1111)`).
- Latest main remote gates are green on `bb2e7f7c`:
  - CI `25950238914`: `success`.
  - Release Drafter `25950238917`: `success`.
  - pages `25950238605`: `success`.
- Exact-main local release gate passed for `bb2e7f7c` in
  `/private/tmp/osaurus-coord/worktrees/main-bb2e7f7c`; evidence:
  `/private/tmp/osaurus-coord/evidence/builds/main-bb2e7f7c.log`
  (`swift build --package-path Packages/OsaurusCore -c release`, 397.59s,
  existing warnings only).
- Open PRs evaluated: 29.
- Open issues evaluated: 32.
- Open bug reports evaluated: 10.
- Open feature requests evaluated: 21 labeled `enhancement`; #1050 is
  unlabeled but remains a reliability bug lane.
- Recently landed work since the previous snapshot:
  - #1101 landed independent glass toggles.
  - #1103 landed pasted content chip and preview.
  - #1105 fixed the update button.
  - #1106 added Claude plugin import support.
  - #1107 fixed the import skills dialog freeze.
  - #1108 refreshed screenshots.
  - #1109 added development plugin install support.
  - #1111 edited pasted content behavior and is now the current main tip.

## Nudge Decision - 2026-05-16 07:33 UTC

No GitHub nudge was posted in this refresh.

Reasons:

- No non-draft, green, mergeable PR changed into a clearly reviewable
  agent-owned state during this refresh.
- #1110 is open and green, but it is new enough that the T1 review cadence has
  not elapsed.
- #1006 and #873 are open and green but need maintainer/product review rather
  than an automated pressure nudge.
- #1059 and #1024 remain `DIRTY`, so they stay in rebase/conflict buckets.
- Draft document-stack and security PRs should not be promoted or nudged while
  their stack ordering and red checks remain unresolved.

## Immediate Execution Order - 2026-05-16

1. Treat `bb2e7f7c` as the verified dispatch base while remote gates and the
   local release evidence above remain green.
2. Execute disjoint current-main lanes in parallel:
   - Lane D: #1050 eval CLI noninteractive hang.
   - Lane B: #823/#789/#995 tool exposure and capability-search diagnostics.
   - Lane C: #615/#828/#1059 remote provider compatibility and model discovery.
   - Lane E: #416/#1058 MCP stdio documentation mismatch, docs-only.
3. Keep #1091/#232 global proxy as the next design-plus-implementation feature
   lane after provider/tool fixes because it touches shared network policy.
4. Keep document-stack PRs parked until #974 is replaced or rebased cleanly.
5. Keep conflicted historical PRs in observe-only mode unless a maintainer asks
   for a focused conflict proof or branch rescue.

## Execution Results - 2026-05-16 07:33 UTC

- Lane D (#1050) executed in `Packages/OsaurusEvals/**`: eval startup now has a
  timeout guard and emits an errored JSON report instead of hanging. Validation:
  `swift build --package-path Packages/OsaurusEvals`,
  `swift test --package-path Packages/OsaurusEvals`, timeout smoke tests with
  and without `CI=true`, and `git diff --check -- Packages/OsaurusEvals`.
- Lane C (#615/#828/#1059) executed in provider scope: OpenAI-compatible model
  discovery falls back to configured manual model IDs when `/models` is
  unavailable or schema-incompatible, while auth/server errors still fail.
  Validation: `swift test --package-path Packages/OsaurusCore --filter
  RemoteProviderModelDiscoveryTests`, `swift test --package-path
  Packages/OsaurusCore --filter Provider`, and scoped `git diff --check`.
- Lane B (#823/#789/#995) executed in tool/context scope:
  `capabilities_search` can expose indexed/enabled tools from BM25 when the
  embedding side is unavailable, and diagnostics now report requested versus
  effective fused cutoffs. Validation: focused tool, preflight, capability, and
  tool database tests plus scoped `git diff --check`.
- Lane E (#416/#1058) executed as docs-only: `osaurus mcp` is documented as the
  supported stdio bridge, and Remote MCP Providers are clarified as URL-based
  HTTP/SSE only. Validation: `git diff --check` over the touched docs.

## PR Publication Result - 2026-05-16 08:27 UTC

- A clean publication worktree was created from `origin/main` at `bb2e7f7c`.
- Only the intended plan, provider, tool-search, eval, and MCP docs files were
  applied to the publication worktree; unrelated dirty theme, schedule, and
  coordinator work in the original checkout was left untouched.
- Opened upstream PR #1112 from `mimeding:codex/development-plan-bug-lanes`,
  marked it ready after GitHub checks passed, and posted validation evidence.
- GitHub checks green on #1112: `test-core`, `test-cli`, `swiftlint`,
  `shellcheck`, and `update_release_draft`.
- Review request via `gh pr edit --add-reviewer tpae` was blocked by token
  permission (`RequestReviewsByLogin`), so the evidence comment records the
  reviewer handoff state.

## T-M Spec Lane Addendum - 2026-05-17

- Lane T-M is a docs/spec lane for multimodal plugin input/output. It is not a
  code lane unless review finds an explicit, small, testable plugin model hole.
- Ownership is `docs/MULTIMODAL_PLUGIN_ENGINE_SPEC.md` plus this tracked plan.
  Avoid provider, runtime, UI, and ABI churn in the same branch.
- The acceptance criteria now require ordered OpenAI-compatible media content
  parts, local capability gating, remote-consent boundaries, output stream
  semantics, tool isolation, session/cache isolation, and redacted observability.
- The threat model covers media exfiltration, BYO key leakage, media/prompt
  injection, SSRF, resource exhaustion, cross-agent/member contamination,
  reasoning disclosure, and cache confusion.
- Future implementation work should split into T-M1 through T-M7:
  host API contract tests, capability discovery, typed member request model,
  streaming/output adapter, tool and consent gate, observability/redaction, and
  a local-only manual smoke plugin.

## Maximum Parallelization Plan - 2026-05-16

These lanes are intentionally disjoint. Each implementation branch must start
from current build-clean `origin/main`, must not merge or close upstream PRs or
issues, and must acquire a mutation lock before writing to GitHub.

| Lane | Issues/PRs | Status | Write scope | Validation | Next action |
| --- | --- | --- | --- | --- | --- |
| B. Tool exposure matrix | #823, #789, #995; observe #1110 | Dispatch after local gate | `Packages/OsaurusCore/Services/Tool/**`, `Packages/OsaurusCore/Services/Context/**`, focused chat/tool diagnostics tests | Tool search/index tests, capability-search evals, focused chat tests | Pin why granted tools/search tools are not exposed, then add diagnostics or recall fixes without touching provider networking. |
| C. Provider compatibility | #615, #828, #1059 | Dispatch after local gate; #1059 draft is `DIRTY` | `Packages/OsaurusCore/Services/Provider/**`, provider tests only | Remote provider tests, model discovery tests | Add fallback behavior for OpenAI-compatible providers without `/models`, direct model IDs, and MiniMax-compatible endpoints. |
| D. Eval CLI hang | #1050 | Dispatch first; isolated | `Packages/OsaurusEvals/**` only | `swift test --package-path Packages/OsaurusEvals`; CLI smoke with and without `CI=true` | Make eval CLI noninteractive/timeout-safe on current main and document the behavior in help text if needed. |
| E. MCP stdio docs | #416, #1058 | Dispatch first; docs-only | `README.md`, `docs/REMOTE_MCP_PROVIDERS.md`, `docs/FEATURES.md`, `docs/DEVELOPER_TOOLS.md` | `git diff --check` | Align docs with command-based MCP provider support and clarify remote transport limits. |
| F. Global proxy | #1091, #232 | Design next | Shared URLSession/proxy policy, settings UI, model download/provider/plugin call sites | Proxy config unit tests plus model/provider smoke tests | Draft architecture first because it crosses provider, model download, plugin, and remote docs scopes. |
| T-M. Multimodal plugin I/O spec | Plugin/council roadmap; adjacent to #793, #332, #417, #1002 | Spec lane; docs-only | `docs/MULTIMODAL_PLUGIN_ENGINE_SPEC.md`, `docs/OPEN_PR_BUG_DEVELOPMENT_PLAN.md` | `git diff --check -- docs/MULTIMODAL_PLUGIN_ENGINE_SPEC.md docs/OPEN_PR_BUG_DEVELOPMENT_PLAN.md` | Use the new acceptance criteria, threat model, and T-M1-T-M7 slices to scope future implementation PRs; do not add ABI surface without a proven host gap. |
| H. Voice reliability and TTS | #689, #1002, #417, #445, #605 | Feature/quality follow-up | voice settings, TTS/transcription services, hotkey path | Voice service tests plus manual audio smoke | Pick one small target after D/B/C settle: language selection or function-key hotkey. |
| I. Model/download compatibility | #443, #358, #1065, #886, #833 | Research/design | model discovery/download/runtime adapters | Compatibility notes and focused model manager tests | Produce design notes before code; avoid overlapping provider fallback work. |
| J. Document stack | #929/#936/#937/#939/#940/#941/#942/#983/#1022/#1023/#1024 and #974 | Parked | document/plugin stack | Full document-stack sequencing gates | Do not dispatch until stack base is rebuilt from current main. |
| K. Historical PRs | #873, #913, #958, #963, #976, #985/#986/#987/#988/#992, #1006, #1048 | Observe or conflict proof only | varies | conflict proof first | Skip broad rebases; mine narrow fixes only when they match an active current-main lane. |

## T-J Document I/O Foundation Wave - 2026-05-17

T-J replaces the stale document-stack base with a current-main foundation lane.
It intentionally avoids format-specific import/export depth while unblocking
the PDF, DOCX, XLSX, and PPTX follow-up lanes with shared contracts.

Wave breakdown:

1. Foundation model and adapter contract:
   - Add format-neutral document structure, anchors, text/source ranges, and
     security/provenance metadata under `Models/Documents/**`.
   - Keep the existing plain-text attachment path stable by preserving
     `StructuredDocument.textFallback` and the legacy `DocumentParser` shim.
   - Current adapters may publish shallow trees; high-fidelity lanes replace
     leaves with page/table/cell/slide/shape subtrees.
2. Original-file bridge:
   - Mine #983 first, but rebuild it on current main and preserve the rule that
     on-disk artifacts stay inside the encrypted attachment/blob envelope.
   - Expose original bytes to local tools/plugins only through controlled
     metadata, path containment, and redacted logs.
3. Format read lanes:
   - XLSX read: mine #929 for typed workbook/sheet/cell models.
   - CSV/TSV: mine #939 for streaming tables and encoding/line-ending tests.
   - PDF: mine #940 for page/table/image anchors and active-content inspection.
   - PPTX/POTX: mine #1023 for slide/shape/chart/speaker-note anchors, replacing
     subprocess unzip with a bounded ZIP reader.
4. Emit/tool lanes:
   - Mine #936 for XLSX emit and round trips after the typed workbook lands.
   - Mine #937 for workbook tools after current tool/capability plumbing is
     stable.
   - Revisit #942/#941 only after the typed attachment and plugin extension
     surfaces can use the same anchor/security contracts.
5. Skills/runtime/docs lanes:
   - Mine #974 for on-demand high-fidelity skills after document I/O exists.
   - Mine #1022 for optional office-runtime detection with timeout/trust review.
   - Finish with #1024-style docs once code behavior is current-main real.

Acceptance gates for the foundation PR:

- Existing `PlainTextAdapter`, `PDFAdapter`, and `RichDocumentAdapter`
  behaviours remain compatible with the current attachment flow.
- Every parsed `StructuredDocument` carries a structure tree, at least one
  stable anchor, and explicit security metadata.
- Security metadata distinguishes `inspected`, `partiallyInspected`, and
  `notInspected`; adapters must not imply a deeper scan than they performed.
- Tests cover UTF-16 text ranges, paginated source offsets, digest metadata,
  HTML active/external content signals, and current adapter compatibility.
- Run focused document tests plus `git diff --check`; run the full core gate
  before publishing a PR.

## Open PR Plan - 2026-05-16 07:33 UTC

| PR | State | Merge state | Checks | Plan |
| ---: | --- | --- | --- | --- |
| #1110 | Open | `UNKNOWN` | green | Review after local evidence; likely Lane B/DSV4 guardrail adjacency. |
| #1059 | Draft | `DIRTY` | green | Mine provider fallback ideas into Lane C; do not promote while dirty. |
| #1058 | Draft | `UNKNOWN` | green | Fold into Lane E only if docs are still current-main clean. |
| #1048 | Open | `UNKNOWN` | green | Observe; local CI parity changes should not block current bug lanes. |
| #1024 | Draft | `DIRTY` | red | Park with document-stack docs. |
| #1023 | Draft | `UNKNOWN` | red | Park with document-stack typed presentation work. |
| #1022 | Draft | `UNKNOWN` | red | Park with document-stack runtime detection work. |
| #1006 | Open | `UNKNOWN` | green | Packaging/design review lane; no automated nudge. |
| #992 | Draft | `UNKNOWN` | green | Observe as possible system-prompt bug reference for #903. |
| #988 | Draft | `UNKNOWN` | green | Observe; eval smoke ideas may inform Lane D only if scoped. |
| #987 | Draft | `UNKNOWN` | green | Observe; API guardrails may inform provider/tool lanes after B/C. |
| #986 | Draft | `UNKNOWN` | green | Observe; docs workflow only. |
| #985 | Draft | `UNKNOWN` | green | Mine narrow current-main fixes only; do not revive wholesale. |
| #983 | Draft | `UNKNOWN` | green | Park with document-stack PDF work. |
| #979 | Draft | `UNKNOWN` | green | Observe-only; never auto-close. |
| #976 | Draft | `UNKNOWN` | green | Park behind repair-chain redesign. |
| #974 | Draft | `UNKNOWN` | green | Park as document-stack base until manually replaced or rebased. |
| #963 | Draft | `UNKNOWN` | no checks | Park localization conflicts. |
| #958 | Draft | `UNKNOWN` | red | Park pending security/design review. |
| #955 | Draft | `UNKNOWN` | green | Observe; capability snapshot may relate to B after current bugs. |
| #942 | Draft | `UNKNOWN` | green | Park with document-stack structured attachments. |
| #941 | Draft | `UNKNOWN` | green | Park with document-stack format base. |
| #940 | Draft | `UNKNOWN` | green | Park with document-stack PDF extraction. |
| #939 | Draft | `UNKNOWN` | green | Park with document-stack CSV/TSV adapter. |
| #937 | Draft | `UNKNOWN` | green | Park with document-stack workbook tools. |
| #936 | Draft | `UNKNOWN` | green | Park with document-stack XLSX write. |
| #929 | Draft | `UNKNOWN` | green | Park with document-stack XLSX read. |
| #913 | Open | `UNKNOWN` | no checks | Exploratory Windows/Helios work; needs design split before automation. |
| #873 | Open | `UNKNOWN` | green | Localization coverage; no automatic rebase/nudge. |

## Open Bug Reports - 2026-05-16 07:33 UTC

| Issue | Bucket | Plan |
| ---: | --- | --- |
| #995 | Tool/runtime diagnostics | Lane B: add evidence for whether tools are indexed, selected, and sent to providers. |
| #903 | System prompts | Reproduce after B/C; #992 may contain useful but stale context. |
| #828 | Provider compatibility | Lane C: MiniMax/OpenAI-compatible connection fallback. |
| #823 | Tool availability | Lane B: granted tools must surface through capability search and prompt assembly. |
| #789 | Search tool discovery | Lane B: search tool recall and diagnostics. |
| #689 | Voice/transcription | Lane H after higher-priority API/tool/provider bugs. |
| #662 | OpenAI-compatible request format | Reproduce after C; likely API compatibility guardrail. |
| #647 | Gemini/provider results | #1088 landed but issue remains open; wait for retest or add verifier evidence. |
| #615 | Local OpenAI-compatible provider | Lane C: direct endpoint/model config without `/models` dependency. |
| #416 | MCP stdio docs/support | Lane E docs now; code lane only if docs uncover real runtime breakage. |

## Open Feature Requests - 2026-05-16 07:33 UTC

| Issue | Bucket | Plan |
| ---: | --- | --- |
| #1091 | Global proxy | Lane F after B/C; design shared network policy first. |
| #1069 | FIM | API compatibility feature after provider/tool regressions. |
| #1065 | DFlash model | Lane I research; avoid speculative runtime changes. |
| #1002 | TTS language | Lane H small feature candidate. |
| #886 | Longcat model support | Lane I research. |
| #869 | Access keys | Product/security design lane. |
| #833 | Tensor parallelism | Large runtime design lane. |
| #793 | Plugin browser | Product/plugin feature lane after current stabilization. |
| #654 | Agent/team defaults | Product lane after ordering and agent database work settles. |
| #642 | Local access token | Security/product decision before code. |
| #605 | Voice hotkey | Lane H small feature candidate. |
| #587 | Local MCP server | Future MCP capability lane; separate from Lane E docs. |
| #546 | Multi-agent API | Large agent API lane; design first. |
| #445 | Global voice input | Lane H after transcription reliability. |
| #443 | Local HF cache | Lane I model/download compatibility. |
| #430 | Folders/spaces | Product organization lane. |
| #417 | Speech output | Lane H voice conversation work. |
| #358 | Hunyuan model type | Lane I model compatibility. |
| #332 | Auto screenshot | Product/tooling feature lane. |
| #232 | HTTP/SOCKS proxy | Covered by Lane F with #1091. |
| #22 | Benchmarks | Evaluation/release-quality lane after D stabilizes eval CLI. |

## Complete Open Issue Inventory - 2026-05-16 07:33 UTC

| Issue | Labels | Title |
| ---: | --- | --- |
| #1091 | enhancement | Add global HTTP/SOCKS5 proxy support (for all network access) |
| #1069 | enhancement | FIM request support |
| #1065 | enhancement | Adapted with DFlash model (lightweight block diffusion model designed for speculative decoding) |
| #1050 |  | CapabilitySearch eval CLI hangs after build on current main |
| #1002 | enhancement | Add support for languages other than English in TTS |
| #995 | bug | Is this Program working for anyboday? |
| #903 | bug | System prompts not injected at runtime |
| #886 | enhancement | support for longcat-next? or longcat-flash-omni? |
| #869 | enhancement | Support for Custom Access Keys and UI Cleanup for Revoked Keys |
| #833 | enhancement | Tensor Parallelism |
| #828 | bug | Minimax 2.7 Not Connecting |
| #823 | bug | I cant use tools, and I've granted all permissions |
| #793 | enhancement | Community Plugin Browser |
| #789 | bug | Osaurus Search tool never seem to be found by any model |
| #689 | bug | Transcription mode is very unreliable |
| #662 | bug | Invalid request format |
| #654 | enhancement | Default Agent Configuration and Agent Team Functions |
| #647 | bug | no results whatsoever |
| #642 | enhancement | Can local access without an access token？ |
| #615 | bug | trying to connect to local lemonade / OpenAI compat server |
| #605 | enhancement, good first issue | Ability to make function key hot key for voice transcription |
| #587 | enhancement | Add support for local MCP Server |
| #546 | enhancement | Multi-agent support/access through the API |
| #445 | enhancement | Voice mode input from everywhere |
| #443 | enhancement | Support pre-downloaded Hugging Face models from local cache folder |
| #430 | enhancement | Folders and Spaces |
| #417 | enhancement | Add Speech Output for full voice conversations |
| #416 | bug | Command-based MCP providers (stdio) do not work despite documentation |
| #358 | enhancement | Unsupported model type: hunyuan_v1_dense |
| #332 | enhancement | auto screenshot feature |
| #232 | enhancement, good first issue | HTTP/Socks5 proxy support for downloading models and accessing online providers |
| #22 | enhancement | Benchmarks for current models, more sizes |

Snapshot update: 2026-05-15 08:02 UTC, repo `osaurus-ai/osaurus`.

This section is the current consolidated automation plan. It supersedes every
older dated section below; keep the older sections only as history.

## Current Live State - 2026-05-15 08:02 UTC

- `origin/main` is `973b8fa797e94f59aab30ef23424e67e6ea7efde`
  (`[codex] Move theme image picker into Appearance (#1099)`).
- Latest main remote gates are green on `973b8fa7`:
  - CI `25904487544`: `success`.
  - Release Drafter `25904487513`: `success`.
  - pages `25904486956`: `success`.
- The exact-main local release gate passed in
  `/private/tmp/osaurus-coord/worktrees/main-973b8fa7` with log output at
  `/private/tmp/osaurus-coord/evidence/builds/main-973b8fa7.log`.
  No new `origin/main` SHA appeared during this refresh, so the prior successful
  exact-SHA local gate remains the active dispatch evidence for invariant I3.
- Open PRs evaluated: 29.
- Open issues evaluated: 32.
- No upstream queue counts changed since the `2026-05-15 07:08 UTC` snapshot.
- Recently touched lane state remains:
  - Issue #1092 is still closed at `2026-05-15T06:10:11Z`; `origin/main`
    includes `reorder agents (#1102)`.
  - Issue #1093 is still closed at `2026-05-15T06:45:22Z`; `origin/main`
    includes `Move theme image picker into Appearance (#1099)`.
  - Issue #1094 remains closed as of `2026-05-15T04:09:24Z`, and #1096 stays
    the landed save-without-apply fix on main.
  - Issue #1090 remains closed as of `2026-05-15T04:14:32Z`, but PR #1101
    remains open on head `e7ec10df` with green checks and `DIRTY` merge state
    against current main, so it is still a rebase/conflict lane rather than a
    review lane.
  - PR #1098 remains closed by maintainer action on head `e6fb329d`; do not
    auto-reopen the parked theme-refresh worktree without a new current-main
    rebase and a narrowed remaining scope.

## Nudge Decision - 2026-05-15 08:02 UTC

No GitHub nudge was posted in this refresh.

Reasons:

- No PR changed into a new reviewable state during this refresh.
- PR #1101 is still green on its own head SHA, but it remains `DIRTY` against
  current main, which keeps it out of the review-ladder path and in the
  conflict/rebase bucket.
- The landed #1099 / #1102 work and the closed #1093 / #1092 issues still
  require no reviewer follow-up.
- The previously closed #1098 theme PR remains closed by maintainer action; do
  not auto-reopen or re-nudge it.

## Immediate Execution Order

1. Treat `973b8fa7` as the new verified dispatch base for downstream work.
2. Treat Lane A as effectively drained on upstream main: #1093/#1094 are closed
   and the remaining detached theme-refresh patch should stay parked until a new
   current-main-safe issue is identified.
3. Reclassify Lane G reorder work as landed for #1092, and treat PR #1101 as a
   separate conflict/rebase candidate for the closed-#1090 follow-on rather
   than an active nudge target.
4. Shift the next dispatch focus to still-open issues with clean scope
   boundaries: Lane F (#1091/#232) first, then Lane B (#823/#789/#995), then
   Lane C (#615/#828/#1059).

Snapshot update: 2026-05-15 04:05 UTC, repo `osaurus-ai/osaurus`.

This section is the current consolidated automation plan. It supersedes every
older dated section below; keep the older sections only as history.

## Current Live State - 2026-05-15 04:05 UTC

- `origin/main` is `e14de28d8e65c94ae7e4ca6a043864126660d9ee`
  (`improved theme edit sync in chat` via #1095).
- Issue #1089 is closed as of `2026-05-15T03:24:58Z`, so the theme-editor bug
  cluster is now narrowed to #1093 and #1094.
- PR #1098 (`Fix theme editor save behavior`) was opened from
  `mimeding:codex/theme-editor-save-image-1093-1094` and then closed by
  `RaajeevChandran` at `2026-05-15T04:08:18Z` with state reason `COMPLETED`
  (not merged).
- The active detached theme worktree is
  `/tmp/osaurus-coord/worktrees/theme-editor-save-image-1093-1094` on commit
  `e6fb329d`. This run added one more guard there:
  - `ThemeManager.saveTheme(_:)` now posts `.globalThemeChanged` when saving a
    non-active custom theme, so open chat windows pinned to that theme refresh.
  - `ChatWindowStateAgentSyncTests` now includes a regression test that saves a
    non-active custom theme and asserts the open window updates.
- Focused validation passed on that detached branch:
  `swift test --package-path Packages/OsaurusCore --filter ChatWindowStateAgentSyncTests`
  completed cleanly with 11 tests passing after a cold SwiftPM build.

## Nudge Decision - 2026-05-15 04:05 UTC

No GitHub nudge was posted in this refresh.

Reasons:

- #1089 already moved to closed, so there is no reviewer or maintainer action
  to request there.
- #1093 and #1094 briefly had implementation PR #1098, but it was closed by a
  maintainer without merge. Do not auto-reopen; treat the closure reason as the
  next thing to clarify before creating another theme PR.
- No other non-draft, mergeable, green PR changed state during this run.

## Immediate Execution Order

1. Record that PR #1098 was closed by a maintainer as `COMPLETED` without a
   merge, and do not auto-reopen it.
2. Keep the older `theme-editor-live-save-1089` detached worktree as stale
   history only; do not rebase or push it unless the newer lane proves
   insufficient.

Snapshot update: 2026-05-15 00:50 UTC, repo `osaurus-ai/osaurus`.

This section is the current consolidated automation plan. It supersedes every
older dated section below; keep the older sections only as history.

## Current Live State - 2026-05-15 00:50 UTC

- `origin/main` is `f525a9460af03849a59d7f01fd3018c7a80773f5`.
  It includes #1088 (`Fix Gemini tool schema parameters`) and follows the
  0.18.18 appcast update.
- Latest main remote gates are green on `f525a946`:
  - CI `25884917206`: `success`.
  - Release Drafter `25884917217`: `success`.
  - pages `25884916149`: `success`.
- Current-main local release build passed on the same SHA in
  `/private/tmp/osaurus-coord/worktrees/main-f525a946` using
  `swift build --package-path Packages/OsaurusCore -c release`.
  Duration was 411.41s with existing warnings only.
- Open PRs evaluated: 28.
- Open issues evaluated: 37.
- #1088 is merged and #647 remains open because #1088 used `Refs #647`, not
  `Fixes #647`. Treat #647 as pending reporter/maintainer confirmation, not
  as automatically closeable.
- New bug cluster after 0.18.18: #1089, #1093, and #1094 are theme-editor
  regressions. These are now the highest-value small code lane.

## Nudge Decision - 2026-05-15

No GitHub nudge was posted in this refresh.

Reasons:

- #1088 was approved by `@tpae` and merged, so no review/merge nudge is needed.
- #1048 was already nudged on 2026-05-10 and is now broadly conflicted; another
  nudge would be duplicate noise.
- #647 needs release/retest confirmation after #1088, but the next useful move
  is verifier evidence or a reporter retest request once a build containing
  `f525a946` is available.
- Fresh issues #1089/#1093/#1094 are actionable without a maintainer decision.

Future nudge rules:

1. Nudge only when a PR is non-draft, mergeable, green on its exact head SHA,
   has local evidence where applicable, and has no recent equivalent comment.
2. For conflicted external PRs, nudge only after fresh conflict proof identifies
   a focused maintainer/author action.
3. For issue closure, never close automatically. Ask for reporter/maintainer
   confirmation when a fix has landed but the issue intentionally remains open.

## Maximum Parallelization Plan

These lanes are intentionally disjoint. Each branch must start from current
build-clean `origin/main`, verify no duplicate PR exists, and acquire a
GitHub/origin mutation lock before push or PR creation.

| Lane | Issues/PRs | Status | Write scope | Validation | Next action |
| --- | --- | --- | --- | --- | --- |
| A. Theme editor correctness | #1089, #1093, #1094; follow-on #1090 | Ready now | `Packages/OsaurusCore/Views/Theme/*`, `Models/Theme/*`, focused theme tests | Theme manager/unit tests, focused UI state tests, release build | Create narrow branch fixing live application of saved theme changes, image picker placement, and save-without-apply behavior. |
| B. Tool exposure matrix | #823, #789, #995 | Worker A was in progress from older main; not integration-ready | `Tools/*`, `Services/Tool/*`, `Services/Chat/*`, diagnostics only | Tool registry/search/prompt/provider request tests | Restart or finish from current main; do not integrate the stale partial worker patch until rebased and validated. |
| C. Provider compatibility | #615, #828, #1059 | Worker B lane exists but stale base | `Services/Provider/*`, `Managers/RemoteProviderManager.swift`, provider settings tests | Remote request/model discovery tests, release build | Extract a current-main branch for OpenAI-compatible providers without `/models`, direct model IDs, and MiniMax fallback. |
| D. CapabilitySearch eval hang | #1050 | Worker C lane exists but stale base | Eval CLI/tests only | Eval CLI test with and without `CI=true` | Add noninteractive default/timeout behavior and document the CI workaround as a fallback. |
| E. MCP stdio docs mismatch | #416, #1058 | Worker D docs branch exists and passed `git diff --check` | `README.md`, `docs/REMOTE_MCP_PROVIDERS.md`, `docs/FEATURES.md` | `git diff --check`; docs review | Publish a docs-only PR after review, or fold into #1058 only if no duplicate PR is created. |
| F. Global proxy support | #1091, #232 | New feature lane; medium risk | network session factory/config, settings UI, model download/provider/plugin HTTP call sites | Unit tests for proxy config, provider/model-download smoke tests | Design first, then implement a shared URLSession/proxy policy. Keep separate from provider fallback to avoid network-layer merge conflicts. |
| G. Agent ordering/product UX | #1092, #654, #430, #546 | Feature lane; lower priority than bugs | `Views/Agent/*`, `Managers/AgentManager.swift`, agent store migration | Agent ordering persistence tests, UI state tests | Start with reorder persistence and dropdown ordering; avoid multi-agent API scope until a separate design is accepted. |
| H. Voice/TTS/transcription | #689, #1002, #417, #445, #605 | Feature/quality lane | `Views/Voice/*`, audio/TTS/transcription services | Voice settings/unit tests, manual audio smoke | Pick one small target first: non-English TTS language setting or function-key hotkey. |
| I. Model/download compatibility | #443, #358, #1065, #886, #833 | Research/design lane | model discovery/download/runtime adapters | Model manager tests, compatibility notes | Produce design notes before code; these overlap with runtime and download behavior. |
| J. Document stack | #929/#936/#937/#939/#940/#941/#942/#983/#1022/#1023/#1024 and #974 | Blocked | document/plugin stack | Full document-stack sequencing gates | Do not dispatch until #974 is manually resolved or replaced by a fresh current-main base. |
| K. Historical conflicted PRs | #873, #963, #1048, #958, #955, #976, #985/#986/#987/#988/#979/#992 | Blocked or observe-only | varies | conflict proof first | Skip unless branch changes or maintainer explicitly asks for manual conflict resolution. |

## Immediate Execution Order

1. Keep current main as dispatchable only while remote CI and local release
   build remain green on the same SHA.
2. Start Lane A, the theme-editor bug cluster, as the top branch candidate.
   It is fresh, user-visible, and isolated from the ongoing tool/provider lanes.
3. Rebase/restart Lane B from current main after Lane A is underway or if a
   separate worker owns it. Do not use stale worker output without validation.
4. Run Lane C in parallel with Lane B only if write scopes stay provider-only.
5. Keep Lane D and Lane E as small fallback branches when larger code lanes are
   blocked or waiting for review.
6. Treat #1091/#232 as a separate design-plus-implementation lane because a
   global proxy touches many network call sites.
7. Leave document-stack and conflicted historical branches parked until their
   blockers change.

## Open PR Plan - 2026-05-15 00:50 UTC

| PR | State | Bucket | Plan |
| ---: | --- | --- | --- |
| #873 | Open, `DIRTY` | Community localization | Blocked by non-mechanical localization/UI conflicts; do not retry automatically. |
| #913 | Open, `BEHIND` | Windows/Helios exploratory | No-check/large exploratory PR; needs split/design review before automation work. |
| #929 | Draft, `DIRTY` | Document stack | Park until document-stack base is rebuilt from current main. |
| #936 | Draft, `DIRTY` | Document stack | Park behind document-stack sequencing. |
| #937 | Draft, `DIRTY` | Document stack | Park; prior note says workbook work moved to plugin scope. |
| #939 | Draft, `DIRTY` | Document stack | Park until shared format base is available. |
| #940 | Draft, `DIRTY` | Document stack | Park until shared format base is available. |
| #941 | Draft, `DIRTY` | Document stack base | Park behind #974 or a fresh replacement base. |
| #942 | Draft, `DIRTY` | Document stack | Park behind lower document-stack PRs. |
| #955 | Draft, `DIRTY` | Support/quality | Park until stabilization lanes settle. |
| #958 | Draft, `DIRTY` | External HPKE | Needs security/design acknowledgement and owner conflict resolution. |
| #963 | Draft, `DIRTY` | Community localization | Blocked by CLI localization conflicts; do not retry automatically. |
| #974 | Draft, `DIRTY` | Document stack base | Blocked by prompt/capability conflicts and docs modify/delete conflict. |
| #976 | Draft, `DIRTY` | Repair chain | Park behind current bug lanes and repair-chain redesign. |
| #979 | Draft, `DIRTY` | Superseded repair | Observe-only closure-review candidate; never close automatically. |
| #983 | Draft, `DIRTY` | Document/PDF stack | Park until lower document-stack PRs land. |
| #985 | Draft, `DIRTY` | Open bug repair | Do not revive wholesale; extract narrow current-main fixes only. |
| #986 | Draft, `DIRTY` | Workflow docs | Park or mine for docs after ordering stabilizes. |
| #987 | Draft, `DIRTY` | API guardrails | Park until provider/API fixes settle. |
| #988 | Draft, `DIRTY` | Eval smoke suite | Park until eval and repair-chain base are stable. |
| #992 | Draft, `DIRTY` | Superseded repair | Observe-only closure-review candidate; never close automatically. |
| #1006 | Open, `BEHIND` | Packaging | Needs fresh current-main rebase proof before another maintainer ask; automation cannot push upstream branch. |
| #1022 | Draft, `BEHIND` | Document stack | Still sequenced behind document-stack base despite mergeable-adjacent status. |
| #1023 | Draft, `BEHIND` | Document stack | Same as #1022. |
| #1024 | Draft, `DIRTY` | Document docs | Docs-only; rebase after document stack blockers clear. |
| #1048 | Open, `DIRTY` | A0 local CI parity | Already nudged; blocked by broad first-commit conflicts. |
| #1058 | Draft, `DIRTY` | MCP docs | Replace or supersede with Worker D docs-only branch after review. |
| #1059 | Draft, `DIRTY` | Provider compatibility | Mine for provider fallback logic, but prefer a new current-main branch. |

## Open Issue Inventory - 2026-05-15 00:50 UTC

| Issue | Labels | Bucket | Plan |
| ---: | --- | --- | --- |
| #1094 | bug | Theme editor | Lane A: saving a theme must not make it default unless explicitly applied. |
| #1093 | bug | Theme editor | Lane A: move/show image picker next to image background mode. |
| #1092 | enhancement | Agents UX | Lane G: reorder agents and reflect order in picker. |
| #1091 | enhancement | Global proxy | Lane F: global HTTP/SOCKS5 proxy across network access; supersedes narrower #232 scope. |
| #1090 | enhancement | Theme/glass | Follow Lane A or separate theme enhancement after regressions are fixed. |
| #1089 | bug | Theme editor | Lane A: saved/current theme changes should update open windows immediately. |
| #1069 | enhancement | FIM | Medium API compatibility feature after provider/tool lanes. |
| #1065 | enhancement | DFlash model | Research/model-runtime lane. |
| #1050 | unlabeled reliability | Eval CLI | Lane D: avoid interactive hang or make CI mode automatic/documented. |
| #1002 | enhancement | TTS | Lane H: add non-English PocketTTS language selection. |
| #995 | bug | Tools/diagnostics | Lane B umbrella for tool exposure and raw request diagnostics. |
| #903 | bug | System prompts | Reproduce on current main after tool/provider work; avoid assuming #992 is valid. |
| #886 | enhancement | Model support | Research/model-runtime lane. |
| #869 | enhancement | Access keys | Product/security lane; not near-term. |
| #833 | enhancement | Tensor parallelism | Large runtime feature; design first. |
| #828 | bug | Provider compatibility | Lane C: provider without `/models`, direct endpoint/model config. |
| #823 | bug | Tool availability | Lane B: registry/search/prompt/provider matrix. |
| #793 | enhancement | Plugin browser | Product/plugin feature; medium priority. |
| #789 | bug | Search tool discovery | Lane B with #823/#995. |
| #689 | bug | Transcription | Lane H after API/tool/provider regressions. |
| #662 | bug | Responses shorthand | Reproduce on current main; possible narrow API compatibility test. |
| #654 | enhancement | Agent config/team | Lane G after reorder groundwork. |
| #647 | bug | Gemini/provider schema | #1088 merged; wait for retest/confirmation before closure. |
| #642 | enhancement | Local access token | Security/product decision needed before code. |
| #615 | bug | Local OpenAI-compatible provider | Lane C with #828/#1059. |
| #605 | enhancement, good first issue | Voice hotkey | Lane H small enhancement candidate. |
| #587 | enhancement | Local MCP stdio providers | Larger implementation counterpart to #416; do not mix with docs-only lane. |
| #546 | enhancement | Multi-agent API | Large product/API design lane. |
| #445 | enhancement | Voice mode input | Lane H; overlaps hotkey/VAD work. |
| #443 | enhancement | Local model cache | Lane I; model discovery/storage design. |
| #430 | enhancement | Folders/spaces | Product/UX roadmap, after agent ordering. |
| #417 | enhancement | Speech output | Lane H; broad voice conversation roadmap. |
| #416 | bug | MCP docs mismatch | Lane E docs-only fix or larger #587 implementation later. |
| #358 | enhancement | Hunyuan model type | Model compatibility research lane. |
| #332 | enhancement | Auto screenshot | Product/tooling roadmap; not immediate. |
| #232 | enhancement, good first issue | Proxy support | Fold into #1091 global proxy design. |
| #22 | enhancement | Benchmarks | Benchmark/eval roadmap; useful after stabilization. |

## Automation Contract For Future Runs

Every unsupervised tick should:

1. Fetch and snapshot live `origin/main`, open PRs, open issues, and latest main
   CI/release/pages runs.
2. If `origin/main` changed, require latest main CI success and rerun local
   `swift build --package-path Packages/OsaurusCore -c release` on that exact
   SHA before dispatching branch work.
3. Never merge, close, delete branches, mutate main, create duplicate PRs, or
   push without a lock under `/tmp/osaurus-coord/locks`.
4. Dispatch only one branch per lane and keep write scopes disjoint.
5. Prefer Lane A first, then Lane B/C in parallel if separate workers are
   available, then Lane D/E fallback branches.
6. Treat #979 and #992 as observe-only closure-review candidates.
7. Write a gate evaluation, lane work orders, reviewer summaries for open
   non-draft PRs, a refreshed plan artifact, and a final tick report.

---

Snapshot update: 2026-05-14 19:05 UTC, repo `osaurus-ai/osaurus`.

This update supersedes the 16:30 UTC section below. Live GitHub state is
authoritative; the older sections remain as history for why the queue moved.

## Current State - 2026-05-14 19:05 UTC

- `origin/main` advanced to `163aaa5e9b051427e134048bf328d5fe61d2531a`
  via #1087 (`added agent database feature`).
- Latest main GitHub runs for `163aaa5e9b051427e134048bf328d5fe61d2531a`
  are green:
  - CI `25878282180`: `success`.
  - Release Drafter `25878282182`: `success`.
  - pages `25878280411`: `success`.
- Current-main local release build passed on the same SHA in detached worktree
  `/private/tmp/osaurus-coord/worktrees/main-163aaa5e` using
  `swift build --package-path Packages/OsaurusCore -c release`.
- Open PRs evaluated: 29.
- Draft PRs: 24. Non-draft PRs: 5.
- Merge state distribution: 5 `MERGEABLE`, 24 `CONFLICTING`.
- #1088 is the only ready bug-fix PR in review: open, non-draft, mergeable,
  green on head `0289ebd9ec20bb1de777f3973950a7af69b9379d`, no comments or
  reviews. It addresses #647 and intentionally uses `Refs #647`, leaving issue
  closure to maintainer/user confirmation.
- #1087 has merged; remove it from open-PR watch and include it in the current
  main gate.

## Parallel Agent Dispatch - 2026-05-14

The orchestrator split work into four disjoint lanes. Agents must not push,
merge, close issues/PRs, delete branches, mutate GitHub/origin, or touch
`main`/`master`.

| Lane | Agent | Issues | Scope |
| --- | --- | --- | --- |
| Tool exposure matrix | Aristotle `019e27f1-b1f5-7a40-bcf3-7bd3efbbeb05` | #823/#789/#995 | Test-first proof that tools are registered, searchable, loaded, sent to providers, or diagnostically marked disabled. |
| Provider compatibility | Averroes `019e27f1-b3f5-7f60-a5c9-08c0fd2ee956` | #615/#828/#1059 | OpenAI-compatible local server/model discovery fallback; avoid conflicts with pending #1088 Gemini schema work. |
| CapabilitySearch eval hang | Mill `019e27f1-b608-7060-8fcb-e25c00f70faf` | #1050 | Small reliability fix for eval CLI hang/noninteractive behavior. |
| MCP stdio docs mismatch | Franklin `019e27f1-b822-7133-80a9-735a9e140227` | #416/#1058 | Docs-only correction for remote MCP transport support; do not attempt larger #587 implementation. |

## Updated Execution Order

1. Treat current main as build-clean on `163aaa5e`.
   Main CI, Release Drafter, pages, and the local release build all passed on
   the current main SHA.
2. Watch #1088.
   If it receives feedback or CI reruns fail, patch the same branch under a
   fresh lock. If it merges, refresh main CI, rerun the local release build, and
   refresh verifier evidence for #647/#823/#789/#995/#903/#662/#689.
3. Integrate or triage parallel-agent results.
   Prefer a narrow #823/#789/#995 tool-exposure branch if the local main gate is
   clean and #1088 remains stable. Keep write scopes disjoint and create only
   one PR per lane.
4. Use provider compatibility as the next code lane.
   #615/#828/#1059 should focus on local OpenAI-compatible servers that lack
   `/models` or need direct endpoint configuration.
5. Keep low-risk reliability/docs lanes ready.
   #1050 and #416/#1058 are good small follow-ups if the larger code lanes are
   blocked or conflict with #1088.
6. Keep blocked historical branches skipped unless live branch state changes or
   a maintainer asks for manual conflict resolution.

## Open PR Plan - 2026-05-14 19:05 UTC

| PR | Bucket | Live state | Plan |
| ---: | --- | --- | --- |
| #873 | Community localization | Open, `CONFLICTING` | Still blocked by non-mechanical localization/UI conflicts. Do not retry automatically. |
| #913 | Windows/Helios exploratory | Open, `MERGEABLE` | Needs design review and package-specific build plan before merge work. |
| #929 | Document stack | Draft, `CONFLICTING` | Park until #974 base lands and format base SHA is published. |
| #936 | Document stack | Draft, `CONFLICTING` | Park until #929 lands; then rebase and gate. |
| #937 | Document stack | Draft, `CONFLICTING` | Park until #936 lands; then rebase and gate. |
| #939 | Document stack | Draft, `CONFLICTING` | Park until #974 base lands and format base SHA is published. |
| #940 | Document stack | Draft, `CONFLICTING` | Park until #974 base lands and format base SHA is published. |
| #941 | Document stack base | Draft, `CONFLICTING` | Run first after #974 if shared format base SHA is absent. |
| #942 | Document stack | Draft, `CONFLICTING` | Depends on #929/#939/#940/#941/#937. |
| #955 | Support/quality | Draft, `CONFLICTING` | Park until Phase 3/4 and main build remain stable. |
| #958 | External HPKE | Draft, `CONFLICTING` | Needs explicit security ack and owner conflict resolution before branch work. |
| #963 | Community localization | Draft, `CONFLICTING` | Blocked by CLI localization conflicts; do not retry automatically. |
| #974 | Document stack base | Draft, `CONFLICTING` | Document-stack gate remains blocked by prompt/capability discovery conflicts plus `docs/PLUGIN_AUTHORING.md` modify/delete. |
| #976 | Repair chain | Draft, `CONFLICTING` | Park behind #985/#979/#992 redesign and current bug-fix priorities. |
| #979 | Superseded repair | Draft, `CONFLICTING` | Closure-review candidate only; never close automatically. |
| #983 | Document/PDF stack | Draft, `CONFLICTING` | Rebase after lower document-stack PRs land. |
| #985 | Build/readiness repair | Draft, `CONFLICTING` | Re-evaluate after #1088/main refresh; keep scoped to stabilization and open bugs. |
| #986 | Docs/workflow | Draft, `CONFLICTING` | Park until ordering is stable; useful as workflow docs if rebased. |
| #987 | API compatibility guardrail | Draft, `CONFLICTING` | Park until provider/API fixes settle. |
| #988 | Eval smoke suite | Draft, `CONFLICTING` | Park until #985/#986 dependencies are stable. |
| #992 | Superseded repair | Draft, `CONFLICTING` | Closure-review candidate only; never close automatically. |
| #1006 | Packaging | Open, `MERGEABLE` | Recheck only after local current-main build is green; prior blocker was upstream branch write permission and duplicate PR prohibition. |
| #1022 | Document stack | Draft, `MERGEABLE` | Still parked behind document-stack sequencing despite mergeable state. |
| #1023 | Document stack | Draft, `MERGEABLE` | Still parked behind document-stack sequencing despite mergeable state. |
| #1024 | Document docs | Draft, `CONFLICTING` | Docs-only; rebase after #1022/#1023 and shared blockers clear. |
| #1048 | A0 local CI parity | Open, `CONFLICTING` | Already nudged; blocked by broad first-commit conflicts. Do not retry automatically. |
| #1058 | MCP docs | Draft, `CONFLICTING` | Parallel docs lane is active; keep implementation/docs limited to confirmed transport mismatch. |
| #1059 | Provider compatibility | Draft, `CONFLICTING` | Parallel provider lane is active; prefer extracting a narrow current-main branch over reviving conflicted draft wholesale. |
| #1088 | Gemini tool schema | Open, `MERGEABLE`, green | Ready for maintainer review/merge; no new nudge yet. Patch only if feedback or CI drift appears. |

## Open Bugs and Fix Candidates - 2026-05-14 19:05 UTC

| Issue | Area | Current signal | Plan |
| ---: | --- | --- | --- |
| #647 | Gemini/Google Cloud tool schema | #1088 ready and green | Watch #1088; after merge, refresh main and verifier evidence. |
| #823 | Tool availability | Updated 2026-05-14; user still cannot use tools reliably | Active parallel lane: registry/search/load/provider/diagnostics matrix. |
| #789 | Search tool discoverability | Cross-linked to #823 | Treat as tool-discovery family with #823/#995. |
| #995 | Broad "is it working" report | Umbrella symptom report | Use as umbrella for tool/provider failures; avoid vague closure. |
| #615 | Local OpenAI-compatible server | Likely provider discovery/config issue | Active parallel lane with #828/#1059. |
| #828 | Minimax endpoint compatibility | `/models` absence/direct endpoint support | Active parallel lane with #615/#1059. |
| #1050 | CapabilitySearch eval hang | Needs noninteractive/default timeout behavior | Active parallel lane; good small reliability fix. |
| #416 | Stdio MCP docs mismatch | Docs imply unsupported command-based remote providers work | Active parallel docs lane with #1058. |
| #662 | Responses shorthand input | Linked to old dirty #985 | Reproduce on current main after active lanes report. |
| #903 | System prompts runtime | Linked to superseded #992 class | Reproduce on current main before branch work. |
| #689 | Transcription reliability | DSP/noise-gate discussion exists | Medium priority after API/tool/provider regressions. |

## Feature Requests We Can Work On Next

| Issue | Feature | Size | Plan |
| ---: | --- | --- | --- |
| #232 | HTTP/SOCKS5 proxy support | Small/medium, `good first issue` | Good isolated enhancement after bug lanes. |
| #443 | Pre-downloaded Hugging Face local cache | Medium | Good follow-up to model/download stability. |
| #605 | Function-key hotkey for voice transcription | Small/medium, `good first issue` | Needs macOS input-event design. |
| #1069 | FIM request support | Medium | API compatibility candidate after provider fixes. |
| #1002 | Non-English TTS support | Medium | Voice roadmap candidate after transcription reliability. |
| #587 | Local MCP server support | Medium/large | Implementation counterpart to #416/#1058; not part of current docs-only lane. |

## Automation Changes Needed

Each heartbeat should now:

1. Refresh main, #1088, open PRs, open issues, and main runs.
2. If `origin/main` advances, require latest main CI success and a local
   release build on the exact same SHA before branch dispatch.
3. Keep #1088 in review watch; do not post another nudge unless new evidence or
   a focused maintainer decision appears.
4. Integrate parallel-agent results into one narrow branch per lane, avoiding
   duplicate PRs and respecting locks.
5. Keep #1048/#873/#963/#974 skipped unless live branch state changes or a
   maintainer asks for conflict resolution.
6. Treat #979 and #992 as observe-only closure-review candidates; never close
   automatically.

---

Snapshot update: 2026-05-14 16:30 UTC, repo `osaurus-ai/osaurus`.

This update supersedes the 2026-05-13 queue state below while preserving it as
history. Live GitHub state is authoritative; older notes are useful only for
why the queue moved.

## Current State - 2026-05-14 16:30 UTC

- Open PRs evaluated: 29.
- Draft PRs: 24. Non-draft PRs: 5.
- Merge state distribution: 24 `DIRTY`, 4 `BEHIND`, 1 `CLEAN`.
- PRs with no check rollup: #913, #963.
- PRs with red or mixed historical check rollups: #958, #1022, #1023, #1024.
- Latest `origin/main`: `501d40350a252e5ae40cf51c1cc83aa3d6ba12b2`.
- Latest main GitHub run: CI `25853923524`, completed `success`.
- Current-main local release build evidence is green on the same SHA:
  `/tmp/osaurus-coord/verifier-evidence/main-release-build-501d4035.log`.
- Open issues evaluated: 32 total, including 11 `bug`, 20 `enhancement`, and
  2 `good first issue` labels. #1050 is an unlabeled reliability bug candidate.

## Maintainer Nudge Decision - 2026-05-14

Posted one maintainer nudge, and only one:

- #1086: posted `@tpae` review/merge nudge because the PR is non-draft,
  `CLEAN`, fixes fresh bug #1085, and local plus remote gates passed on the
  exact same head SHA `df183c2b785960050e729d0e991fc2952599a147`.
  Comment: https://github.com/osaurus-ai/osaurus/pull/1086#issuecomment-4452597924

Do not post another #1048 nudge now. #1048 was already nudged on
2026-05-10 and is currently `DIRTY` with broad non-mechanical conflicts.

Do not nudge #1006 yet. The prior automation proved a clean local rebase only
against an older main, and the blocker is upstream branch write permission. Ask
for maintainer branch refresh only after #1086 lands or after a fresh rebase
proof against current main is available.

## Updated Execution Order

1. Land #1086 or get maintainer feedback.
   #1086 is the only clean, ready, remote-green PR and fixes #1085. Automation
   must not merge it, but it should watch for review feedback or CI reruns. If
   feedback appears, patch the same branch under a fresh GitHub/origin mutation
   lock.
2. Refresh main after #1086 merges.
   Once #1086 lands, confirm `origin/main` advanced, wait for latest main CI,
   rerun `swift build --package-path Packages/OsaurusCore -c release`, and
   refresh #1085/#995/#823/#789/#647/#903/#662/#689 verifier notes.
3. Use bug work as the next productive path if PR review stalls.
   Top local reproduction/fix candidates are #647, #823/#789/#995, #615/#828,
   #416/#1058, and #1050. These are better uses of time than retrying branches
   already known to have non-mechanical conflicts.
4. Resume blocked branch work only with new evidence or maintainer action.
   Skip #1048/#1006/#873/#963/#974 unless the branch changes, the maintainer
   asks for a manual rebase/conflict pass, or a fresh current-main re-evaluation
   changes the blocker.
5. Keep document stack sequencing blocked behind #974.
   After #974 is manually resolved and merged, resume with #941, publish
   `/tmp/osaurus-coord/state/format-plugin-base-sha`, then #929/#939/#940,
   followed by #936, #937, #942, #983, #1022/#1023, and #1024.

## Open PR Plan - 2026-05-14 16:30 UTC

| PR | Bucket | Live state | Plan |
| ---: | --- | --- | --- |
| #873 | Community localization | Open, `DIRTY`, green checks | Still blocked by non-mechanical localization/UI conflicts. Do not duplicate the prior owner/maintainer conflict-resolution note. |
| #913 | Windows/Helios exploratory | Open, `BEHIND`, no checks | Needs design review and package-specific build plan before merge work. |
| #929 | Document stack | Draft, `DIRTY`, green checks | Park until #974 base lands and format base SHA is published. |
| #936 | Document stack | Draft, `DIRTY`, green checks | Park until #929 lands; then rebase and gate. |
| #937 | Document stack | Draft, `DIRTY`, green checks | Park until #936 lands; then rebase and gate. |
| #939 | Document stack | Draft, `DIRTY`, green checks | Park until #974 base lands and format base SHA is published. |
| #940 | Document stack | Draft, `DIRTY`, green checks | Park until #974 base lands and format base SHA is published. |
| #941 | Document stack base | Draft, `DIRTY`, green checks | Run first after #974 if shared format base SHA is absent. |
| #942 | Document stack | Draft, `DIRTY`, green checks | Depends on #929/#939/#940/#941/#937. |
| #955 | Support/quality | Draft, `DIRTY`, green checks | Park until Phase 3/4 and main build remain stable. |
| #958 | External HPKE | Draft, `DIRTY`, mixed `test-core` history | Needs explicit security ack and owner conflict resolution before branch work. |
| #963 | Community localization | Draft, `DIRTY`, no checks | Blocked by CLI localization conflicts; do not retry automatically. |
| #974 | Document stack base | Draft, `DIRTY`, green checks | Document-stack gate is blocked here by prompt/capability discovery conflicts plus `docs/PLUGIN_AUTHORING.md` modify/delete. |
| #976 | Repair chain | Draft, `DIRTY`, green checks | Park behind #985/#979/#992 redesign and current bug-fix priorities. |
| #979 | Superseded repair | Draft, `DIRTY`, green checks | Closure-review candidate only; never close automatically. |
| #983 | Document/PDF stack | Draft, `DIRTY`, green checks | Rebase after lower document-stack PRs land. |
| #985 | Build/readiness repair | Draft, `DIRTY`, green checks | Re-evaluate after #1086/main refresh; keep scoped to stabilization and open bugs. |
| #986 | Docs/workflow | Draft, `DIRTY`, green checks plus `pr-clean-gate` | Park until ordering is stable; useful as workflow docs if rebased. |
| #987 | API compatibility guardrail | Draft, `DIRTY`, green checks | Park until provider/API fixes settle. |
| #988 | Eval smoke suite | Draft, `DIRTY`, green checks | Park until #985/#986 dependencies are stable. |
| #992 | Superseded repair | Draft, `DIRTY`, green checks | Closure-review candidate only; never close automatically. |
| #1006 | Packaging | Open, `BEHIND`, green checks | Prior local rebase was clean on older main but could not be pushed to upstream branch. Recheck only after #1086 or maintainer branch action. |
| #1022 | Document stack | Draft, `BEHIND`, red `test-core` | Rebase after #983; rerun once shared stack blockers clear. |
| #1023 | Document stack | Draft, `BEHIND`, red `test-core` | Rebase after #983; rerun once shared stack blockers clear. |
| #1024 | Document docs | Draft, `DIRTY`, red `test-core` | Docs-only; rebase after #1022/#1023 and shared blockers clear. |
| #1048 | A0 local CI parity | Open, `DIRTY`, green checks | Already nudged; blocked by broad first-commit conflicts. Do not retry automatically. |
| #1058 | MCP docs | Draft, `DIRTY`, green checks | Canonical path for #416 docs/transport mismatch once rebased. |
| #1059 | Provider compatibility | Draft, `DIRTY`, green checks | Candidate base for #615/#828 provider discovery fallback work. |
| #1086 | `/api/chat` tool-call bug | Open, `CLEAN`, green checks | Ready for maintainer review/merge; nudge posted. Do not merge automatically. |

## Open Bugs and Fix Candidates

| Issue | Area | Current signal | Plan |
| ---: | --- | --- | --- |
| #1085 | API compatibility | Fresh bug; #1086 is ready and green | Wait for #1086 review/merge, then refresh main and close-loop verification. |
| #647 | Chat/model request failures | Reporter added concrete Gemma4 Google Cloud HTTP 400 repro on 2026-05-12 | Next high-value local reproduction: capture request body/provider params and compare against cloud schema. |
| #823 | Tool availability | Long thread, updated 2026-05-14; user still cannot use tools reliably | Fold into a focused tool-exposure matrix with #789/#995; verify actual tool schemas exposed to Foundation, local MLX, and remote models. |
| #789 | Search tool discoverability | Older report cross-linked to #823 | Treat as same tool-discovery family; close only with current-main reproduction evidence. |
| #995 | Broad "is it working" report | Umbrella symptom report | Use as umbrella for #647/#823 provider/tool failures; avoid vague closure until concrete paths are verified. |
| #662 | Responses shorthand input | Linked to dirty #985 | Re-evaluate #985 or extract a narrow fix/test if still failing on current main. |
| #903 | System prompts runtime | Linked to #992, but #992 is now closure-review/superseded class | Reproduce on current main before spending branch time; do not assume #992 is still the right vehicle. |
| #615 | Local OpenAI-compatible server | No comments; likely provider discovery/config issue | Pair with #828 and #1059; implement fallback/manual model config if `/models` is absent. |
| #828 | Minimax endpoint compatibility | Maintainer acknowledged `/models` absence; user wants direct endpoint support | Same workstream as #615/#1059; good candidate for a narrow provider-compat branch. |
| #416 | Stdio MCP provider docs mismatch | Maintainer confirmed docs are mistaken | #1058 is the likely docs vehicle; implementation of local stdio providers is larger #587 territory. |
| #689 | Transcription reliability | DSP/noise-gate discussion exists | Medium priority voice-quality branch after API/tool/provider regressions. |
| #1050 | CapabilitySearch eval hang | Unlabeled; maintainer workaround is `CI=true` | Small fix candidate: make eval CLI set/document CI mode or avoid interactive hang by default. |

## Feature Requests We Can Work On

| Issue | Feature | Size | Plan |
| ---: | --- | --- | --- |
| #232 | HTTP/SOCKS5 proxy support | Small/medium, `good first issue` | Good branch candidate: model downloads plus online provider URLSession/proxy config. |
| #605 | Function-key hotkey for voice transcription | Small/medium, `good first issue` | Needs macOS input-event design; research whether event taps or app-specific APIs can support Fn safely. |
| #443 | Import/use pre-downloaded Hugging Face local cache | Medium | Good follow-up to #1084's org-aware gate; support local folder/cache import without re-download. |
| #587 | Local MCP server support | Medium/large | Product implementation counterpart to #416/#1058 docs mismatch. |
| #417 | Speech output/full voice conversations | Large | Park until transcription reliability (#689) is better scoped. |
| #546 | Multi-agent API access | Large | Needs API design; not first unless maintainer prioritizes agent orchestration. |
| #1002 | Non-English TTS support | Medium | Voice roadmap candidate after core voice reliability. |
| #1069 | FIM request support | Medium | API compatibility branch candidate after #1086 and provider fixes. |
| #1065 | DFlash/speculative decoding model support | Research/large | Needs runtime capability investigation before branch work. |

## Automation Changes Needed

Each heartbeat should now:

1. Refresh main, #1086, open PRs, and open issues.
2. If #1086 merges, rebuild current main locally and refresh bug verifier
   evidence.
3. If #1086 receives review feedback, patch the same branch under a fresh
   lock; do not create a duplicate PR.
4. If #1086 stays ready and unreviewed, do not post another nudge until there is
   a materially new reason.
5. Keep #1048/#1006/#873/#963/#974 skipped unless live branch state changes or
   a maintainer explicitly asks for conflict resolution.
6. Prefer a new narrow bug branch from the "Open Bugs and Fix Candidates" table
   if maintainer review stalls.

---

Snapshot update: 2026-05-13 19:36 UTC, repo `osaurus-ai/osaurus`.

This update supersedes the 13:24 UTC queue state below. It is based on all 31
currently open PRs, current PR bodies/comments/reviews, check rollups, and the
latest heartbeat evidence from `/tmp/osaurus-coord`.

## Current State - 2026-05-13 19:36 UTC

- Open PRs evaluated: 31.
- Draft PRs: 24. Non-draft PRs: 7.
- Merge state distribution: 24 `DIRTY`, 6 `BEHIND`, 1 `BLOCKED`.
- PRs with no check rollup: #913, #963.
- PRs with red checks: #958, #1022, #1023, #1024, #1064.
- PR with pending/blocked checks: #1078.
- Latest `origin/main`: `f73e09b2d09e44d1d23dc00330afdd028a4cf04a`.
- Latest main GitHub run: green.
- Local release build of current main still fails at
  `Packages/OsaurusCore/Services/Sandbox/SandboxManager.swift:1009` because
  `process.kill(signal)` receives `Int32` while the current Containerization API
  expects `Signal`.

## Maintainer Nudge Decision

The only live `@tpae` nudge required right now is #1064, because it is approved,
directly addresses the current local-main build blocker, and remains `BEHIND`
with red `test-core`. A focused comment was posted:
`https://github.com/osaurus-ai/osaurus/pull/1064#issuecomment-4444593151`.

Do not post a fresh #1048 nudge yet. #1048 is still the A0 parent, but asking
for it to merge before the Signal API fix lands would keep downstream work
stuck on a build-red main. Also do not nudge the broad document stack until the
main build gate is clean.

## Updated Execution Order

1. Land or replace the Signal API fix.
   Primary path: maintainer refreshes/lands #1064. If the maintainer asks Codex
   to take it over, create a replacement branch from current `origin/main`, keep
   the fix narrow, and run the release build before opening/marking any PR ready.
2. Re-run current-main verification.
   Once #1064 or an equivalent fix is on main, run the shared release build and
   refresh verifier evidence for #995, #823, #789, #647, #903, #662, and #689.
3. Restore A0 ordering.
   Re-evaluate #1048 after main builds locally. If #1048 is still needed, resolve
   its dirty merge state, rerun local and remote gates, then ask for maintainer
   review/merge.
4. Retire superseded repair PRs.
   Keep #979 and #992 in maintainer closure-review only. Do not spend Xcode time
   on them unless a maintainer rejects the supersession classification.
5. Resume branch work only from a build-clean main.
   First non-document PRs: #1006, #873, #963, then #1073/#1078 if still open and
   relevant. Each branch action needs an explicit lock, exact-SHA local gates,
   push with `--force-with-lease`, and remote checks before readiness.
6. Resume the document stack after A0/main is clean.
   Sequence: #974, #941, publish `format-plugin-base-sha`, then #929/#939/#940,
   followed by #936, #937, #942, #983, #1022/#1023, and #1024.

## Open PR Plan - 2026-05-13 19:36 UTC

| PR | Bucket | State | Plan |
| ---: | --- | --- | --- |
| #873 | Community localization | Open, dirty, green | Hold until main build is clean; then rebase/resolve conflicts and gate. No duplicate nudge now. |
| #913 | Windows/Helios exploratory | Open, behind, no checks | Needs design review and package-specific build plan before merge work. |
| #929 | Document stack | Draft, dirty, green | Park until #974 base lands and format base SHA is published. |
| #936 | Document stack | Draft, dirty, green | Park until #929 lands; then rebase and gate. |
| #937 | Document stack | Draft, dirty, green | Park until #936 lands; then rebase and gate. |
| #939 | Document stack | Draft, dirty, green | Park until #974 base lands and format base SHA is published. |
| #940 | Document stack | Draft, dirty, green | Park until #974 base lands and format base SHA is published. |
| #941 | Document stack base | Draft, dirty, green | Run first after #974 if shared format base SHA is absent. |
| #942 | Document stack | Draft, dirty, green | Depends on #929/#939/#940/#941/#937. |
| #955 | Support/quality | Draft, dirty, green | Park until Phase 3/4 and main build are stable. |
| #958 | External HPKE | Draft, dirty, red `test-core` | Needs explicit security ack and owner conflict resolution before branch work. |
| #963 | Community localization | Draft, dirty, no checks | Rebase only after build-clean main; then run localization/build gates. |
| #974 | Document stack base | Draft, dirty, green | First document-stack base after A0/main build is stable. |
| #976 | Repair chain | Draft, dirty, green | Park behind #985/#979/#992 redesign and current main build cleanup. |
| #979 | Superseded repair | Draft, dirty, green | Closure-review candidate; do not close automatically. |
| #983 | Document/PDF stack | Draft, dirty, green | Rebase after lower document-stack PRs land. |
| #985 | Build/readiness repair | Draft, dirty, green | Live Phase 3 repair candidate, but blocked behind #1048 and main build cleanup. |
| #986 | Docs/workflow | Draft, dirty, green | Park until current ordering is stable, then update if still useful. |
| #987 | API compatibility guardrail | Draft, dirty, green | Park until build-clean main and provider fixes settle. |
| #988 | Eval smoke suite | Draft, dirty, green | Park until #985/#986 dependencies are stable. |
| #992 | Superseded repair | Draft, dirty, green | Closure-review candidate; do not close automatically. |
| #1006 | Packaging | Open, behind, green | First packaging branch after build-clean main; verify DMG output locally. |
| #1022 | Document stack | Draft, behind, red `test-core` | Rebase after #983; rerun once shared build/test blockers clear. |
| #1023 | Document stack | Draft, behind, red `test-core` | Rebase after #983; rerun once shared build/test blockers clear. |
| #1024 | Document docs | Draft, dirty, red `test-core` | Docs-only; rebase after #1022/#1023 and shared blockers clear. |
| #1048 | A0 local CI parity | Open, dirty, green | Re-evaluate after #1064/main build fix; do not nudge again before that. |
| #1058 | MCP docs | Draft, dirty, green | Canonical #416 docs PR; rebase after #1048 if still needed. |
| #1059 | Provider compatibility | Draft, dirty, green | Keep as provider #828/#615 draft; gate after main build and A0 are clean. |
| #1064 | SandboxManager build fix | Open, behind, red `test-core`, approved | Highest-priority unblocker. Nudge posted to @tpae asking for land/refresh or permission for Codex replacement. |
| #1073 | Voice/model runtime | Open, behind, green | Large runtime PR; rebase after build-clean main and run full runtime/voice checks. |
| #1078 | Chat UI polish | Open, blocked, pending `test-core` | New maintainer PR. Observe only until checks settle; do not interfere. |

## Automation Changes Needed

The heartbeat automation should stop cycling on downstream branch dispatch while
the shared main release build is red. Each tick should now:

1. Refresh PR/issues/runs and open PR bodies/comments/reviews.
2. Check for newly merged #1064 or equivalent Signal fix before spending Xcode
   on downstream branches.
3. Run one current-main release build if verifier evidence is stale.
4. Refresh the open PR plan and reviewer-summary artifacts.
5. Post at most one maintainer nudge per blocker class, only when no recent
   equivalent nudge exists.
6. Surface #1078 as observe-only unless it becomes a blocker or maintainer asks
   for help.
7. Never merge, close, delete branches, mark ready, or mutate PR bodies without
   exact local and remote gates.

Snapshot update: 2026-05-13 13:24 UTC, repo `osaurus-ai/osaurus`.

This update supersedes the queue state below while preserving the older
2026-05-07 snapshot for historical context.

## Current State - 2026-05-13

- Open PRs evaluated: 30.
- Comments, reviews, and inline review comments read: 46.
- `@tpae` comments requiring attention were found on #1048, #992, #985,
  #979, and #873.
- Posted fresh replies where useful:
  - #979: acknowledged the PR is superseded by merged #996 and should not
    advance as-is.
  - #985: acknowledged merged #1012 owns DeepSeek `reasoning_content`, keeping
    #985 scoped to stabilization/build-readiness.
- Did not duplicate comments on #992 or #873 because those already had
  follow-up notes.
- Current local blocker: `origin/main` still fails local
  `swift build --package-path Packages/OsaurusCore -c release` at
  `Packages/OsaurusCore/Services/Sandbox/SandboxManager.swift:1009`, where
  `process.kill(signal)` receives `Int32` but the Containerization API expects
  `Signal`.
- Highest-value unblocking PR is #1064 or an equivalent mainline fix for that
  SandboxManager Signal API mismatch.

## Updated Execution Order

1. Restore local main build.
   Prioritize #1064 or an equivalent fix for the SandboxManager Signal API
   mismatch. Do not request readiness for downstream Codex PRs until current
   main builds locally.
2. Re-stabilize A0.
   Refresh #1048 after the main build blocker clears, resolve or answer the
   remaining Copilot review threads, run local and remote gates, then ask
   `@tpae` to merge.
3. Retire superseded work.
   Recommend closure/retirement for #979 and #992 rather than spending build
   time on PRs the maintainer has redirected.
4. Gate current Codex/mimeding PRs in dependency order.
   Rebase each PR on a build-clean main and mark ready only when the exact head
   SHA has clean local and remote gates.
5. Wait until later today before posting maintainer nudges.
   Draft nudges are staged under `/tmp/osaurus-coord/maintainer-queue/maintainer-nudges/`.
   If there is no movement, nudge `@tpae` on #1064/#1048 and the requirement
   that all Codex PRs build cleanly before readiness.

## Open PR Plan - 2026-05-13

| PR | Bucket | State | Plan |
| ---: | --- | --- | --- |
| #873 | Community localization | Open, clean checks, merge conflicts | Do not duplicate comments. Needs owner/maintainer conflict resolution. |
| #913 | Windows/Helios exploratory | Open, behind, no checks | Needs design review and package-specific build plan before merge work. |
| #929 | Document stack | Draft, dirty, green | Park until #974 base lands; then rebase and gate. |
| #936 | Document stack | Draft, dirty, green | Park until #929 lands; then rebase and gate. |
| #937 | Document stack | Draft, dirty, green | Park until #936 lands; then rebase and gate. |
| #939 | Document stack | Draft, dirty, green | Park until #974 base lands; then rebase and gate. |
| #940 | Document stack | Draft, dirty, green | Park until #974 base lands; then rebase and gate. |
| #941 | Document stack base | Draft, dirty, green | Run first after #974 if format adapter base SHA is still absent. |
| #942 | Document stack | Draft, dirty, green | Depends on #929/#939/#940/#941/#937. |
| #955 | Support/quality | Draft, dirty, green | Park until Phase 3/4 and main build are stable. |
| #958 | External HPKE | Draft, dirty, red `test-core` | Needs security ACK and owner conflict resolution before branch work. |
| #963 | Community localization | Draft, dirty, no checks | Needs owner rebase/conflict resolution before build assessment. |
| #974 | Document stack base | Draft, dirty, green | First document-stack base after A0/main build is stable. |
| #976 | Repair chain | Draft, dirty, green | Park until #985/#979/#992 chain is redesigned. |
| #979 | Superseded repair | Draft, dirty, green | Recommend close/retire; issue addressed by #996. |
| #983 | Document/PDF stack | Draft, dirty, green | Rebase after lower document-stack PRs land. |
| #985 | Build/readiness repair | Draft, dirty, green | Re-scope to stabilization only; rebase after #1048/#1012 state and rerun gates. |
| #986 | Docs/workflow | Draft, dirty, green | Park until current ordering is stable, then update if still useful. |
| #987 | API compatibility guardrail | Draft, dirty, green | Park until build-clean main and provider fixes settle. |
| #988 | Eval smoke suite | Draft, dirty, green | Park until #985/#986 dependencies are stable. |
| #992 | Superseded repair | Draft, dirty, green | Recommend close/retire; fix belongs upstream in `vmlx-swift-lm`. |
| #1006 | Packaging | Open, behind, green | Develop only after main build is green; verify DMG output. |
| #1022 | Document stack | Draft, behind, red `test-core` | Rebase after #983; rerun once shared build/test blockers clear. |
| #1023 | Document stack | Draft, behind, red `test-core` | Rebase after #983; rerun once shared build/test blockers clear. |
| #1024 | Document docs | Draft, dirty, red `test-core` | Docs-only; rebase after #1022/#1023 and shared blockers clear. |
| #1048 | A0 local CI parity | Open, dirty, green | Parent PR after #1064/main build fix; resolve Copilot threads and nudge merge. |
| #1058 | MCP docs | Draft, dirty, green | Rebase after #1048; run docs/build gates. |
| #1059 | Provider discovery fallback | Draft, dirty, green | Add to action table; targeted provider tests after build-clean main. |
| #1064 | SandboxManager build fix | Open, behind, red `test-core` | Highest priority unblocker for local current-main build. |
| #1073 | Voice/model runtime | Open, behind, green | Large PR; rebase after build-clean main and run full runtime/voice tests. |

---

Snapshot: 2026-05-07 01:45 UTC, repo `osaurus-ai/osaurus`.

This is a triage and execution plan for Claude to expand and revise. It is based on GitHub open PRs, open issues labeled `bug`, PR check status, issue comments, and the local checkout state. The local checkout was on `main`, behind `origin/main` by 17 commits when this was written.

## Current Queue

- Open PRs: 26.
- Open bugs: 10.
- Red PR checks: #1022, #1023, #1024 currently fail `test-core`.
- Draft PRs: #1022, #1023, #958, #963.
- Conflict or stale merge state is the dominant PR blocker. Many PRs have green checks but are `DIRTY` or `BEHIND`.
- Recently merged PRs relevant to bugs:
  - #1035, `Prompt updates`, merged 2026-05-06.
  - #1038, `improved preflight capability search`, merged 2026-05-06.

## Ranking Rules

Rank by user impact first, then merge unblock value, then implementation risk.

1. Core app unusable, tool use broken, request loop stalls, or API compatibility broken.
2. PRs that close open bugs or unblock several other PRs.
3. Provider compatibility bugs with clear reproduction.
4. Feature PR stacks with many conflicts.
5. Cosmetic, localization, broad platform, or docs-only work.

## Ranked Plan

### P0 - Tool Discovery, Tool Execution, and "No Results" Reliability

Targets: #995, #823, #789, #647, plus PRs #1035 and #1038 already merged.

Why this is first: several users report that enabled tools are invisible, automatic tool selection is unreliable, web/search/date/calendar/file tasks fail, or the app burns tokens without producing artifacts. These reports cover local MLX, remote, cloud, and sandbox paths.

Plan:

1. Reproduce against current `origin/main`, not an old release.
2. Build a small manual matrix:
   - Foundation core model with Browser/Search/Time enabled.
   - Chat model as core model.
   - Manual tool selection with exact tool names.
   - Automatic tool selection with natural language prompts like "search the web", "check my calendar", "write a file on Desktop".
3. Run and expand the capability search/eval suite from #1038, especially browser prefix, fetch/extract webpage, time/date, calendar, file write, shell/sandbox, and abstain-on-greeting cases.
4. Inspect the active agent tool selection mode and chat session tool state path. Verify globally enabled tools, agent enabled tools, manual selections, and session-loaded tools all converge on the schema actually sent to the model.
5. Improve observability in Insights or logs so users can see:
   - which tools were exposed to the model,
   - why a tool was not exposed,
   - whether auto-selection skipped because no core model was configured,
   - raw or redacted request tool schema for debugging.
6. If #1035/#1038 resolve #823/#789/#995 in current main, comment with verification steps and close or convert remaining complaints into focused follow-up issues.

Definition of done:

- One automated test/eval verifies that `capabilities_search` finds Browser/Search/Fetch tools from natural language and exact-name queries.
- One chat/preflight test verifies auto mode loads usable tools when a core model is configured.
- One UI/logging improvement makes "which tools were available this turn" inspectable.
- #823, #789, and the tool portion of #995 have explicit closure or follow-up comments.

### P1 - Merge the Open Bug Fix PRs

Targets: #985, #992, #979, #976.

Why this is next: these PRs already address open or related bugs and reduce product pain without waiting for larger feature stacks.

Plan:

1. #985, `Fix open bug regressions and core build readiness`
   - Links/fixes: #662 and several related provider/runtime regressions.
   - Current blocker: `DIRTY` merge state despite green checks.
   - Rebase onto current `origin/main`, resolve conflicts, rerun `swift build --package-path Packages/OsaurusCore`, `swift test --package-path Packages/OsaurusCore`, and PR checks.
   - After merge, verify and close #662.
2. #992, `Preserve system prompts for Gemma templates`
   - Links/fixes: #903.
   - Current blocker: `BEHIND` with green checks.
   - Rebase, rerun the Gemma/local template compatibility tests, merge, then close #903 after release note or user confirmation.
3. #979, `Use lightweight context for Foundation`
   - Helps the small-context/tool-overload side of #995/#823.
   - Current blocker: `DIRTY`.
   - Rebase after #985/#992 if conflicts overlap, run prompt composer and session preflight tests, merge.
4. #976, `Return tool timeouts without draining blocked bodies`
   - Helps #647-style stuck/no-result sessions.
   - Current blocker: `BEHIND`.
   - Rebase, run `ToolRegistryTimeoutTests`, merge.

Definition of done:

- The linked bug PRs are rebased, green, and merged in the order that minimizes conflicts.
- Each linked bug has a comment pointing to the merge commit and the expected release/build containing the fix.

### P2 - Provider Compatibility Bugs

Targets: #828, #615, #416.

Why this is high: provider setup failure prevents users from using models they already have, and the repros are specific.

Plan:

1. #828, MiniMax 2.7 returns 404 because MiniMax does not expose a standard `/models` endpoint.
   - Add a provider mode or per-provider override that allows saving an endpoint without successful model listing.
   - Allow manual model IDs for OpenAI-compatible providers whose `/models` endpoint is absent.
   - Consider a MiniMax preset that knows `https://api.minimax.io/v1` and the Anthropic-compatible path.
   - Add tests in `RemoteProviderManager`, `RemoteProviderService`, and provider preset tests for "no model list but manual model id works".
2. #615, local Lemonade/OpenAI-compatible server exposes models at `/api/v1/models`.
   - Verify whether current base path handling can represent `/api/v1`.
   - Add tests for base path normalization and model-list parsing with Lemonade's extra fields.
   - If needed, add a separate "models path" override rather than overloading base path.
3. #416, command-based MCP stdio providers.
   - Short-term conservative fix: clarify docs/UI that remote MCP providers currently support HTTP/SSE only.
   - Longer-term feature: implement stdio transport as a separate provider type, with command, args, env, cwd, process lifecycle, timeout, and security prompts.
   - If not implementing stdio now, close #416 as documentation corrected and open an enhancement for stdio MCP clients.

Definition of done:

- MiniMax and Lemonade can be saved and used with a manual model id or provider-specific model discovery.
- HTTP/SSE MCP docs match actual behavior, or stdio support is implemented behind explicit UI and tests.

### P3 - Voice Transcription Reliability

Target: #689.

Why this matters: transcription is user-facing and feels broken when pauses, silence, or live typing produce corrupted output.

Plan:

1. Add a push-to-talk final-transcript mode in `TranscriptionModeService`.
2. Keep existing live typing as an advanced/legacy option, but make final-transcript mode the reliable default.
3. Implement clipboard paste with previous clipboard restoration where possible.
4. Add manual stop and optional automatic silence segmentation using `VADService`.
5. Add settings in `TranscriptionModeSettingsTab` and update `docs/VOICE_INPUT.md`.
6. Add tests around mode persistence, stop behavior, and cleanup; manual QA is needed for global hotkey, accessibility permission, and clipboard restoration.

Definition of done:

- Pause-heavy dictation no longer prematurely ends or corrupts text in the default mode.
- User can choose live typing vs final paste.
- Docs and settings describe the behavior accurately.

### P4 - File Generation and Business Document Stack

Targets: #647 plus PRs #929, #936, #937, #939, #940, #941, #942, #983, #1022, #1023, #1024, #974.

Why this is important: #647 reports "no output" for blog posts and PPT generation. Several open PRs appear to build the document/file infrastructure needed to make file tasks reliable.

Recommended merge order:

1. #974, on-demand high-fidelity skills.
2. #929, XLSX read adapter. Current blocker: `DIRTY`.
3. #936, XLSX write emitter. Current blocker: `DIRTY`.
4. #937, workbook agent tools. Current blocker: `DIRTY`.
5. #939, CSV/TSV streaming adapter. Current blocker: `DIRTY`.
6. #940, PDF table extraction. Current blocker: `DIRTY`.
7. #941, plugin format surface plus PPTX/POTX adapter. Current blocker: `DIRTY`.
8. #942, structured document attachments. Current blocker: `DIRTY`.
9. #983, high-fidelity PDF file attachment plumbing. Current blocker: `DIRTY`.
10. #1022, ExternalOfficeRuntime detection. Draft, `BEHIND`, red `test-core`.
11. #1023, PresentationDocument typed representation. Draft, `BEHIND`, red `test-core`.
12. #1024, document high-fidelity workflows docs. `BEHIND`, red `test-core`.

Execution notes:

- Do not merge document PRs solely because checks are green. Many are likely stacked and conflicting with each other.
- Rebase in dependency order and collapse stale duplicated commits where a lower PR already merged equivalent code.
- For #1022/#1023/#1024, pull the uploaded xcresult artifacts or rerun after rebase. The current failed checks are all `test-core`; `swiftlint`, `shellcheck`, and `test-cli` pass.
- After the stack stabilizes, add an end-to-end local test path for "create a presentation/file and expose the resulting artifact".

Definition of done:

- The file/document stack has one clear merged sequence, not overlapping dirty PRs.
- #647 gets a focused reproduction on current main. If still broken, file a narrower issue for the failing tool or artifact handoff.

### P5 - Runtime, Model Capability, and Evaluation Infrastructure

Targets: #1037, #955, #987, #988, #986.

Plan:

1. #1037, Ling vmlx runtime support.
   - Green but `BEHIND`.
   - Rebase and run the listed model profile/runtime tests.
   - Merge before work that depends on new vmlx/Ling behavior.
2. #955, LLM capability snapshot dispatch.
   - `DIRTY` but green.
   - Rebase after #985/#979 because provider/request surfaces may overlap.
   - Merge before adding provider-specific pruning or more advanced tool-gating logic.
3. #987, OpenAI compatibility guardrail report.
   - Green but `BEHIND`.
   - Merge after #985 so the Responses shorthand fix is present and the guardrail validates it.
4. #988, agent loop eval smoke suite.
   - `DIRTY`; PR body says it depends on #986 and #985.
   - Rebase after #985/#986 merge and verify it reduces to the intended eval slice.
5. #986, development plan and contributor workflow.
   - Green but `BEHIND`.
   - Merge after current bug-fix PR ordering is updated, or revise it so it does not conflict with this plan.

Definition of done:

- Runtime support, capability snapshots, and guardrails merge after their dependencies, not as parallel conflicting branches.
- CI/eval documentation points to one current workflow.

### P6 - Security, Packaging, Localization, and Broad Platform PRs

Targets: #958, #1006, #963, #873, #913.

Plan:

1. #958, HPKE e2e encryption for Bonjour-paired peers.
   - Draft, green, `DIRTY`.
   - Needs security review, threat model, compatibility tests, relay downgrade/failure behavior, and clear rollout plan before merge.
2. #1006, DMG BG.
   - Green but `BEHIND`; PR body is template-only.
   - Require before/after screenshot or generated DMG visual verification, then merge if purely packaging artwork.
3. #963, Russian localization.
   - Draft, no checks, `BEHIND`.
   - Rebase, run string catalog validation and Xcode project checks, then request native-language review if possible.
4. #873, zh-Hans localization.
   - Green but `DIRTY`.
   - Rebase, run `jq empty` on string catalogs and static missing-translation checks, then merge after conflicts are resolved.
5. #913, Windows port/rewrite.
   - No checks and template body.
   - Ask author to split into reviewable slices or close as too broad.

Definition of done:

- No draft/security/localization/platform PR merges without current checks and a real test plan.

## Open Bug Matrix

| Bug | Rank | Current read | Primary action |
| --- | --- | --- | --- |
| #995 | P0 | Umbrella "app unusable"; tool/search/date setup and sandbox failures; #1035 mentioned as fixing shell_run-related bug. | Verify current main, improve diagnostics, split remaining issues. |
| #823 | P0 | Tools enabled but invisible/unreliable; #1038 directly related and merged. | Verify #1038, expand capability tests, close or narrow follow-up. |
| #789 | P0 | Search tool not found; likely same root as #823. | Verify #1038, close with #823 if fixed. |
| #647 | P0/P4 | Work/chat produces no files or no visible result, especially presentation output. | Reproduce current main, merge timeout/tool/document stack, then narrow remaining failure. |
| #662 | P1 | OpenAI Responses shorthand item without `type` fails. | Merge #985, then close. |
| #903 | P1 | Gemma-family system prompts ignored. | Merge #992, then close. |
| #828 | P2 | MiniMax lacks `/models`, causing save/model-list 404. | Add manual model id/no-model-list provider path. |
| #615 | P2 | Lemonade local server model list path/schema. | Add model path/base path tests and parsing. |
| #416 | P2 | Docs imply stdio MCP client support that does not exist. | Clarify docs/UI or implement stdio transport. |
| #689 | P3 | Live transcription unreliable with pauses. | Ship final-transcript push-to-talk/clipboard mode. |

## Open PR Matrix

| PR | Rank | State | Action |
| --- | --- | --- | --- |
| #985 | P1 | Green, `DIRTY` | Rebase first; closes #662 and related core regressions. |
| #992 | P1 | Green, `BEHIND` | Rebase and merge for #903. |
| #979 | P1 | Green, `DIRTY` | Rebase after #985/#992; helps Foundation context/tool overload. |
| #976 | P1 | Green, `BEHIND` | Rebase and merge timeout behavior. |
| #1037 | P5 | Green, `BEHIND` | Rebase and merge runtime support if vmlx pin is accepted. |
| #955 | P5 | Green, `DIRTY` | Rebase after core provider/tool fixes. |
| #987 | P5 | Green, `BEHIND` | Merge after #985; useful guardrail. |
| #986 | P5 | Green, `BEHIND` | Revise/merge after bug-fix ordering is settled. |
| #988 | P5 | Green, `DIRTY` | Rebase after #985/#986. |
| #974 | P4 | Green, `DIRTY` | Rebase before document stack. |
| #929 | P4 | Green, `DIRTY` | Start document stack rebase here. |
| #936 | P4 | Green, `DIRTY` | Rebase after #929. |
| #937 | P4 | Green, `DIRTY` | Rebase after #936. |
| #939 | P4 | Green, `DIRTY` | Rebase in document stack. |
| #940 | P4 | Green, `DIRTY` | Rebase in document stack. |
| #941 | P4 | Green, `DIRTY` | Rebase after document adapter decisions. |
| #942 | P4 | Green, `DIRTY` | Rebase after #941 if still needed. |
| #983 | P4 | Green, `DIRTY` | Rebase after attachment/document surfaces settle. |
| #1022 | P4 | Draft, red `test-core`, `BEHIND` | Inspect xcresult, rebase, keep draft until green. |
| #1023 | P4 | Draft, red `test-core`, `BEHIND` | Inspect xcresult, rebase, keep draft until green. |
| #1024 | P4 | Red `test-core`, `BEHIND` | Rebase after #1022/#1023 or revise docs scope. |
| #958 | P6 | Draft, green, `DIRTY` | Security review before merge. |
| #1006 | P6 | Green, `BEHIND` | Require visual/package verification. |
| #963 | P6 | Draft, no checks, `BEHIND` | Rebase and run localization/Xcode checks. |
| #873 | P6 | Green, `DIRTY` | Rebase and validate string catalogs. |
| #913 | P6 | No checks, `BEHIND` | Split, clarify, or close. |

## Claude Handoff Checklist

For each PR Claude touches:

1. Run `git fetch origin --prune`.
2. Check out the PR branch with `gh pr checkout <number>`.
3. Rebase onto `origin/main` unless the PR is intentionally stacked on another open PR.
4. Resolve conflicts by preserving the narrower PR scope and dropping duplicated stale commits already merged through newer PRs.
5. Run the smallest relevant local tests first, then the package-level checks used by the PR body.
6. Push and recheck `gh pr checks <number> -R osaurus-ai/osaurus`.
7. Update the PR body with current validation and dependency notes.
8. Comment on linked issues with the PR number, expected release/build, and exact verification prompt or API request.
9. Close only after the fix is merged, released if necessary, and the issue is not still reporting a separate failure mode.
