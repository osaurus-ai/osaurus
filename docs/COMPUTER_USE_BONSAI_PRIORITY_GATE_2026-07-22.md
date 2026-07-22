# Computer Use / Bonsai priority gate — 2026-07-22

Status: **PARTIAL — the vMLX numeric parser and exclusive input route have
isolated Release UI evidence on Bonsai. The current AppleScript 16B route has
isolated Release UI evidence for exact whole-document and substring edits,
Thinking Off/On propagation, positive Save and negative no-Save controls,
runtime pre/post read-back, and terminal success. A fresh-chat Ornith run also
restored 4,190 tokens of the stable system/tool prefix from SSD with paged RAM
cache off. A stronger current-outcome contract removed the blocked redundant
`mac_query` in the latest Release replay, but Ornith then put a generated
replacement instruction in `content`; the narrow redundant-instruction
normalizer has focused-test but not rebuilt live evidence. Compile-envelope
recovery also has focused-test but not branch-specific live evidence. The broader cross-model, restart,
TurboQuant, and cache-eviction matrix remains open.**

This is the current checkpoint for the two priority user reports received on
2026-07-21/22. It does not replace the longer family/cache ledgers. A row may
move to verified only after both its owning source path and an isolated
Release Osaurus UI run are recorded here.

## Exact source baseline

- Osaurus baseline: `osaurus/main` at
  `0dfbae5dc3ae6395be130558da45db1d8dbd316f` (merged PR #2127).
- Working branch: `codex/computer-use-root-cause-20260722`.
- vMLX parser fix: PR #175 merged to `vmlx-swift/main` as
  `bbbf49e090449bb42f6cde8f50b6f230e3578aec`. The live Release rows below
  used the PR commit `61e7a02c0572f06c41a941d9ae8d215b47973ef0`; the merge commit has the
  same source tree, and the Osaurus workspace now pins the merged-main commit.
- Local models named by the reports:
  - `/Users/eric/models/dealign.ai/Bonsai-27b-Ternary-JANG-CRACK`
  - `/Users/eric/models/JANGQ-AI/AppleScript-16B-A4B-JANG_4M`
- No MXFP4 bundle is part of this gate.

## Preserved user evidence

The full 175,109,902-byte user video is intentionally not committed. The
downloaded source is
`/private/tmp/osaurus-bonsai-notes-permission-user-video-20260721.mp4`, SHA-256
`e08ab5823d97f8ca18d81388fcdcad4fa583efc093e6c5f814be741dd7c2e2ac`,
duration 369.495 seconds, H.264 2168x1560 plus AAC. Public source supplied by
the user: `https://disk.yandex.ru/i/sikfo00gk-dFZg`.

Committed evidence under `docs/evidence/computer-use-2026-07-22/`:

| Artifact | SHA-256 | What it proves |
| --- | --- | --- |
| `bonsai-initial-capability-stop.png` | `e21aa7f34bb79f8984d1a58a56975d6056586c467a49c70cf5d8f259c105ae98` | First response emitted only prose saying tools were being loaded. No capability/tool card is visible until the user's second message. This is not proof that a successful `capabilities_load` execution failed to continue. |
| `bonsai-notes-video-contact-sheet.png` | `cebe9379ba5e858cbb16b73eaf91887d65674a8a9745027ee574a7af148b5f00` | Whole six-minute sequence and repeated actions. |
| `bonsai-notes-075s-localized-open-failure.png` | `4075b710ecdfb754f30644563ca478fac1290c36f4472a65dd53d297a4a653b8` | `Open заметки` initially fails app lookup before a later `Заметки` attempt reaches confirmation. |
| `bonsai-notes-135s-invalid-target-after-success.png` | `b5d2122c359f421410042c2fc2965b9dbb51539723b6b5b421c9c61896c461c9` | After an approved click and `Change detected`, the next model action is rejected because `target` is not an object. |
| `bonsai-notes-240s-invalid-roles-redundant-clear.png` | `b7bfb957d0fe4f0314ba615a76ca47c4cc0159635c2191bc4bdff6a0ab38ab40` | `roles` is not an array, followed by a redundant clear attempt. |
| `bonsai-notes-300s-redundant-new-note.png` | `8ff7462465c8c4f7078e08813073a38994461fa6b8400bd559e48ee32e0fc2cf` | A new-note action is requested again after a note and text already exist. |
| `bonsai-notes-350s-double-numbering.png` | `2f20da911f3f2d90a6cae1cbb05fec31ec4dd3554dd6703f10ad97c0e354097d` | Notes auto-numbering plus model-supplied numeric prefixes yields duplicated numbers; output mixes Russian and English. |
| `bonsai-notes-365s-timeout-after-visible-completion.png` | `e8eaf9cbf741eaeb41ea3e70c0f16999c4f1474145d9a57071e4b59b21fdf7d2` | The document is visibly populated, but Computer Use returns `Reached the time limit before finishing`; the parent row shows five-plus minutes and 0.7 tok/s aggregate display. |
| `applescript16-user-report.txt` | `8ec4b7be3993cdd9ecb741ba248cca13be519f2285cb8c5626692c7073aba691` | Exact 0.22.7/0.22.8 TextEdit, placeholder, repeated-click, and malformed-action report. |
| `current-head-bonsai-stop-result.png` | `df5d079073fc11760ba351af66bb84c1270b49008162e502571f7e474210a9b3` | Pre-fix current-head replay with exact Bonsai bundle and visible Thinking Off. The parent called Computer Use directly, but the nested run emitted malformed actions, repeatedly targeted unchanged Notes rows/cells, and ended only when manually stopped. |

## Current-head pre-fix live reproduction

An isolated Release app (`com.dinoki.osaurus.lagunas21memoryproof20260721`)
was launched keychain-free against
`/private/tmp/osaurus-laguna-s21-live-root-20260721-1851-dflashfix` with exact
vMLX `a3b047e05871e1271fc86d2ef0ab2f8270aa832f`. Through the UI, the Assistant
agent's parent and Computer Use model were both set to exact
`dealign.ai/Bonsai-27b-Ternary-JANG-CRACK`; Thinking was visibly Off and
Computer Use permissions showed Accessibility and Screen Recording Granted.

Exact prompt:

`Привет, Том! Открой приложение «Заметки» и сделай нумерованный список от 1 до 5 для планирования дня.`

Observed result:

- The parent called `computer_use` directly after 13.73 s; B1 did not
  reproduce on this head.
- The nested model emitted both `roles`-not-array and `target`-not-object
  actions, then alternated open/click/double-click proposals against Notes
  rows/cells. Several actions reported `No visible change`.
- The run was manually stopped after about 164 s before any user note could
  be mutated. The existing selected note was read-only inspected and remained
  unchanged.
- Input trace contained both non-zero SkyLight statuses and `rc=0`. The bridge
  labelled every completed call delivered and returned true even for `rc=0`,
  so the public CoreGraphics per-pid fallback never ran for those rejected
  events.
- SSD partial restore did operate within the nested run: restored prefix
  boundaries advanced through 1,531→2,780→2,834→4,083 and later steps with
  the Qwen hybrid companion state (`ssm=96`), while paged blocks remained zero.
  That is useful cache evidence but does not close cross-chat/restart cache rows.

## Bonsai failure classes

These are separate until a current-head trace proves a shared owner.

| ID | Observed behavior | Current evidence | Current classification | Required closure evidence |
| --- | --- | --- | --- | --- |
| B1 | First answer says it is loading macOS tools and stops | Screenshot contains prose only; the later turn contains the first visible load card; current-head replay called `computer_use` directly on turn one | **NOT REPRODUCED CURRENT HEAD / USER EVIDENCE PRESERVED.** Do not call this a `capabilities_load` continuation bug unless raw history shows a completed load call on that first turn | Additional repeated live replay or original raw history |
| B2 | User reports Developer Tools permission helped app control | User follow-up says granting the permission solved the access problem; live TextEdit replay proved a SkyLight call can return `rc=0` and still deliver | **REPRODUCED-LIVE / PATCH REVISED / OPEN.** Treating zero as rejection and retrying through public `postToPid` delivered every character twice. The revised source chooses exactly one transport by app class: Cocoa uses public per-pid; Chromium uses terminal SkyLight when available or HID when unavailable. The Settings permission-diagnostics question remains separate. | Release replay with `OSAURUS_CU_INPUT_DEBUG=1` showing exactly one selected route per event and exact undoubled target text |
| B3 | Russian app name initially does not resolve | Video records `Open заметки` failure and later differently cased `Заметки` confirmation | **REPRODUCED-USER / ROOT OPEN.** Could be LaunchServices localization/name normalization, model casing, or both | Driver-level lookup trace and live Russian/English/bundle-id controls |
| B4 | `target` is scalar/string and `roles` is not an array | Two video frames and current-head live replay preserve the same validator classes | **NUMERIC TRANSPORT ROOT VERIFIED-LIVE / REMAINDER OPEN.** The exact Bonsai XML parser path converted Foundation `NSNumber(1)` to Bool because `JSONValue.from` tested `Bool` first; Swift proves `NSNumber(value: 1) as? Bool` succeeds. vMLX `61e7a02c` (merged unchanged as `bbbf49e`) distinguishes CFBoolean from numeric NSNumber before conversion. The post-pin Release replay preserved real object targets such as `{"mark":13}` and `{"mark":1}`. Bonsai also independently emitted the scalar string `"{'mark': 1}"`; scalar `roles` and other invented fields remain separate model/schema failures. The strict schema remains unchanged; no malformed-field alias was added. | Matched Ornith MXFP8 control plus remaining scalar-field classification; no synthetic coercion |
| B5 | Successful changes do not terminate; new-note/clear/type actions repeat | Video shows change detection followed by more mutations and eventual wall-clock timeout | **REPRODUCED-LIVE / RUNTIME SYNC ROOT FOUND.** After the requested mutation, the action result captured the textarea as `Hello agai` while an independent live accessibility inspection moments later showed exact `Hello again`. Bonsai then tried to append `g H` and, after decline, retype `Hello again`. The post-input view was sampled before event delivery/AX state had stabilized. | Patch the input-completion-to-observation boundary; isolated Release replay must show exact stable value, one mutation, terminal success, no save/repeat |
| B6 | Notes list is double-numbered and partly untranslated | Final document is visibly `1. 1.` through `5. 5.` with English tail entries | **REPRODUCED-USER / ROOT OPEN.** Do not hide with output post-processing | Exact typed payload, Notes AX state/formatting before typing, and matched plain-lines/numbered-list controls |
| B7 | Apparent 0.7 tok/s / five-minute run | Final frame shows aggregate parent row and a five-minute nested tool | **REPRODUCED-USER / METRIC OWNERSHIP OPEN.** The displayed parent rate may include nested-tool wait and is not yet inner Bonsai decode speed | Per-inner-step TTFT/token/s plus parent-only timing and Activity Monitor footprint |

The Bonsai bundle is Qwen 3.5 hybrid (`64` layers: `48` linear-attention and
`16` full-attention) and its template defaults thinking on when
`enable_thinking` is omitted. Current Osaurus source marks each nested Computer
Use model request as agentic; current-head live proof must show the effective
template kwarg for every inner step rather than infer it from the parent UI.
The patch captures the explicit UI value once per logical turn in
`ChatExecutionContext.currentEnableThinking`, includes it in `SubagentScope`,
and writes it to every Computer Use, AppleScript, Browser Use, and spawned-agent
request reconstruction. `nil` remains nil, so this does not invent a new
bundle sampler/template default.

## Patch and test checkpoint (not live acceptance)

### First isolated Release replay after the transport/Thinking patch

The first post-patch replay used isolated Release app bundle
`com.dinoki.osaurus.curootproof202607222232`, keychain-free root
`/private/tmp/osaurus-cu-root-proof-root-20260722-2232`, exact parent and
Computer Use model `dealign.ai/Bonsai-27b-Ternary-JANG-CRACK`, and a visibly
Off Thinking control. A disposable TextEdit window contained exactly
`Hello from OracHQ`; other already-open TextEdit documents were not mutated.

Exact prompt:

`Change the text in the open TextEdit document from “Hello from OracHQ” to “Hello again”.`

Observed result:

- The parent changed the requested scope into `... change ... then save the
  file`; the user did not request Save.
- The first nested `open` action was coherent and emitted no visible reasoning,
  but its merged accessibility view flattened three TextEdit windows into one
  list. The three text areas contained `Hello from OracHQ`, `Hello again`, and
  `Hello again`, without model-visible window ownership.
- The nested model then emitted an unexpected top-level `marker`, a scalar
  `target.value`, and finally a valid click on the already-edited window's
  mark 23 with a note saying it would save the document.
- The save-oriented click was declined, the run was stopped, and the UI showed
  `Failed: Computer use · 55.5s`. No mutation from this replay was approved.
- The loop uses non-stream `completeChat`, and tool calls were parsed. This
  replay therefore does **not** support content-delta streaming as the owner.
  It isolates three seams: parent goal scope expansion, raw/schema-invalid
  model arguments, and loss of window identity during multi-window view merge.
- Disk-backed partial restore operated during the failed nested run, with
  hybrid companion state (`ssm=96`) and paged payload disabled. That is not a
  correctness pass and does not close cross-chat/restart cache proof.

The next patch therefore preserves requested Computer Use scope exactly,
adds a TextEdit one-shot/no-save recipe, retains and renders window identity,
matches verification items by window id, records raw parser invocation JSON
before schema canonicalization, and records post-policy model options. It does
not add malformed-field aliases or a synthetic completion guard.

- `SkyLightBridge.postEvent`: returns `rc != 0`; zero is logged as rejected.
- `BackgroundDriver.route`: zero-rejected SkyLight events take exactly one
  Cocoa per-pid fallback or one Chromium HID fallback.
- `ChatExecutionContext` / `SubagentScope`: carry only the explicit turn-level
  Thinking boolean; no model-name matcher or hidden generation default.
- `ComputerUseLoop`, `AppleScriptLoop`, `AgentSubagentRunner`: apply the same
  captured boolean to every reconstructed nested request.
- `ComputerUseTraceLog`: off by default; when explicitly enabled, records
  the requested Thinking value, post-policy model options, raw parser tool
  invocation before schema canonicalization, canonical model tool arguments,
  visible-content surface, reasoning character count, finish reason, tokens,
  and tok/s.
- `ComputerUseTool`: explicitly forbids the parent from adding save, close,
  send, formatting, or unrelated follow-up work absent from the user's request.
- `AppRecipes.textEdit`: directs a one-shot `set_value`, same-window
  verification, and terminal `done`, with no save/close/format/create/repeat
  unless explicitly requested.
- `AgentView`: retains window id/title/focus through capture merging, renders
  window labels when more than one window is present, and includes window id in
verification matching so duplicate controls in different windows cannot
alias.

### Second isolated replay: window identity passed, numeric bridge failed

The second replay used the same isolated Release bundle/root and exact prompt,
with the same visible Bonsai parent/subagent selection and Thinking Off. It
failed after 1m12s without an approved mutation. The UI and trace establish:

- Every inner request recorded `effective_options={disableThinking=bool(true)}`
  and `reasoning_chars: 0`; the parent UI showed TTFT 1.36s, 3.3 tok/s, while
  inner steps were about 35 tok/s. This is live proof for Off on this replay,
  not yet the requested On/control matrix.
- The model-visible AX view correctly separated `[1] textarea [window
  "Untitled 4", focused] = "Hello from OracHQ"` from marks 24 and 47 in
  `Untitled 3` and `Untitled 2`. Window flattening was therefore fixed for
  this replay.
- Parsed invocations repeatedly contained `"target":{"mark":true}` even
  though mark 1 was the correct focused textarea and the tool feedback showed
  the model the integer form. Other calls still contained a scalar string
  `target` and scalar `roles`.
- No action was approved: a proposal against mark 23 was declined. Visual
  inspection after failure confirmed `Untitled 4` still contained exactly
  `Hello from OracHQ`.

Source tracing below Osaurus found the deterministic numeric corruption in
vMLX `JSONValue.from`: Foundation JSON integers are `NSNumber`, and the old
Bool-first cast converted `NSNumber(value: 1)` to `true` while constructing
`ToolCall.Function.arguments`. The fix at vMLX `61e7a02c`, merged unchanged
as `bbbf49e`, tests
`CFBooleanGetTypeID` first, then preserves integer versus floating-point
NSNumber identity with `CFNumberIsFloatType`. Its focused tests pass the exact
Qwen XML envelope and integer/float/boolean controls. The next isolated
Release replay accepted a real integer `mark` object without Bool corruption.

### Third isolated replay: numeric bridge passed, post-input snapshot failed

The next Release app was rebuilt after the workspace resolved exact vMLX
`61e7a02c`, ad-hoc signed as
`com.dinoki.osaurus.curootproof202607222232`, and launched keychain-free from
`/private/tmp/Osaurus CU Root Proof 20260722-2308.app` with isolated root
`/private/tmp/osaurus-cu-root-proof-root-20260722-2232`. The executable SHA-256
was `16db4463bd1ee06bed0e69da7e2a3d35c527d3106c448fe36b6ec6d76fb537ee`.

The real UI again showed exact Bonsai selected and Thinking Off. TextEdit
`Untitled 4` visibly contained exactly `Hello from OracHQ`; the same exact
replacement prompt was sent through the Osaurus chat UI.

Observed result:

- Every nested step recorded `disableThinking=bool(true)` and
  `reasoning_chars: 0`; inner decode was mostly about 35 tok/s.
- A real object invocation such as `"target":{"mark":13}` survived parsing
  as an integer target. This is the required live acceptance evidence for the
  vMLX NSNumber/Bool bridge fix. Bonsai also emitted the independently invalid
  scalar string `"target":"{'mark': 1}"`, which the strict validator rejected.
- The same focused `Untitled 4` window was mutated once. Independent Computer
  Use inspection immediately afterward showed only exact `Hello again` in
  that window; the other TextEdit windows remained separately identified.
- The action-result observation fed back to the model had instead captured
  `Hello agai`. Bonsai consequently proposed typing `g H`; after that was
  declined it proposed typing the full `Hello again` again. Both retries were
  refused, and Osaurus ended `Failed: Computer use · 5m 24s` without an
  additional mutation.
- The parent had already expanded the delegated goal to include `and save the
  file` even though the user did not request Save. The run did not reach that
  step because the repeat was stopped first. Prompt guidance alone therefore
  did not preserve scope.
- SkyLight delivery was observed with both `rc=0 -> rejected -> perPid` and
  later nonzero `rc=459079680 -> delivered`, proving the patched fallback was
  exercised in this real run.

This replay is **FAILED overall**. It separates a verified parser transport
fix from two still-open owners: sampling the post-input accessibility view
before the last delivered characters stabilize, and allowing the parent model
to expand the authoritative user scope with Save.

### Source checkpoint after the third replay (live acceptance still open)

Two narrow patches now own those remaining seams:

- `ComputerUseLoop.act` polls the real post-action accessibility snapshot only
  after successful text mutations (`type`, `set_value`, and `clear`). A direct
  replacement/clear completes as soon as the expected target value is visible;
  append-style typing requires the same value on two consecutive captures. It
  follows the same logical target across changing snapshot marks by window,
  role, accessibility path, label, and focus. The poll is capped at five
  50-millisecond follow-ups and returns the latest real snapshot on timeout;
  it never fabricates a target value or success state. Non-text actions keep
  the existing one-capture behavior.
- `ChatView` publishes the exact trimmed UI request through
  `ChatExecutionContext.currentUserRequest` for the logical turn, and
  `ComputerUseTool` uses that request as the authoritative nested goal when it
  is present. This prevents a parent-generated tool argument from adding Save
  to a UI request that did not ask for it. Direct/programmatic tool calls with
  no published UI request retain their explicit tool goal; this checkpoint
  does not claim API/plugin parity.

The combined focused Debug result is
`/private/tmp/osaurus-cu-root-derived-20260722/Logs/Test/Test-OsaurusCoreTests-2026.07.21_23-28-47--0700.xcresult`:
35/35 selected `ComputerUseLoopActTests`, `ComputerUseEvidencePackTests`, and
`SubagentSessionTests` passed. The added tests reproduce the transient
`Hello agai` then `Hello again` snapshot sequence and assert exact UI-request
scope over a parent-expanded `Replace the text and save the file` argument.
This is source/test evidence only. A newly rebuilt isolated Release app must
still complete the exact TextEdit replay once, with the full settled value,
terminal success, and no retry or Save action.

- Focused Debug result:
  `/private/tmp/osaurus-cu-root-derived-20260722/Logs/Test/Test-OsaurusCoreTests-2026.07.21_22-05-05--0700.xcresult`.
  All nine `BackgroundDriverRouteTests` and the `SubagentSessionTests` passed,
  including reject→fallback/no-double-delivery and Thinking true/false/nil.
  This is test evidence only; post-fix Release UI rows remain open.

### Fourth isolated replay: cache reuse observed, transport delivery doubled

The latest sealed Release app was
`/private/tmp/Osaurus CU Root Proof 20260722-2343.app`, bundle id
`com.dinoki.osaurus.curootproof202607222338`, executable SHA-256
`962a98093b9ad9a656f16ce508d7a173e069726581a91d0e76bcc4130fd60730`.
It used exact vMLX `61e7a02c`, a fresh keychain-free root, exact Bonsai parent
and Computer Use model, visibly Off Thinking, Balanced autonomy, and the exact
TextEdit replacement prompt above.

Observed result:

- Window identity and authoritative goal scope held: the nested goal contained
  no Save request, and the model-visible view distinguished focused `Untitled
  4` from the two other TextEdit windows.
- Every nested response recorded `reasoning_chars: 0`; dispatch recorded
  `disableThinking=bool(true)`. The raw request's nullable Thinking value was
  still `nil`, so this proves effective Off behavior for this run, not yet an
  explicit Off/On propagation matrix.
- Disk L2 restored partial tool-loop prefixes at boundaries including 1,479,
  1,706, 3,456, 3,512, 3,554, and 3,639 tokens with Qwen hybrid companion state
  `ssm=96`, while paged RAM cache was off. This is real same-run partial reuse,
  not cross-chat/restart proof and not a correctness pass.
- After the first wrong-window mutation was visibly declined, later mutations
  executed without a second visible approval being observed. The focused
  document ultimately contained doubled characters (`HHeelllloo. aaggaaiinn`)
  and another TextEdit document was cleared. The UI ended `Failed: Computer
  use · 2m 7s` at the step limit.
- The source branch had changed `SLEventPostToPid rc=0` into a fallback trigger.
  The action reported public per-pid routing, yet the doubled value proves the
  preceding private call also delivered. The preserved trace is
  `/private/tmp/bonsai-ax-settle-live-failed-20260722.log`, SHA-256
  `279b7b0dd4ee1380ab3d70eddef19e88cdc82f1d9effeddaf8c68c0e65cfa91e`.

The revised source does not chain transports: Cocoa/unknown apps use public
`CGEvent.postToPid` only; Chromium uses terminal SkyLight when available and
HID only when it is unavailable. Gate/confirmation tracing now records the
classified effect, decision, enqueue, user resolution, and any scoped
auto-approval. These changes remain source-only until the next Release replay.

## Current isolated Release cross-model replay — 2026-07-22

The sealed app `/private/tmp/Osaurus CU Root Proof 20260722-0026.app` used
bundle id `com.dinoki.osaurus.curootproof202607222338`, exact vMLX
`61e7a02c0572f06c41a941d9ae8d215b47973ef0`, and isolated root
`/private/tmp/osaurus-cu-root-proof-root-20260722-2343`. Its executable SHA-256
was `13f7a9aaa903f1baa443d48462aa14d471a7af18342aea408611c4b43ea0e632`.
The UI showed Accessibility and Screen Recording granted, Balanced global
autonomy, Ask First for editing, and the visible Thinking control.

| Route/model | Live result | Thinking evidence | Disk-L2/tool-prefix evidence |
| --- | --- | --- | --- |
| Bonsai 27B 1-bit JANG CRACK through generic Computer Use | **PASS for the exact TextEdit replacement only.** The user turned Thinking On and then Off in the visible UI. Clear and Type each displayed a confirmation, both were approved, TextEdit ended with exactly one `Hello again`, no Save occurred, and the UI terminated green `DONE` in six steps. The input trace contained only `route pid=3434 -> perPid (Cocoa/unknown; exclusive)`, with no double transport. | Every delegated step recorded `requested_enable_thinking=Optional(false)`, `disableThinking=bool(true)`, and `reasoning_chars:0`. This closes explicit Off for this route only; On behavior remains open. | With paged RAM cache off, the parent restored boundary 3,183/3,642. Nested partial boundaries grew through 1,238, 1,513, 1,618, 1,886, 2,147, and 2,229. Final counters included Disk L2 hits/misses/stores `15/41/15`; prefix-RAM hits/misses stayed `0/0`. |
| Ornith 1.0 9B JANG_4M through the same generic Computer Use task | **FAIL/PARTIAL.** The model focused the correct TextEdit window, first proposed plain `a`, then recovered to Command-A after denial, but proposed Command-A repeatedly after an approved edit. Later repeated edits were declined and the UI ended `Failed: Computer use · 2m 9s`. | Explicit visible Off reached all sampled nested steps as `disableThinking=true` with `reasoning_chars:0`; hidden reasoning was not the observed owner. | The first model-specific parent prefix missed and stored. Later same-route restores included boundary 1,992 with only 3 tokens left and nested partial hits at 1,513, 1,561, and 3,306. Cache reuse operated, but behavior still failed. |
| AppleScript 16B A4B JANG_4M through the dedicated AppleScript ability | **FAIL/PARTIAL on the pre-read-back-fix app.** The first confirmed script used `oldText`/`newText` placeholders and changed TextEdit to exactly one `Hello again` with no Save. The helper then entered its model-authored verification turn, produced broken verifier scripts, and failed. A later parent retry invented Save text, but dispatch retained the exact no-Save UI task; that second script was declined. | The parent was Ornith with visible Thinking Off. AppleScript dispatch received the authoritative current job rather than the parent-expanded text. The helper-specific On/Off matrix remains open. | First helper prefill was a model-specific cold miss and stored rotating KV plus required companion state with paged off. A later helper run restored boundary 1,793/1,840. This is a real hit, not a behavioral pass or restart proof. |

Preserved traces:

- Bonsai pass: `/private/tmp/bonsai-exclusive-route-gate-live-pass-20260722.log`,
  SHA-256 `ea436e571b63c3cf0ed676bf00231bda0bd39a19535ea61ef9b6ce2e9814ebde`.
- Ornith failure: `/private/tmp/ornith9b-jang4m-computer-use-loop-fail-20260722.log`,
  SHA-256 `f69419cda5cf6037021eca1fa239f7433143bd61568ea411fec58fc111855d34`.
- AppleScript failure: `/private/tmp/applescript16-post-success-retry-live-fail-20260722.log`,
  SHA-256 `d5a2a9743265090c1abf8c0939aabfbab2616fa27c5109826fe154234be76ccd`.
- Cumulative cross-model trace:
  `/private/tmp/cross-model-cu-applescript-live-matrix-20260722.log`, SHA-256
  `8cc0dfb2c8cb90a91840082e606de5ae80bd52851736381a9dbe5493e7803378`.

The AppleScript source owner is `AppleScriptLoop.shouldVerify`: exact content
replacement was classified as requiring verification, but the loop asked the
small helper model to author a second read-only script after the already
successful write. The current patch recognizes only a confirmed exact
TextEdit replacement carrying `oldText` and `newText`, performs runtime-owned
read-only `text of front document` observations immediately before and after
the approved script, and terminates only when the real post-state equals the
expected replacement. A mismatch or read error falls back to the existing
verification loop; no target value or success is fabricated.

Focused Debug result:
`/private/tmp/osaurus-cu-root-derived-20260722/Logs/Test/Test-OsaurusCoreTests-2026.07.22_00-34-19--0700.xcresult`.
The selected AppleScript classifier, loop, tool-guidance, model-routing, and
app-knowledge suites exited 0. The added regression proves one confirmed write,
two runtime reads, exact observed `Hello again`, one confirmation, and no
second model mutation. This is source/test evidence only until rebuilt Release
UI proof completes.

### First runtime-read-back Release replay: parent literal routing failed first

The corrected read-back build was sealed as
`/private/tmp/Osaurus CU Root Proof 20260722-005124.app`, bundle id
`com.dinoki.osaurus.curootproof202607222338`, executable SHA-256
`8d48cbbfa09deac10b9514a64e9f439bb49553006598f87449547483fbdb245a`.
The real agent UI visibly showed Ornith 9B JANG_4M, Thinking Off, AppleScript
enabled, AppleScript 16B A4B JANG_4M selected, and Confirm Each Script selected.
TextEdit was restored through Computer Use to exact `Hello from OracHQ` before
the same no-Save prompt was submitted.

This replay **FAILED before the new read-back path could run**:

- The parent first called `mac_query` to read the front TextEdit text. The
  existing live-current-request conflict check rejected it before execution;
  the UI nevertheless correctly displayed that tool call as failed instead of
  hiding it.
- The retry called `applescript` with a generated AppleScript program in the
  single `content` field and rewrote the job as finding a document *named*
  `Hello from OracHQ`. The helper received only `literal_keys=["content"]`
  and proposed creating/addressing such a document. The visible script card
  was declined. No script executed and live TextEdit remained exactly
  `Hello from OracHQ`.
- SQLite preserved the exact raw parent calls in session
  `1E6F99E7-92C2-4AB5-86FE-F1CD9E4A7C12`; this separates parent tool-argument
  construction from AppleScript content-delta streaming or the helper parser.
- The new-chat Ornith parent visibly began prefill at `2585/2911`. Runtime
  trace records a Disk-L2 hit at boundary 2,585 with 326 tokens remaining.
  The first AppleScript-helper prefix missed after the 10 GiB disk quota had
  evicted older blocks, then subsequent helper iterations hit boundary
  1,820/1,971 and 1,971/2,108. Cache use was active but did not cause or cure
  the malformed parent task.

Preserved artifacts:

- stdout/cache trace:
  `/private/tmp/applescript16-runtime-readback-live-20260722.log`, SHA-256
  `935b4be33b652ab9c42f5161de3f7851cc8704ff9565b5db5ce9d05118b7d7d8`;
- cumulative AppleScript raw-step trace copied immediately after the run:
  `/private/tmp/applescript16-runtime-readback-live-20260722.applescript-trace.log`,
  SHA-256
  `e2014557a7e124ed96da7a67fe920594751b627bd2763351a22aa308c44e042b`;
- isolated chat database:
  `/private/tmp/osaurus-cu-root-proof-root-20260722-2343/chat-history/history.sqlite`.

The owning dispatch bug was a persistence race: the exact UI request already
exists in `ChatExecutionContext.currentUserRequest` during the tool call, but
`latestUserTaskFromCurrentSession` consulted only SQLite, where the active user
turn is not guaranteed committed yet. The current patch prefers that TaskLocal
and retains SQLite only for API/plugin contexts without it. It also covers the
exact observed parent rewrite narrowly: the direct user replacement remains
authoritative only when the parent repeats both exact user values byte-for-byte
and contains a mutation verb. Compare/read requests, partial matches, and
different values are not reconciled.

Focused Debug result after that patch:
`/private/tmp/osaurus-cu-root-derived-20260722/Logs/Test/Test-OsaurusCoreTests-2026.07.22_00-58-15--0700.xcresult`.
The selected `AppleScriptToolDispatchLiteralsTests` and `AppleScriptLoopTests`
exited 0, including the exact raw parent rewrite, TaskLocal-first lookup,
read/partial-value negative controls, exact runtime read-back script bytes, and
one-write termination. This remains source/test evidence; another isolated
Release replay is required.

### Current runtime-read-back Release replay and fresh-chat SSD control

The current sealed Release app is
`/private/tmp/Osaurus CU Root Proof 20260722-0158.app`, bundle id
`com.dinoki.osaurus.curootproof202607222338`, executable SHA-256
`894c5cdd887720637f9c2e77dc7f10279f915170deed41c702ba35d0e46673be`.
It was launched keychain-free against
`/private/tmp/osaurus-cu-root-proof-root-20260722-2343` and exact vMLX
`61e7a02c0572f06c41a941d9ae8d215b47973ef0`. In the real Settings UI, the
external model folder was changed to `~/models` and Rescan visibly found 68
external models. The same app then visibly showed:

- Ornith 1.0 9B JANG_4M selected and warm;
- Thinking Off;
- Computer Use enabled with inherited approval and screen context;
- AppleScript enabled with exact
  `JANGQ-AI/AppleScript-16B-A4B-JANG_4M` and Confirm Each Script;
- Prefix Cache On, GPU Cache (Paged KV) Off, Disk Cache On, and SSM re-derive
  On in Server -> Settings -> Cache.

TextEdit was reset through its live UI to exact `Hello from OracHQ`. The exact
prompt was then submitted twice in separate new chats:

`Use the AppleScript helper—not Computer Use—to change the text in the open
TextEdit document from “Hello from OracHQ” to “Hello again”. Do not save the
document.`

Both replays reached the same visible confirmation card containing only:

`tell application "TextEdit" to set text of front document to "Hello again"`

After one approval, both ended with exact `Hello again` in the same unsaved
TextEdit document, one script mutation, one runtime-owned post-read, no Save,
no repeated mutation, an empty persisted reasoning field, and a coherent final
answer. The first row showed TTFT 1.30 s, 69.5 tok/s, 16 tokens. The fresh-chat
row showed TTFT 1.53 s, 70.1 tok/s, 13 tokens. SQLite session
`EB7BCADE-6BD3-477B-85D0-DDB60026F7F4` records one `applescript` call,
`scripts_run=1`, `model_tokens=0`, the exact one-line action, the real
`Hello again` post-read, and no further tool call.

This closes the exact AppleScript replacement/finalization row on this source,
not arbitrary TextEdit edits or the generic Computer Use loop. The source
owner is the narrow exact-replacement path in `AppleScriptLoop`: it reads the
real front-document text before approval, permits one direct TextEdit set only
when that value equals the supplied `oldText`, reads the real value afterward,
and terminates only when it equals `newText`. Mismatch/read failure retains the
existing model path; no success or target value is fabricated.

The first replay still emitted and rejected a redundant read-only `mac_query`
before its successful `applescript` call. The second matched fresh-chat replay
selected `applescript` directly. Therefore the selection guidance is **not a
deterministic fix** for that adjacent behavior and the row remains open. The
invalid read call executed no script and the mutation/finalization contract
still held.

The fresh-chat cache trace supplies the requested SSD-only prefix proof for
this Ornith tool route:

- a 4,201-token new-chat prompt restored Disk-L2 boundary 4,190 with one token
  remaining;
- the 4,711-token user/tool prompt restored the same 4,190-token stable prefix
  with 521 tokens remaining;
- after the tool call, 4,938 tokens restored boundary 4,190, and the final
  continuation restored boundary 4,931 with 25 tokens remaining;
- every store records `blocks=0 payload=false`, so no paged-RAM payload owns
  these hits; the Qwen hybrid companion state records `ssm=48`;
- the 10 GiB quota evicted one older KV entry while retaining and reusing the
  longest matching current prefix.

This is current live proof that the already-merged cross-chat SSD restore path
works for the Ornith Qwen-3.5 hybrid system/tool prefix when paged RAM cache is
off. It does not prove app-restart restore, every model family, media salts,
TurboQuant, corruption recovery, or the user's SSD throughput on another Mac.

Current artifacts:

- stdout/cache trace:
  `/private/tmp/applescript16-readback-crosschat-live-20260722.log`, SHA-256
  `6f7d19fe680d917b34b9979b658cda0bd5e616e7853df83ae905a3b6d733b5c8`;
- AppleScript dispatch/gate trace:
  `/private/tmp/applescript16-readback-crosschat-live-20260722.applescript-trace.log`,
  SHA-256
  `37a375292b8143881c7d09143fc5522befe91744118d13fcf3398b4701385871`;
- isolated history snapshot:
  `/private/tmp/applescript16-readback-crosschat-history-20260722.sqlite`,
  SHA-256
  `e31cc4f8ad5aa01df71e95a0bee0c2ba8cfd5a42b36b23ee7ffab3145620b03d`;
- focused Debug result:
  `/private/tmp/osaurus-cu-root-derived-20260722/Logs/Test/Test-OsaurusCoreTests-2026.07.22_01-47-23--0700.xcresult`.

## Fresh AppleScript scenarios and final Save/no-Save control

The final current-source replay used ad-hoc-signed Release app
`/private/tmp/Osaurus CU Root Proof 20260722-0248.app`, bundle id
`com.dinoki.osaurus.curootproof202607222338`, isolated root
`/private/tmp/osaurus-cu-root-proof-root-20260722-2343`, parent
`ornith-1.0-9b-jang_4m`, and exact helper
`JANGQ-AI/AppleScript-16B-A4B-JANG_4M`. Its executable SHA-256 is
`3e39819be7d1af5fd1743583188b0438b154df4b62047204114ad74efda4472a`.
The AppleScript ability and Confirm Each were selected in the real Settings UI;
Thinking was changed through the visible chat control.

Fresh scenarios exercised through the Osaurus UI:

| Scenario | Live result | Classification |
| --- | --- | --- |
| Feedback-only statement after successful TextEdit/Calculator actions | No tool call and no fabricated time/date. The model did over-interpret visible screen context and asked a follow-up. | **ROUTING PASS / CONVERSATION QUALITY PARTIAL** |
| Read exact front TextEdit text, no mutation | One read-only `mac_query` returned exact `Hello again`; no confirmation or mutation. The read helper intentionally used resident Ornith. | **VERIFIED-LIVE** |
| Substring replacement preserving `Header` and `Footer`, Thinking Off | AppleScript 16B generated one delimiter-based script, one approval changed only the middle line, read-back matched, no Save/retry; helper trace recorded `requested_enable_thinking=Optional(false)` and zero reasoning chars. | **VERIFIED-LIVE** |
| Same substring replacement, Thinking On | The pre-fix/current-worktree run reproduced a malformed compile followed by reasoning-only/no-envelope failure. The rebuilt current-source run received `requested_enable_thinking=Optional(true)`, generated a valid script on its first helper step, changed only the middle line once, left the document unsaved, and ended coherently at 78.0 tok/s. | **TOGGLE + TASK VERIFIED-LIVE; COMPILE-REPAIR BRANCH TEST-ONLY** |
| Explicit Save on an existing `/private/tmp` TextEdit file | Pre-fix replay wrongly entered `mac_query`, emitted invalid read scripts, executed nothing, and left UI/disk at `Save control old`. Final replay showed one confirmation containing `set text ... "Save control new"` plus `save front document`; after approval TextEdit had no Edited badge, disk bytes were exactly `Save control new`, and the final was coherent at 68.7 tok/s. | **VERIFIED-LIVE** |
| Inverse no-Save control in the same final binary | Confirmation contained only `set text ... "Save control draft"`. After approval TextEdit visibly showed `Save control draft — Edited`, while disk bytes and mtime remained the saved `Save control new`; final was coherent at 67.6 tok/s. | **VERIFIED-LIVE** |

The explicit-save failure had a concrete routing root. Exact replacement
parsing recognized `change ... from ... to ...` and `replace ... with ...`, but
not the natural `replace ... from ... to ...` form. Therefore the current-user
conflict guard did not recognize the mutation and could not reject the wrong
read path. `AppleScriptToolDispatch.exactReplacementLiterals` now recognizes
only that additional two-quoted-value grammar. `AppleScriptLoop` carries a
`saveRequested` bit in the already-narrow exact TextEdit contract; it adds
`save front document` only for a positive save request and explicitly excludes
`do not save`, `don't save`, `never save`, `without saving`, and unsaved forms.
Both variants retain the ordinary approval gate and real pre/post TextEdit
reads. No model output, sampler, parser result, or success value is fabricated.

The parent still selected `mac_query` first in both final Save/no-Save rows.
The exact-request guard rejected it before any script ran, and the parent then
called `applescript` successfully. The visible red failed-query card is honest
and remains a routing/presentation follow-up; this document does not claim that
the redundant selection is gone.

Current proof artifacts:

- Release stdout/cache trace:
  `/private/tmp/osaurus-cu-root-explicit-save-live-20260722.log`, SHA-256
  `641ec840b196c7db8fd9f6675075a6bf7b04730247240c3dac3ab106cda1fdeb`;
- AppleScript gate trace:
  `/private/tmp/osaurus-applescript-explicit-save-final-trace-20260722.log`,
  SHA-256
  `b94a7d8caae54218e645c63cf9e74861a051ea7f823de52bc8056081b59c4b43`;
- isolated history snapshot:
  `/private/tmp/osaurus-applescript-explicit-save-final-history-20260722.sqlite`,
  SHA-256
  `0c20648602f0ae6b733b321ad52ef4630c1ec34fc6319dcf18479e2832340826`;
- focused current-source result:
  `/private/tmp/osaurus-cu-root-derived-20260722/Logs/Test/Test-OsaurusCoreTests-2026.07.22_02-39-31--0700.xcresult`,
  reporting 61 passed, 0 failed. It includes exact Save/no-Save,
  `replace ... from ... to ...` conflict routing, and one-shot
  compile-envelope recovery.
- combined Computer Use/driver/view/recipe/subagent/turn-control result:
  `/private/tmp/osaurus-cu-root-derived-20260722/Logs/Test/Test-OsaurusCoreTests-2026.07.22_02-57-19--0700.xcresult`,
  reporting 69 passed, 0 failed on the final combined source.

The final two fresh chats also restored the parent Qwen-hybrid prefix from SSD
with paged payload absent: representative hits include boundary 2,610 for
3,137-token prompts, then boundaries 3,249/3,481 and 3,235/3,469 for tool
continuations, all with `ssm=48`; paged stores recorded
`blocks=0 payload=false`. The 10 GiB quota evicted older KV plus companion
entries while stores continued. This extends the current Ornith new-chat slice
but still does not close restart or other-family cache rows.

### Current routing/schema replay before final rebuild

Release app `/private/tmp/Osaurus CU Root Proof 20260722-0340.app`, executable
SHA-256 `3479ea7608706441ad07d266d80e8520d5627468fe12c44e8d10102281c82e15`,
reused the isolated keychain-free profile after the parent prompt and
`mac_query` schema were strengthened. The real UI showed Ornith 9B JANG_4M,
Thinking Off, AppleScript enabled, AppleScript 16B selected, and Confirm Each.
A fresh unsaved TextEdit document was reset through its UI to exact
`Routing direct old`.

Exact prompt:

`Use the AppleScript helper—not Computer Use—to replace the entire text in the
open TextEdit document from “Routing direct old” to “Routing direct new”. Do
not save the document.`

The first tool selection was now `applescript`, not `mac_query`, so the prior
read-before-edit routing defect did not reproduce. It was still rejected
before execution because Ornith put a generated instruction in `content`:

`{"content":"Replace all occurrences of ...","task":"Replace all
occurrences of ..."}`

The second `applescript` call was valid. One confirmation showed only the
direct TextEdit set, one mutation produced exact `Routing direct new`, the
document remained unsaved, and the coherent final showed TTFT 1.24 s at
69.0 tok/s. The visible failed first card means the row is **PARTIAL**, not a
clean pass.

The owning parser/contract seam is distinct from content-delta streaming: the
stored raw tool call and strict `invalid_args` result are complete. The current
source recovers only a single redundant `content` instruction when `task`
independently parses as a complete exact old/new replacement, the content
contains both exact values plus a mutation verb, and the task does not
reference provided content. Partial/different values, mixed maps, genuine
literal data, and tasks that reference provided content remain strict. The
focused `AppleScriptToolDispatchLiteralsTests` plus
`AppleScriptToolSelectionGuidanceTests` exited 0, including four negative
controls. This normalizer still needs a new Release UI replay after the branch
is rebased onto current `main`.

## Cross-model tool/reasoning/cache acceptance matrix (partially run)

After the delivery and confirmation paths pass on Bonsai, repeat the same
observable TextEdit task without changing its wording on:

1. Bonsai 27B 1-bit JANG CRACK.
2. A locally available Ornith/Qwen MXFP8 or JANG4M bundle; do not substitute an
   MXFP4 bundle.
3. AppleScript 16B JANG_4M through its real delegated AppleScript lane.

For each model, run visible Thinking Off and On controls, record every nested
step's effective template option and reasoning surface, preserve raw and
canonical tool calls, and verify exact one-shot mutation, approval behavior,
terminal success, no Save expansion, and no collateral window changes.

Cache proof must keep paged RAM cache off for the default row and record prompt
tokens, restored Disk L2 boundary, remaining prefill, TTFT, token/s, store/hit
counters, and architecture companion state. Repeat in a new chat and after app
restart with the identical tool-system prefix, then a partially changed user
prompt, so the tool schema/system prompt's reusable blocks are measured rather
than inferred. A same-run hit or a high hit counter alone does not prove
cross-chat/restart reuse or acceptable behavior.
- Expanded focused Debug result:
  `/private/tmp/osaurus-cu-root-derived-20260722/Logs/Test/Test-OsaurusCoreTests-2026.07.21_22-32-43--0700.xcresult`.
  All 58 selected `AgentViewTests`, `AppRecipeTests`,
  `ComputerUseEvidencePackTests`, `BackgroundDriverRouteTests`,
  `SubagentSessionTests`, and `ChatTurnGenerationControlsTests` passed. New
  assertions cover cross-window identity, focused-window change matching,
  TextEdit set-once/done/no-save guidance, and parent scope preservation. This
  remains source/test evidence only.
- Pinned-vMLX focused Debug result:
  `/private/tmp/osaurus-cu-root-derived-20260722/Logs/Test/Test-OsaurusCoreTests-2026.07.21_23-02-50--0700.xcresult`.
  The same selected Computer Use, driver, view, recipe, and subagent suites
  passed after the workspace resolved vMLX `61e7a02c`. The new vMLX parser
  suite separately passed 2/2 tests: exact Qwen nested mark 1 and Foundation
  integer/float/boolean preservation. A wider vMLX focused-target attempt is
  not green evidence: unrelated Gemma/LFM expectations failed and GPU rows
  could not locate the package's default Metal library in that shell.

## AppleScript 16B versus generic Computer Use

The user-facing phrase “AppleScript 16B selected” does not make every failure
an AppleScript-loop failure:

- Native AppleScript uses the dedicated `applescript` tool and the helper's
  `run_applescript` schema.
- Native Computer Use uses `computer_use`, whose nested planner must emit the
  unrelated `agent_action` schema (`verb`, nested `target`, array `roles`, and
  terminal `done`).
- Current UI intentionally excludes dedicated `JANGQ-AI/AppleScript-*` bundles
  from chat, Spawn, and generic Computer Use model candidate lists. A prior
  temporary exposure was live-disproved and reverted because the helper did
  not reliably emit `agent_action`.

### Already merged/live-proven native AppleScript slice

Merged PR #2118 (`cee858bc84ccf49cdab1d05dcdcbfb83eed520de`) contains the
native AppleScript state/contract fixes. Its isolated Release proof used exact
`JANGQ-AI/AppleScript-16B-A4B-JANG_4M` and changed visible unsaved TextEdit
from `Hello from OracHQ` to exactly one `Hello again` using one approved
mutation plus one read-only verification, with no Save. The feedback-only turn
produced a plain acknowledgement and no `mac_query`. Detailed source and live
artifacts remain in `docs/AGENT_COMPUTER_USE_APPLESCRIPT_PROOF_2026-07-16.md`.

This slice is **MERGED / VERIFIED-LIVE AT PR #2118**, but it must be replayed on
the current combined head before this new gate can rule out a later regression.

### Still-open rows from the same report

| Row | Status |
| --- | --- |
| Exact replacement and no-save on current `0dfbae5d` | **REVERIFY CURRENT HEAD** |
| Requested Save control | **OPEN** |
| Confirm Each accept/decline, permission denial, cancellation | **OPEN** |
| 8B helper controls | **OPEN** |
| App closed/already open, new document, larger substring replacement | **OPEN** |
| Placeholder `Hello, this is a test` from an open-only request | **OPEN — raw tool route/action/script needed** |
| `Click mark 88` repetition | **GENERIC COMPUTER USE ROW; OPEN** |
| `Missing required property: verb` | **GENERIC COMPUTER USE ROW unless raw history proves otherwise; OPEN** |
| Two independent helper jobs receive only their current job, not prior job or parent transcript | **SOURCE-TRACED / LIVE OPEN** |
| AppleScript/Computer Use/Spawn enablement combinations and parent recovery | **OPEN** |

## Current source seams to trace before editing

1. `ComputerUseTool`/`ComputerUseKind`: permission preflight, model selection,
   nested-run result mapping, and per-step telemetry.
2. `ComputerUseLoop`: full growing transcript, schema re-asks, repeated-action
   detector, localized `open`, action verification, and terminal `done` trust.
3. `AgentAction` plus the Qwen/Gemma native tool parser: raw argument bytes,
   validation envelope, and field-specific feedback.
4. `CapabilityLoadBuffer` plus the chat `AgentToolLoop`: distinguish no call,
   failed call, and successful same-turn load continuation.
5. `AppleScriptLoop`/`AppleScriptToolDispatch`: current-head replay only unless
   a native AppleScript regression is reproduced.
6. `AgentReasoningPolicy`/`ChatTurnGenerationControls`/`MLXBatchAdapter`: explicit
   Off/On must reach every parent and nested tool step without a family-name
   shortcut or hidden sampler/template repair.

## Carry-forward ledger (not closed by this priority PR)

The following remain active. Their detailed evidence lives in the named docs;
this list prevents a narrow priority merge from erasing them.

| Area | Current status / owner document |
| --- | --- |
| Laguna 2L reasoning footer and post-tool Off/On | **VERIFIED-LIVE for Laguna 2L and Ornith MXFP8**, but other families/API/delegation remain partial — `docs/LAGUNA_S21_OSAURUS_LIVE_GATE_2026-07-21.md` |
| Laguna tool selection | **FAILED-LIVE**; unrelated/hallucinated tools — same Laguna ledger |
| Laguna 4M, TQ Off/On, paged-On eviction, memory footprint, cancellation | **OPEN** — same Laguna ledger |
| SSD-only cross-chat/restart partial restore for Laguna/Ornith/Gemma slices | Proven slices exist; all-family, eviction, corruption, toggle-key invalidation, and media/path-dependent companion state remain **PARTIAL/OPEN** — Laguna ledger and `docs/SSD_L2_NEW_CHAT_PARTIAL_RESTORE_GATE_2026-07-21.md` |
| TurboQuant KV | Default must remain Off. Explicit On still needs live topology/coherence/cache-size proof for supported full-KV portions of Gemma rotating-SWA, Qwen 3.5/VL/Ornith/Bonsai hybrid, LFM, MiniMax, Nemotron, and other supported families; DSV4 Flash/OpenPangu exclusions must remain effective — **OPEN MATRIX** |
| RAM safety / user override | Big-model load after user changes the setting, image generation/edit, Spawn/delegation admission, and low-RAM notification remain **PARTIAL/OPEN** |
| Nemotron Nano multimodal image/audio/video/VL | **OPEN** |
| MiniMax JANG/JANGTQ, DSV4 Flash cache/runtime, JANGTQ coherence, MLXPress interference | **OPEN/PARTIAL** per existing runtime ledgers; not part of this Computer Use branch |
| Sandbox uninstall / idle 100% GPU report | **OPEN**; needs current Sentry/source/process trace plus isolated live setup/uninstall/idle proof |
| Sentry crashes | Only individually source-traced and live-reproduced issues may enter this branch; broad crash sweep remains **OPEN** |

## Live acceptance matrix for this gate

Use a fresh Release-config app with a unique bundle id, unique
`OSAURUS_TEST_ROOT`, keychain disabled, and exact `/Users/eric/models`. Operate
only through the real UI and preserve tool feed, visible target-app state,
runtime trace, TTFT/token/s, and physical footprint.

1. Bonsai: Russian Notes prompt, English control, Russian localized app name,
   bundle-id control, approval accept/decline, and permission-denied diagnostic.
2. Bonsai: TextEdit open, create, replace, file read/edit through the correct
   dedicated tools, Calculator, Safari navigation, exact completion once, and
   no post-success mutation.
3. Bonsai Thinking Off and On: every parent and nested Computer Use step,
   including after approval/tool results; no hidden reasoning on Off.
4. Native AppleScript 16B: the two reported replacements, open-only no
   placeholder, create-new-document, feedback-only acknowledgement, requested
   Save control, failure/permission/cancel recovery, and two disjoint jobs with
   no cross-job context.
5. Ability composition: Computer Use only, AppleScript only, both, then Spawn
   before/after; no recursive desktop capability or stale tool choice.
6. Laguna regression control: footer/picker sync, Off/On across tool results,
   switch away/back and app restart, and bundle generation/JANG parameters in
   the effective load trace.

No row is release-ready from this document yet.

## 2026-07-22 final-candidate live findings (Computer Use driven)

Proof environment before the final rebase:

- isolated Release app: `/private/tmp/Osaurus CU Root Final 481d271e 20260722-r5.app`
- bundle id: `com.dinoki.osaurus.curootproof202607220512`
- binary SHA-256: `ae78205a1b16ed36b0f8a7b6b72f01e81cff1a2c20cbcf57c04f5c75f14231ec`
- exact source at build time: `481d271e8c0bb204c0370daec66e3721704618c7`
- exact pinned vMLX revision: `bbbf49e090449bb42f6cde8f50b6f230e3578aec`
- UI settings observed before the rows: Ornith 1.0 9B JANG_4M parent,
  Thinking Off, AppleScript 16B A4B JANG_4M helper, Confirm Each, Keep Warm.
  Accessibility and Screen Recording showed Granted. The isolated bundle's
  Automation card still showed `Not yet granted`; do not generalize the
  successful Finder/TextEdit rows into a claim that every Automation target is
  granted.

Current live rows and what they exposed:

| Scenario | Current evidence |
| --- | --- |
| Whole front TextEdit document -> exact two lines, no save | **PASSED on pre-rebase Release candidate.** Approval showed exactly one direct `set text of front document` using `Aster delta 482` / `Cedar echo 619`, no save, formatting, file, or shell operation. After approval, UI reported success (parent TTFT 1.23s, 99.6 tok/s, 38 tokens); TextEdit visibly contained exactly those two lines and remained `Edited`. Trace recorded `confirm_exact_textedit` and no helper-model step for the mutation. |
| Same exact operation, user declines | **PASSED safety control.** The approval showed only the requested two lines. Decline produced an honest failed/declined row; TextEdit visibly remained `Aster delta 482` / `Cedar echo 619`. |
| Finder name/path with Fast Reads Off and Thinking Off | **PASSED on pre-rebase Release candidate.** UI returned `Laguna-XS.2-JANGTQ` and `/Volumes/EricsLLMDrive/jangq-ai/Laguna-XS.2-JANGTQ/`; AppleScript row 4.4s, parent TTFT 1.49s, 71.9 tok/s, 44 tokens. Trace recorded AppleScript 16B, `disableThinking=true`, `reasoning_chars: 0`, and one read-only `target of front window as alias` script. |
| Same Finder query with Thinking On | **PASSED control, with one recovered model error.** UI showed reasoning before and after the tool and returned the exact same name/path; AppleScript row 12.2s, parent TTFT 1.36s, 75.3 tok/s, 119 tokens. Every helper step recorded `requested_enable_thinking=Optional(true)` and `disableThinking=false`. The first helper script added a needless selection check and failed; the next script recovered read-only. Preserve this as model-quality evidence rather than hiding it. |
| Feedback-only: Finder/TextEdit already succeeded | **PASSED on pre-rebase Release candidate.** Plain acknowledgment in 0.40s TTFT at 67.7 tok/s, 18 tokens. No `mac_query`, time/date query, or fabricated date appeared. |
| Partial replacement inside a larger TextEdit document | **FAILED-LIVE and produced a new source fix.** With `Aster delta 482\nCedar echo 619` open, the request to change only `Aster delta 482` to `Birch nova 305` fell through to AppleScript 16B. Its proposed script contained invalid/generated `text items ... whose item is oldText`; it was declined. The UI showed two failed AppleScript rows and TextEdit remained unchanged. Trace recorded the exact bad script and Thinking-Off dispatch. |

Root cause and current source correction for the newly found partial row:

- The early verified-state path required the entire document to equal
  `oldText`; therefore a valid substring replacement fell back to open-ended
  helper synthesis.
- Rebasing also showed the recognizer accepted `change the text` but not the
  equally valid live wording `change only the text`.
- Current rebased source `fc800bfd2fc815bc9239839b636853c692010387`
  accepts that narrow wording, reads the real document, requires the exact old
  literal to be present, computes the complete expected document in Swift,
  expands it as one escaped data literal, gates one whole-document write, and
  requires an exact OS read-back. It does not force thinking tags, alter
  sampling, or synthesize success.
- The new focused regression
  `partialTextEditReplacementUsesDeterministicWholeDocumentWrite` initially
  failed on the missing `only` grammar, then passed after that correction. A
  current-post-rebase run and current Release UI rerun remain required below.

Final merge gates still pending at this checkpoint:

1. Finish the post-rebase focused and full scoped suites.
2. Build/ad-hoc-sign the exact rebased Release candidate.
3. Repeat the same partial TextEdit prompt through the real UI; approve only a
   single exact whole-document assignment and verify visible exact text,
   unsaved state, no repeat, and honest completion.
4. Audit the final diff against `osaurus/main`, push, open the scoped PR, wait
   for current CI, and merge only after those gates hold.

### Post-rebase closeout evidence

The source and live gates above were repeated after rebasing onto
`osaurus/main` `22308112747f0ca3c34c6cc3e23b438437667bd9`:

- code source: `fc800bfd2fc815bc9239839b636853c692010387`
- isolated Release app:
  `/private/tmp/Osaurus CU Root Final fc800bfd 20260722-r6.app`
- bundle id: `com.dinoki.osaurus.curootproof202607220512`
- binary SHA-256:
  `a5272c4a334df626caba19e7d79193414966ddbd262a923b1ec567252998e292`
- ad-hoc signature: `codesign --verify --deep --strict` accepted the app.
- exact pinned vMLX revision:
  `bbbf49e090449bb42f6cde8f50b6f230e3578aec`

Post-rebase Computer Use proof:

1. The real UI visibly showed Ornith Thinking **Off** and accepted the exact
   same partial-replacement prompt that had failed on the prior candidate.
2. The approval sheet contained exactly one script:
   `tell application "TextEdit" to set text of front document to "Birch nova 305\nCedar echo 619"`.
   It contained no save, `changed=false`, formatting, file, shell, or repeated
   action.
3. After UI approval, Osaurus reported success (AppleScript feed 37.0s including
   the approval wait; parent TTFT 1.32s, 71.8 tok/s, 32 tokens). TextEdit visibly
   contained exactly `Birch nova 305\nCedar echo 619` and its title still showed
   `Edited`.
4. Trace lines 335-336 contained only the exact dispatch context and
   `decision=confirm_exact_textedit`; there was no helper-model generation step,
   correction loop, or second execution for this run.
5. A fresh feedback-only chat message received a plain acknowledgment at 0.38s
   TTFT / 70.7 tok/s / 21 tokens. The AppleScript trace line count stayed at
   336, proving that this acknowledgment did not invoke `mac_query` or the
   AppleScript helper; no fabricated date appeared.

Post-rebase source verification:

- result bundle:
  `/private/tmp/osaurus-cu-final-scoped-rebased-20260722.xcresult`
- 277 passed, 0 failed, 0 skipped across AppleScript classification/loop/schema/
  routing/knowledge/executor suites, Computer Use evidence/background/act/model/
  recipe suites, subagent session and chat-turn reasoning-control suites, and
  runtime-policy source checks.
- `git diff --check` passed.
- The final implementation diff remains scoped to the vMLX pin and Computer
  Use/AppleScript routing, permission/error mapping, verified completion,
  reasoning propagation, tests, and evidence. It contains no Laguna/Gemma/cache/
  TurboQuant/MLXPress implementation change.

At this point local source and live gates for this scoped PR are satisfied.
Remote PR CI and the merge itself remain pending; this document does not claim
a release or close any carry-forward matrix row above.

### PR CI pin-contract correction

The first PR #2131 CI run (`29924637680`) completed seven checks successfully
but failed `test-core` in `ImageGenerationBridgeContractTests`. The four
recorded expectations still hard-coded the previous vMLX revision
`a3b047e05871e1271fc86d2ef0ab2f8270aa832f`, while this PR intentionally moves
`Package.swift` and all three resolved files to the merged, live-proven revision
`bbbf49e090449bb42f6cde8f50b6f230e3578aec`. The image bridge, route, and Metal
gate assertions in the same test continued to pass; this was a stale exact-pin
source contract, not a live image-generation failure. The contract now checks
the same `bbbf49e` revision as `RuntimePolicySourceTests` and the four package
manifests. A focused local rerun and a fresh full PR CI run are required before
merge; no runtime source changed for this correction, so the exact Release UI
evidence above remains the current runtime proof.
