# Agent, Computer Use, and AppleScript 8B Proof Ledger

Last updated: 2026-07-20 (America/Los_Angeles)

## Newly reported release-critical regressions (2026-07-20)

These reports are tracked separately even though they arrived during the same
emergency lane. A successful AppleScript row must not be used to close the
Sandbox/GPU report, and an idle-GPU row must not be used to close the
AppleScript completion report.

### Idle 100% GPU after incomplete Sandbox uninstall

Reported environment: Osaurus 0.22.7 on an M5 MacBook Air with 24 GB RAM. The
user installed a 2-core/2-GB Sandbox after several attempts, then attempted to
uninstall it. The UI returned to the setup screen but continued to show four
provisioning findings: `setup_incomplete`, missing kernel, missing init
filesystem, and missing warm-restart rootfs. With Osaurus open and no user
task running, the user's monitor attributed approximately 98.6% GPU to
Osaurus, with overall GPU at 99% and 77 C in the supplied screenshot.

This is **OPEN / UNVERIFIED LOCALLY**. The screenshot proves the reported
process attribution and visible incomplete state on that machine; it does not
yet identify Sandbox as the producer. The investigation must distinguish:

- an unintended model load, warmup, decode, media/privacy inference, or cache
  maintenance task owned by Osaurus;
- Sandbox provisioning, boot, health polling, retry, teardown, download, or
  migration work that survives navigation/uninstall/relaunch;
- a leaked or uncancelled Metal task after a previous request;
- UI rendering/animation versus actual MLX/Metal command submission;
- an external VM/helper process versus work charged to the Osaurus process;
- an environmental/security-tool installation failure versus an Osaurus
  lifecycle bug. BlockBlock/RansomWhere interaction is a hypothesis only and
  must not be blamed without an event/process trace.

Required Release-app matrix:

| State transition | Visible operation | Required evidence and pass condition |
| --- | --- | --- |
| Clean isolated root, no Sandbox assets | Launch Osaurus and remain on chat, then open the Sandbox setup screen without pressing Setup | Process CPU/GPU and Metal/MLX trace remain idle; no model, VM, provisioning, download, or retry starts |
| Incomplete asset state | Reproduce each writable-parent/missing-child finding in an isolated root and relaunch | The UI reports the missing assets honestly but does not provision, boot, or spin until the user explicitly starts setup |
| Setup cancellation/failure | Start setup, cancel/close/quit at download, unpack, configure, and boot boundaries | Every child task and progress poll cancels; relaunch is idle and offers an explicit resumable/retry state |
| Installed but stopped | Complete setup, leave Sandbox unused, navigate away, quit/relaunch | No VM or plugin daemon starts merely because assets exist; GPU stays idle |
| Running then stopped | Start a bounded Sandbox job, stop it, uninstall/clear assets, relaunch | VM/helper/model work terminates; no orphan process, timer, GPU command producer, or stale `setupComplete` state remains |
| Model interaction control | Load and unload one local non-MXFP4 model, then return to idle with Sandbox incomplete | Any GPU activity is attributable to the explicit model task and returns to baseline afterward; Sandbox state does not retain model residency |

Source review must inventory every task launched from `SandboxView`,
`SandboxManager`, provisioning/runtime asset stores, plugin daemons, host
bridges, model warmup/residency, privacy/media services, and app launch hooks.
Tests must cover cancellation and idempotent teardown, but the issue cannot be
closed without the real Release UI and process/GPU observation. A guard that
merely hides the setup screen, suppresses warnings, or throttles GPU use is not
an acceptable fix.

Current source trace found a real lifecycle race, but not a proven GPU root
cause. `SandboxView.performProvision()` starts an untracked view-owned `Task`
that directly awaits `SandboxManager.provision()`. The manager separately
tracks `prefetchTask` and `inFlightStartTask`; `removeContainer()` calls
`stopContainer()` and deletes the asset roots, but it neither cancels nor
awaits the prefetch task or the direct provisioning operation first. A Remove
can therefore race setup/prefetch writes and leave the exact mixed state the
reporter saw. The missing kernel/initfs/rootfs findings themselves are expected
after a full Remove and do not prove a VM is still running.

The candidate now coalesces every explicit `provision()` behind an owned
`inFlightProvisionTask`. Remove marks the sandbox removed first, cancels the
prefetch/provision/start tasks, and awaits all three before stopping the VM or
deleting any asset. `SandboxManagerCleanupTests` includes a hermetic suspended-
task regression proving all three tasks are cancelled, awaited, and cleared;
the selected suite passed 5/5. This is **SOURCE/TEST ONLY** until a Release UI
run visibly exercises setup/remove/relaunch and inspects the resulting files,
processes, and GPU state.

In the current isolated Release control, the warm 16B model remained resident
but no generation was active: shell sampling showed the proof-app process at
approximately 0.9% CPU and 1.72 GB RSS. Activity Monitor's current Energy view
showed Warp and AnyDesk as the large consumers, while it did not list the
custom-bundle proof process in its `% GPU` search. Global AGX utilization was
therefore not attributable to Osaurus. This is insufficient to close the
report. The isolated proof launch also used keychain-disabled test mode, and
`AppDelegate` deliberately skips `SandboxToolRegistrar.start()` in that mode;
it cannot prove the production auto-start/prefetch lane idle. The lifecycle
race still needs a cancellation-safe fix and a visible setup -> remove ->
relaunch matrix with per-process GPU evidence in a safely isolated launch that
does not skip the registrar.

### TextEdit replacement repeats and unrequested Save (0.22.7)

The exact reported prompts are:

1. `Change the text in the file from “Hello from OracHQ” to “Hello again”.`
   The reported result was four concatenated copies of `Hello again`, followed
   by `Failed: Computer use`.
2. `Change the text in the file from “Hello World” to “Hello from OracHQ”.`
   The edit succeeded, but the agent entered an unrequested Save workflow and
   ultimately marked the task failed.

This report remains **PARTIAL**. Earlier patched-Release evidence in this
ledger proved the older action-only finalization and feedback-only regressions,
including a successful TextEdit activation and no unrelated `mac_query` for
the exact feedback sentence. Those prior rows do not prove the new exact-text
replacement prompts. The current candidate's explicit-TextEdit control wrote
`Hello again` once and remained visibly unsaved, but the exact anaphoric prompt
failed before execution because the helper was not told that TextEdit was the
working app. The working-app handoff is now source/test-covered and awaits the
rebuilt Release rerun.

The report's terminal label is `Failed: Computer use`; the initial 2026-07-20
reruns mistakenly exercised the separately configured native `applescript`
tool and therefore do not reproduce the owning loop. The real Computer Use
path is `ComputerUseKind` -> `ComputerUseLoop` with the forced `agent_action`
schema, native accessibility driver, action gate, and post-action observation.
The native path is `AppleScriptKind` -> `AppleScriptLoop` with
`run_applescript` and script confirmation. Both must be tested because the
same specialized models can expose related behavior, but their evidence is
not interchangeable.

The live UI also exposed an apparent settings mismatch: dedicated AppleScript
models are present in the native AppleScript picker but excluded from the
generic Computer Use override picker. A temporary candidate added them only
to the Computer Use picker, then the Release UI disproved that route: the
selected 16B bundle loaded, received Computer Use's forced `agent_action`
schema, emitted two invalid action envelopes, and then omitted the required
tool. No TextEdit mutation occurred. The candidate was reverted. Dedicated
AppleScript bundles remain selectable only for the native `run_applescript`
ability and remain excluded from ordinary chat, Spawn, and Computer Use. This
failed route must not be presented as a picker regression or as evidence for
the reported `Failed: Computer use` path.

Required behavioral matrix for both JANGQ 8B JANG_6M and 16B A4B JANG_4M:

| Scenario | Pass condition |
| --- | --- |
| Exact first prompt through Computer Use, whole document equals old text | One replacement only; document is exactly `Hello again`; one successful completion; no retry or Save |
| Exact second prompt, whole document equals old text | One replacement only; document is exactly `Hello from OracHQ`; document remains unsaved/Edited; no Save workflow |
| Old text is a substring in a larger document | Only matching occurrences change as requested; prefix/suffix and whitespace remain byte-correct; no duplicated replacement |
| Old text is absent or document/app is missing | No mutation and no fabricated success; one grounded, recoverable result or bounded failure |
| User explicitly requests Save | Edit and Save occur once, with the correct confirmation/effect classification and visible file state |
| Confirm Each accept, decline, and cancel | Accept executes once; decline/cancel never mutates and never retries as though approval had succeeded |
| Same prompt repeated as a new user turn | Each turn is independently correct; helper context contains only that job; no stale script, literals, target, or completion state crosses turns |
| Feedback-only turn after success | Plain acknowledgement only; no AppleScript, Computer Use, `mac_query`, date/time invention, Save, or stale forced tool choice |
| Cold, exact-prefix, partial-prefix, and SSD-only restore | The same valid script/one-mutation result under every cache condition; trace identifies the actual hit tier and any required hybrid-state rederive |
| Prefix/disk cache disabled through visible Settings | Same semantics without reuse; changing the toggle affects the next request and restoring it restores the prior effective policy |
| Same prompts through native AppleScript | Record separately from Computer Use; one valid script/mutation and no Save, but never use this row to close a `Failed: Computer use` reproduction |

The owning layer must be identified per failure. Candidate causes include the
parent's committed tool arguments, working-app snapshot, helper prompt/recipe,
helper model proposal, confirmation/execution result, completion classifier,
outer parent continuation, and cache restore. Incremental content/tool previews
must not be blamed when the committed invocation is complete. Likewise, cache
reuse must not be blamed when the cold request already lacks target/literal
context. Every live row must retain the tool cards and trace needed to tell
these boundaries apart.

### Global regression questions for both fixes

- Does any working-app fallback leak TextEdit knowledge into named-app,
  information-only, background-app, or unrelated new-chat tasks?
- Does stopping after a successful mutation accidentally stop a required
  readback, a true multi-step task, a failed execution, or a requested Save?
- Can either the parent or helper execute a second mutation after success due
  to cached output, a stale tool choice, a delayed stream delta, or an outer
  agent-loop retry?
- Does every helper job start from only its newest task/desktop/literal context
  while retaining tool results only inside that one job?
- Do explicit UI choices for helper model, confirmation, reasoning, cache,
  residency, and Sandbox state reach the exact next runtime request and persist
  only where documented?
- After cancel, failure, navigation, app quit, model unload, Sandbox stop, and
  Sandbox uninstall, are all model/Metal/VM/provisioning tasks actually gone?
- Do Gemma, Qwen-derived Ornith/Bonsai, LFM, Spawn, Computer Use, native
  AppleScript, and ordinary chat retain their own reasoning/tool/cache defaults
  rather than inheriting an AppleScript-specific behavior globally?

## Reopened JANG_6M acceptance lane (2026-07-17)

The earlier merge is not final acceptance for the two AppleScript 8B reports.
It proved the bounded `agent_action` protocol re-ask, parent-chat failure
containment, and feedback-only tool-selection guard, but it did not complete a
successful AppleScript-8B-as-Computer-Use action. This lane is reopened on exact
current `origin/main` with the following non-negotiable scope:

- Do not download, load, compare, or draw conclusions from MXFP4. The primary
  helper is the installed
  `/Users/eric/models/OsaurusAI/Osaurus-AppleScript-8B-JANG_6M`; the byte-identical
  `/Users/eric/models/JANGQ-AI/AppleScript-8B-JANG_6M` mirror is inventory only.
- Configure the real development app through visible Settings and agent UI.
  Source tests, evaluator runs, and API calls are supporting evidence only.
- A reported-success row passes only when the requested macOS state is visibly
  achieved, the helper emits the terminal completion contract, the parent does
  not display `The model did not produce a valid required tool call`, and the
  UI records token/s.
- Reproduce both reports in sequence: complete two real actions, then send the
  exact feedback sentence and require a plain acknowledgement with no tool row.
- No prompt keyword classifier, forced sampler, synthetic closer, parser
  masking, hidden model reroute, or output-cap workaround is allowed.

### Required live matrix

| Group | Scenarios | Pass condition |
| --- | --- | --- |
| Settings and persistence | Select JANG_6M for Computer Use and AppleScript; toggle each ability; Confirm Each; Fast Reads; Keep Warm; quit/relaunch | Visible selections persist and the runtime feed names the selected helper rather than a fallback |
| Reported Computer Use successes | Open TextEdit; open Calculator; open Safari and navigate to a harmless local/Osaurus page | Each requested app/state is visibly correct and the same turn ends once with a grounded success, no required-tool failure |
| Completion variants | App closed vs already open; one-step open; multi-step open+type/navigation; repeat action in same chat; helper plain-text-after-action; explicit `done` | No duplicate action, contradictory failure, blind retry, or post-success loop |
| Exact feedback regression | After two successes, send the quoted feedback sentence; repeat in fresh chat and paraphrased acknowledgement-only turns | Plain acknowledgement only; no `mac_query`, AppleScript, Computer Use, date/time invention, or other tool |
| Requested reads and failure grounding | Explicit current date/time request; front-app/title read; nonexistent app; compile/runtime failure; timeout; user denial/cancel | Requested reads use real state; failures report the returned error and never fabricate a value or launch an unrelated fallback |
| Ability routing | Computer Use only; AppleScript only; both enabled; Fast Reads on/off | The selected tool matches the request and its configured model path; no stale tool choice crosses turns |
| Multi-turn and recovery | Success -> feedback -> success; failure -> corrected request; cancel -> new request; stop during generation -> retry | History remains coherent, tools remain available, and no orphaned feed/model residency remains |
| Spawn/delegation boundary | Spawn before/after AppleScript; target with subagent toggles; disabled target; missing/denied target; parent resumes AppleScript | Spawned children do not receive recursive Computer Use/AppleScript schemas; parent tools remain usable and no inherited scope/tool-choice leaks |
| Resource behavior | Cold/warm helper load, unload/reload handoff, Keep Warm expiry, stop cleanup, visible Activity Monitor footprint | Model identity, token/s, residency transitions, and physical footprint are recorded; no concurrent double-residency or zombie load |

### Initial current-main source trace

- `ComputerUseKind` can run on a per-agent model override and forces the single
  strict `agent_action` schema. AppleScript 8B is native-trained for
  `run_applescript`, so its generalization to `agent_action` must be proven live
  rather than inferred from the model name or catalog placement.
- `ComputerUseLoop` now maps only exact `OsaurusToolChoice` code 422 into its
  bounded corrective re-ask. That is source/test coverage for the reported
  finalization miss, not live proof that JANG_6M emits a valid terminal `done`.
- `AppleScriptLoop` uses `tool_choice: auto`, not required, and accepts a
  no-tool plain-text terminal response. Therefore the reported exact required-
  tool error points to the Computer Use `agent_action` path, not the native
  `run_applescript` loop.
- Spawned text children intentionally exclude every subagent capability
  (`computer_use`, `applescript`, `mac_query`, image, and nested spawn) from the
  child schema. The adjacent acceptance target is boundary correctness and
  parent recovery, not recursive desktop automation from the child.

### Current-main live setup evidence

- Exact source is current `origin/main` `4b96ae0ab8b3bc0d9c08315a1f138c7802fc0d50`.
  The first isolated Release build completed, was ad-hoc signed, and passed
  `codesign --verify --deep --strict`; its initial executable SHA-256 was
  `9c57bcc31f73579f486ddf68b4a5255fc687ae56c82bc70db14678a2bbdcf980`.
- Through the fresh onboarding and real agent Settings UI, the parent was set
  to `Ornith-1.0-9B-MXFP8`; Computer Use was enabled with
  `AppleScript 8B JANG_6M`; screen context was turned off; and the separate
  AppleScript ability was enabled with `Osaurus AppleScript 8B JANG_6M` plus
  Confirm Each. A quit/relaunch visibly preserved all of those selections.
  This proves persistence only, not that either runtime route used the model.
- The new proof bundle identity remained `Accessibility: Not Granted` even
  after it was added to the visible Accessibility list and relaunched. Adding
  a newly named client then surfaced macOS's Touch ID/password authorization
  sheet. No credential was requested, entered, or automated. Computer Use
  action rows therefore remain blocked on that identity.
- Current main is being rebuilt under the already-authorized proof-only
  `com.dinoki.osaurus.bonsai2041proof` identity shown enabled as
  `Osaurus Bonsai PR2041 Proof` in System Settings. Production Osaurus
  permissions and preferences are not being removed or toggled. That rebuild
  must still show `Accessibility: Granted` in the app before it can supply any
  Computer Use pass evidence.

### Native JANG_6M reproduction on current main (2026-07-17 20:53-21:01 PDT)

The first native-AppleScript row used the exact current-main Release executable
SHA-256 `61087eb8033b8aedc20aacf9dbe6b32d167be638e8d4ee23d48fc25691783ecb`,
bundle id `com.dinoki.osaurus.bonsai2041proof`, app path
`/private/tmp/Osaurus-AppleScript-JANG6M-Current-Main.app`, and isolated root
`/tmp/osaurus-applescript-jang6m-authorized-root-20260717-204905`. Visible
Settings selected parent `Ornith-1.0-9B-MXFP8`, enabled only the AppleScript
subagent, selected `Osaurus AppleScript 8B JANG_6M`, and kept Confirm Each on;
Computer Use and Spawn were off. A new chat visibly switched the parent from
the onboarding Gemma session to Ornith MXFP8 before the prompt was sent.

`Open TextEdit` produced a valid `run_applescript` call, but the script did more
than requested: it activated TextEdit and created a new document containing the
unrelated text `Beginning of text fit until margin`. After approval, live
TextEdit visibly showed that exact untitled document, proving the script really
executed. The AppleScript run did not finish. It presented the same mutating
confirmation again and, after that repeat was declined, generated a third,
different mutating TextEdit script that would create more unrelated content.
Stopping the run produced a red `Failed: Applescript` row with the canonical
`user_denied` result. The unsaved TextEdit window was then closed.

The owning source is `AppleScriptLoop.swift`: after recording a successful
execution, lines 977-992 short-circuited only `mac_query` with a non-empty
return value; automate mode always fed the success back for another helper-model
turn. That exactly explains a real action followed by repeat/failure. The local
candidate now terminates a successful action-only automation from the real
execution record; data-bearing tasks with no returned value retain the read-back
path, and execution failures retain correction/retry. No parser repair, sampler
override, prompt classifier, synthetic tool call, or model reroute was added.

Focused source proof is **PASS**: the new repeating-JANG regression executes
and confirms exactly once, and the complete `AppleScriptLoopTests` suite passes
through the workspace Xcode scheme. The first focused result bundle is
`/tmp/osaurus-applescript-jang6m-tests-dd/Logs/Test/Test-OsaurusCoreTests-2026.07.17_21-04-59--0700.xcresult`;
the full-suite rerun completed at 21:09 PDT. This is not yet patched-app live
proof; the Release candidate is still rebuilding.

### Exact-text success followed by malformed parent repeat (2026-07-17 21:39 PDT)

The isolated live app then reproduced a second, outer-loop failure with the
installed JANG_6M helper. The real-user prompt was `Use the native AppleScript
helper to create a new unsaved TextEdit document containing exactly JANG6M LIVE
PROOF and nothing else.` The first parent call included the required `task`
with the exact value in that instruction; JANG_6M updated a real unsaved
TextEdit document to exactly `JANG6M LIVE PROOF`; and the first tool envelope
was a grounded success with
`status:succeeded`, `scripts_run:1`, and summary `Done. Result: TextEdit
document updated with JANG6M LIVE PROOF.` The helper generated at 43.5 tok/s.

Despite that success, the parent immediately emitted a second `applescript`
call omitting required `task`. The model's persisted reasoning said it should
use the `content` parameter, but vMLX's canonical invalid envelope replaces the
malformed raw arguments, so the presence of a raw `content` field is not
claimed. vMLX correctly returned `_error:invalid_tool_arguments`,
`_tool:applescript`, and `_field:task`; the
chat displayed that failure and the parent proposed a third redundant call.
The run was stopped before the duplicate mutation executed. The durable trace
is session `D089CA3C-1190-4C64-B02B-589A64784F08`, sequence 12-16, in
`/tmp/osaurus-applescript-jang6m-authorized-root-20260717-204905/chat-history/history.sqlite`.
The Insights response at 21:39:14 showed the same canonical invalid envelope.

This is **not** content-delta assembly. `ModelRuntime.streamWithTools` consumes
the committed vMLX `.toolInvocation(name,argsJSON)` and converts that complete
argument JSON into `ServiceToolInvocation`; `ChatView` catches that committed
invocation directly. Its incremental argument fields are only a preview. At
pinned vMLX revision `a26c7ecec950f18e3d07c8402fbd8c80f40ac764`,
`XMLFunctionParser.schemaValidationFailure` owns the exact missing-required-field
envelope. The live compact system prompt and persisted model reasoning exposed
the actual contract mismatch: compact guidance recommended `content` but did
not repeat that `task` remains required, and the model reasoned that it should
use the tool "with the `content` parameter."

The current candidate fixes both owning boundaries without repairing arbitrary
JSON or inventing output:

- compact guidance now shows `applescript(task=..., content=...)` and states
  that `task` remains required with `content` or `contents`;
- if and only if the very next chat step repeats the same desktop tool with
  vMLX's exact missing-primary-field envelope after a real successful envelope,
  the UI finishes from that immediately preceding non-empty real summary and
  does not execute or display the duplicate mutation;
- mismatched prior tools, empty summaries, other required fields, unrelated
  tools, API/headless surfaces, and other invalid arguments keep their existing
  error behavior.

Current source proof is **PASS**: after rebasing onto `origin/main`
`39a764a52`, 66/66 focused tests passed at 23:08 PDT in
`/tmp/osaurus-applescript-jang6m-tests-dd/Logs/Test/Test-OsaurusCoreTests-2026.07.17_23-08-12--0700.xcresult`.
The selected suites cover the external-folder availability gate, action-only
stop, exact-content readback, exact outer malformed repeat, mismatched-success
negative control, and compact tool guidance. `git diff --check` is also clean.

### Final patched Release live evidence (2026-07-17 22:18-22:58 PDT)

The final candidate is the ad-hoc signed Release app
`/private/tmp/Osaurus-AppleScript-JANG6M-Current-Main.app`, bundle id
`com.dinoki.osaurus.bonsai2041proof`, isolated root
`/tmp/osaurus-applescript-jang6m-authorized-root-20260717-204905`, exact vMLX
revision `a26c7ecec950f18e3d07c8402fbd8c80f40ac764`, and executable SHA-256
`b6cfa6807de1d388586e06d729c414a048b56a7493fb71178fa4552a7c338980`.
Its CDHash is `825f5eec5b6e77acbc2f33eccbd558636b6f888b`; deep/strict ad-hoc signature
verification passed. The app was operated through visible UI only for the
rows below. No MXFP4 bundle was downloaded, loaded, or used.

After the final rebase, the Release app was rebuilt from the rebased source,
copied, ad-hoc sealed, and deep/strict verified again. Its executable SHA-256
was exactly the same
`b6cfa6807de1d388586e06d729c414a048b56a7493fb71178fa4552a7c338980`
as the visually exercised candidate. This is byte identity, not an inference
that the upstream appcast-only commit could not affect the binary.

Visible Settings selected parent `Ornith-1.0-9B-MXFP8`, enabled Computer Use
and Spawn, allowed only local Ornith for Spawn, enabled AppleScript, selected
`Osaurus AppleScript 8B JANG_6M`, and selected Confirm Each. Toggling
AppleScript off hid its controls; toggling it back on restored JANG_6M and
Confirm Each. After quitting and relaunching the exact executable with the
same isolated root, all of those selections persisted. Models visibly listed
AppleScript JANG_6M and Bonsai 1-bit as downloaded from the custom model
folder. The live helper feed named
`OsaurusAI/Osaurus-AppleScript-8B-JANG_6M`, and the first load mapped all eight
safetensor shards from `/Users/eric/models/OsaurusAI/Osaurus-AppleScript-8B-JANG_6M`.

Live rows on this exact candidate:

- **PASS -- TextEdit activation:** the approval sheet showed only
  `tell application "TextEdit" to activate`; TextEdit visibly became frontmost.
  The tool returned `ok:true`, `status:succeeded`, `scripts_run:1`, one
  successful step, and `Ran 1 script(s) successfully.` JANG_6M generated at
  47.3 tok/s; the parent completed at 54.2 tok/s. No duplicate, malformed call,
  required-tool failure, or contradictory failure appeared.
- **PASS -- already-open correction:** JANG_6M first proposed the semantically
  wrong `System Events` activation. Confirm Each exposed it and the user
  declined. The model then produced the correct TextEdit activation; it ran
  once and returned `ok:true`, `status:succeeded`. JANG_6M generated at
  44.2 tok/s and the parent at 52.0 tok/s. This is a model-proposal defect with
  a working user-safety/correction path, not a parser repair.
- **PASS -- exact reported feedback:** after successful actions, the exact
  sentence `For your information, both TextEdit and Calculator did open
  successfully, it seems AppleScript did not report back to you correctly.`
  received a plain acknowledgement at 66.2 tok/s. No `mac_query`, AppleScript,
  Computer Use, date invention, or other tool row appeared.
- **PASS -- spawn boundary and parent recovery:** a bounded local Spawn request
  returned exactly `DELEGATED` in 5.0 seconds; the same parent then called the
  native AppleScript helper, ran one correct TextEdit activation, and completed
  with `ok:true`/`status:succeeded`. JANG_6M generated at 43.6 tok/s and the
  parent at 66.7 tok/s. Parent AppleScript remained available after delegation.
- **PARTIAL -- explicit current-time request:** the builtin current-time tool
  grounded the correct local date/time, but the parent redundantly called
  `mac_query`. The Fast Reads Ornith helper then made one successful read
  followed by seven bad/time-out proposals before its step limit. The parent
  used the builtin result and did not fabricate a value. Correctness passed;
  redundant tool selection and helper efficiency did not.
- **MODEL FAIL, HOST SAFETY PASS -- exact content:** the first JANG_6M script
  correctly wrote `JANG6M FINAL READBACK PROOF`, visibly confirmed in TextEdit.
  Because a mutating script's own return is not independent verification, the
  host required a readback. JANG_6M instead repeated the identical write, then
  proposed a nonsensical System Events script after the duplicate was declined.
  Confirm Each exposed both; neither was auto-run, and Stop ended the row. This
  is reproducible semantic/repetition behavior from the selected model after a
  correct schema call. It is not counted as a host success and is not hidden by
  a synthetic closer, automatic read, parser coercion, or false completion.

The content/schema attribution is source- and runtime-grounded. vMLX
`XMLFunctionParser.schemaValidationFailure` creates the exact
`invalid_tool_arguments` envelope for a missing required field. Osaurus then
maps the committed `.toolCall` to a complete `.toolInvocation(name,argsJSON)`;
`ModelRuntime.streamWithTools` constructs the executable invocation only from
that committed JSON. Incremental `toolCallProgress` is explicitly a native UI
preview and is not dispatched. Therefore the observed missing-`task` repeat
was a model/schema contract miss after a real success, not content-delta
assembly. The final exact-content model failure used a valid outer
`applescript(task,content)` call and valid first inner script, further excluding
either streaming layer as its cause.

Overall verdict for this follow-up: **PARTIAL BY MODEL, MERGEABLE FOR THE
NARROW HOST FIXES AFTER CI.** The external-folder gate, action-only success
finalization, feedback-only behavior, post-success malformed-repeat containment,
settings persistence, Spawn boundary, and TextEdit state changes have current
source plus final Release UI evidence. JANG_6M is not claimed reliable for
arbitrary multi-step or exact-content automation, and AppleScript 8B is not
claimed compatible with Computer Use's distinct `agent_action` contract.
Calculator/Safari Computer Use, proof-identity Accessibility, Activity Monitor
peak physical footprint, and the broader RAM/cache/routing matrix remain
unproven or blocked and are not claims of this urgent patch.

## Scope and proof rules

- Runtime bundles come only from `~/models` (`/Users/eric/models`).
- Do not download, load, benchmark, or infer behavior from MXFP4 in this lane.
- Use the installed AppleScript 8B JANG_6M bundle for Computer Use proof:
  `/Users/eric/models/OsaurusAI/Osaurus-AppleScript-8B-JANG_6M`.
- A source row and a focused unit test are not live proof. Live claims require
  the exact Release candidate, an isolated bundle id and app root, visible UI
  settings, real model load/generation, and recorded output, token/s, physical
  footprint, and relevant tool/cache telemetry.
- Do not add forced prompts, hidden sampler overrides, parser repair, synthetic
  closers, silent output caps, or other behavior masking.
- Preserve unrelated vMLX and Osaurus work. The broad routing/hardware-guidance
  PR is not part of this follow-up.

## Current matrix

| Priority | Reported or adjacent row | Source status | Focused test | Live visual status |
| --- | --- | --- | --- | --- |
| P0 | Direct Calendar Agent has its enabled calendar/plugin tools | Direct-agent scoping resolved the installed `osaurus.calendar` plugin through the live registry | Existing focused suite does not cover the installed plugin | **PASS (VISUAL):** custom Calendar Agent pinned to `gemma-4-12B-it-MXFP8`, Browser disabled, Calendar 4/4 assigned; live UI showed failed typo recovery, capability discovery/load, `Get events`, grounded empty result, TTFT 0.97s, 31.2 tok/s, 34 tokens |
| P0 | `spawn_agent` child inherits the target Calendar Agent's own tool policy | **ROOT CAUSE REPRODUCED AND LOCAL FIX LIVE-VERIFIED:** child request receives target schemas, but registry execution inherited the parent request's `ToolExecutionScope`; local patch publishes a child scope from the exact child schemas | **PASS:** all 13 `SpawnToolsetTests`, including `agentToolDispatchUsesChildExecutionScope`, passed in the focused Xcode run | **PASS (VISUAL, PATCHED):** after the registry exposed Calendar 4/4, two spawned MXFP8 rows completed with grounded Calendar results; the original “not available in this conversation” rejection did not recur |
| P0 | Direct vs spawned Calendar tool schema, exact JSON arguments, tool result, continuation, second call | Direct runtime log captured valid JSON `{"ids":["plugin/osasaurus.calendar"]}` followed by structured `not_found` and recovery; patched child debug traces showed 15 exact schemas while parent had 9 | **PASS:** focused scope regression and 12 neighboring spawn tests | **PASS (VISUAL, TWO TURNS):** 2099-01-01...02 returned no events; same-chat 2099-01-03...04 returned a real Birthdays event. Parent rows were 31.2 and 39.3 tok/s; child rows were 31.3 and 31.7 tok/s |
| P0 | Installed plugin survives isolated-app relaunch and is registered before agent use | **ADJACENT RISK FOUND:** `ToolsPaths.root()` ignores `OSAURUS_TEST_ROOT`, while the keychain-disabled app deliberately skips startup plugin loading | NOT RUN | **FAIL/PARTIAL:** Calendar remained installed on disk and visible in Settings, but the first post-relaunch child had only 11 schemas and omitted Calendar 4/4 until the user pressed Plugins -> Refresh; the first generation immediately after hot-load then stalled for 112.3s and was stopped, while the next two stable-registry runs passed |
| P0 | Computer Use can leave the last-viewed window and visibly switch to another app | ADDRESSED IN SOURCE ON MAIN by PR #2032 (`69726a371`); `ComputerUseLoop.swift:1008` calls the driver with `background: false` | `ComputerUseEvidencePackTests.testOpenVerbLaunchesForegroundSoTheWindowIsVisibleAndVerifiable` PASS through Xcode | NOT RUN; reported stale-window behavior not yet reproduced or cleared |
| P0 | Computer Use returns to the original app and continues multi-step work | Source audit pending | NOT RUN | NOT RUN |
| P0 | AppleScript 8B appears under Settings -> Computer Use -> Models | ADDRESSED IN SOURCE ON MAIN by PR #2046 (`504d174ab`); `AppleScriptModelCatalog.swift:82,101-106` names the installed 8B bundle | Existing catalog/search tests still to identify and rerun | **PASS (VISUAL DISCOVERY ONLY):** Settings -> Computer Use -> Models displayed installed Osaurus AppleScript 8B (7.95 GB); 16B was available but not installed |
| P0 | AppleScript 8B JANG_6M selects, loads, warms, and executes real Computer Use | Local bundle and Zaya/JANG path resolve through the shared local runtime; Computer Use requires strict named `agent_action` rather than the bundle's native `run_applescript` specialization | Protocol re-ask and terminal-envelope tests PASS; no model-coherency unit fixture | **PARTIAL/FAIL:** the UI selected and generated with JANG_6M, but Computer Use returned an invalid `verb`; a dedicated `mac_query` generated scripts but hit permission timeouts/compile/runtime errors. Load/selection is proven; successful execution is not |
| P0 | A successful AppleScript 8B Computer Use action must finish without `The model did not produce a valid required tool call` | **ROOT CAUSE TRACED:** `ChatEngine` fails closed on missing named tool choice before `ComputerUseLoop` can treat the miss as `nil` and issue its bounded `agent_action` re-ask. Local candidate routes only `OsaurusToolChoice`/422 through that existing re-ask and bypasses blind same-prompt inference retries | **PASS:** exact protocol-error regression plus the neighboring `ComputerUseLoopRunTests` passed through Xcode | **BLOCKED (PATCHED RELEASE):** JANG_6M returned an invalid `verb`; JANG_4M visibly reached `Model did not call agent_action`, entered the bounded corrective re-ask, then timed out. Neither performed the action, so successful-action finalization is not claimed |
| P0 | A feedback-only turn must acknowledge the user without inventing `mac_query` for date/time | **SOURCE TRACE:** normal chat resolves `.auto` from the current feedback text; no stale forced choice is present. The broad `mac_query` description permitted an unrelated model-selected read. Candidate schema/full/compact guidance binds selection to the current request without a keyword classifier | **PASS:** `AppleScriptToolSelectionGuidanceTests` and terminal-`mac_query` loop regression passed through Xcode | **PASS (PATCHED RELEASE, 3/3):** the exact reported sentence received acknowledgement-only replies at 62.7, 61.3, and 62.0 tok/s; no `mac_query`, AppleScript, Computer Use, or other tool row appeared |
| P0 | A failed non-retryable `computer_use`, `applescript`, or `mac_query` must not launch another action or fabricate a value | **ROOT CAUSE LIVE-REPRODUCED:** subagent tools return canonical `ok:false` JSON rather than throwing, while Chat's `AgentLoopToolExecution.isError` remains false. `stopOnToolRejection` therefore never fires. Candidate recognizes only non-retryable terminal desktop-subagent failures; `invalid_args`, `not_found`, and unrelated tools retain pivot behavior | **PASS:** serial, real batch-path, terminal `mac_query`, correctable-error, and unrelated-tool controls passed through Xcode | **PASS (PATCHED RELEASE):** JANG_6M and JANG_4M Computer Use returned one terminal red row each with no parent retry/fabrication. A stopped dedicated-model `mac_query` returned `execution_error`, `retryable:false`; the parent emitted no follow-up answer or second tool call |
| P0 | 8B stays selected after relaunch and does not silently fall back to 16B | RISK FOUND: `AppleScriptModelCatalog.swift:160` automatic selection uses `installedModels().first`; with the catalog ordering this can choose 16B unless 8B is explicitly selected | NOT RUN | **PASS (VISUAL SETTINGS/RUNTIME):** after rebuilt-app relaunch the popup still showed Osaurus AppleScript 8B; 16B remained available/not installed; Confirm each and Keep Warm persisted. With Fast reads OFF the live feed generated on exact JANG_6M; the setting was then restored ON |
| P0 | Computer Use permissions/settings toggles actually change runtime behavior | `AppleScriptKind.resolveModel` reads `appleScriptQueryPrefersResidentModel`; ON reuses a resident tool-capable chat model, OFF resolves the selected dedicated AppleScript model | NOT RUN | **PARTIAL/PASS FOR TOGGLE:** Accessibility was visibly granted; Screen Recording remained optional/off. Fast reads ON generated `mac_query` scripts with Ornith MXFP8. Toggling OFF visibly unloaded Ornith and generated with exact `OsaurusAI/Osaurus-AppleScript-8B-JANG_6M`; toggling ON again restored the default. Dedicated execution remained blocked by the isolated bundle's macOS Automation grant prompt |
| P0 | Memory Safety warning -> user changes setting -> intended large model can load | Existing memory-admission work is on main; exact UI/runtime contract still to trace | NOT RUN | NOT RUN |
| P0 | Re-enabling the safer RAM setting restores refusal/warning | Source audit pending | NOT RUN | NOT RUN |
| P1 | AppleScript 8B Thinking off/on, plain task, multi-step task, tool error, retry, and multi-turn | Bundle declares tool and reasoning capabilities; parser/template wiring still to trace | NOT RUN | NOT RUN |
| P1 | AppleScript 8B cold/warm TTFT, token/s, physical footprint, stop/cancel cleanup | Runtime telemetry surfaces exist; exact path pending | NOT RUN | NOT RUN |
| P1 | Computer Use wrong app name, app absent, minimized window, multiple windows, permission denial, app launch delay | Source audit pending | NOT RUN | NOT RUN |
| P1 | AppleScript 8B compatibility with Computer Use's `agent_action` schema, distinct from the AppleScript ability's `run_applescript` schema | Bundle declares `tool_parser: zaya_xml` and generic tool support, but its README and specialization describe native `run_applescript`; Computer Use forces a single named `agent_action` tool | NOT RUN | **ADJACENT FAIL:** patched JANG_6M emitted an invalid action verb; patched JANG_4M omitted `agent_action`, accepted the corrective re-ask, then timed out. Do not silently filter, coerce, or reroute the model in this urgent PR |
| P1 | Spawned agent with no tools, disabled plugin, missing permission, denied tool, exhausted tool budget | Source path identified | NOT RUN | NOT RUN |
| P1 | Spawn/delegation RAM admission and visible insufficient-RAM notification | Source audit pending | NOT RUN | NOT RUN |
| P1 | Image generation/editing model RAM admission and safety-setting behavior | Deferred from the emergency pin PR; still required | NOT RUN | NOT RUN |
| P1 | Gemma 4 rotating-SWA TurboQuant default off, explicit toggle, prefix/L2 disk restore and truthful GB growth | Deferred from the emergency pin PR; still required | NOT RUN | NOT RUN |
| P1 | Qwen 3.5/3.5 VL hybrid SSM/GDN rederive plus TurboQuant/prefix/L2 restore | Deferred from the emergency pin PR; still required | NOT RUN | NOT RUN |
| P1 | Gemma/Bonsai regression sweep after any shared runtime change | Prior narrow ledger exists; follow-up head not yet exercised | NOT RUN | NOT RUN |
| P2 | MXFP4 structurally cut-off output fallback | DOCUMENTED ONLY in the Gemma/Bonsai ledger; explicitly excluded without an exact user-provided reproduction | NOT RUN | NOT RUN |

## 2026-07-17 AppleScript 8B finalization and fallback investigation

### Exact pre-patch visual candidate and settings

The local reproduction used the ad-hoc signed isolated Release app
`/tmp/osaurus-bonsai-chart-recovery.app`, bundle id
`com.dinoki.osaurus.bonsaichartproof`, fresh app root
`/tmp/osaurus-bonsai-chart-recovery-root-0241`, and model root
`/Users/eric/models`. Its affected Computer Use, AppleScript, chat, and tool-loop
sources are identical to tag `0.22.5`; the candidate includes only the already
merged PR #2065 chart patch outside those unchanged paths. Exact vMLX revision
is `a26c7ecec950f18e3d07c8402fbd8c80f40ac764`. This is pre-patch reproduction
evidence, not evidence for the new source candidate.

The real Settings and agent UI visibly showed Accessibility granted, Screen
Recording granted, Balanced global Computer Use policy, the agent's Computer
Use ability enabled, and exact model
`OsaurusAI/Osaurus-AppleScript-8B-JANG_6M`. AppleScript was first enabled with
the same dedicated 8B model and Confirm Each, then disabled to isolate the
Computer Use path. No MXFP4 model was loaded or tested.

With both abilities enabled, `Open Calculator` routed through the separate
AppleScript ability, proposed `tell application "Calculator" to activate`, and
completed with a green AppleScript row and parent text. That does not exercise
Computer Use's forced `agent_action` contract.

With AppleScript disabled and Computer Use still enabled on exact JANG_6M, a
fresh `Open Calculator` turn called `computer_use` with goal `Open the
Calculator app on macOS and show its default interface`. The child then
proposed unrelated Save/Finder actions and an invalid `click` without a target.
It returned the canonical envelope
`{"ok":false,"kind":"execution_error",...,"retryable":false,"tool":"computer_use"}`.
The parent did not stop: it immediately launched another Computer Use run with
unrelated Save/Warp upgrade-flow actions. The user had to press Stop. A fresh
`Open TextEdit` row likewise proposed `Open Finder` for a Save-dialog context
and was stopped. These rows directly prove the failure-continuation boundary
and an adjacent model/schema semantic mismatch; they do not reproduce the
user's exact successful-action/finalization sequence.

### Current source trace and candidate behavior

This is not the chat `content.delta` streaming path. Computer Use performs its
child model step through the non-streaming completion path with one strict,
named `agent_action` tool. The first report is therefore a required-tool
finalization/schema-contract failure at EOS; the second combines an overly
broad auto-selected `mac_query` contract with a returned failure envelope that
the parent chat loop did not classify as terminal.

`ComputerUseLoop.modelStep` sends one `AgentAction.toolSpec` with named forced
choice `agent_action`, and `ChatEngine` rejects a local EOS without a parsed
call as `NSError(domain: "OsaurusToolChoice", code: 422)`. The loop already has
a bounded `guard let call = parsed else` re-ask, but the thrown error was caught
earlier as a terminal run failure. The candidate classifies that exact
domain/code as a protocol-shape miss, bypasses the inner same-prompt inference
retry, and lets the outer loop add its existing corrective nudge. Other errors
keep the previous timeout/retry/failure behavior. No closer, sampler, prompt
coercion, output cap, or parser repair is added.

Normal chat uses `ChatToolChoicePolicy.resolve` against the current user text;
the reported feedback sentence does not force any tool, so `mac_query` is a
model selection under `.auto`, not source evidence of stale required-tool
state. The candidate makes the tool description, `question` property schema,
and full/compact AppleScript guidance explicit: call `mac_query` only when the
current request asks for Mac/app state or that state is necessary to complete
it, never to invent a conversational acknowledgement query. This is a model
contract clarification, not a feedback keyword filter.

`SubagentSession` maps Computer Use and all-failed AppleScript outcomes to
canonical returned failure envelopes. Chat's tool executor treated those as
ordinary results because they did not throw, leaving `isError=false`; the
agent-loop rejection policy therefore allowed a second parent iteration. The
candidate stops Chat only for canonical, non-retryable terminal failures from
`computer_use`, `applescript`, and `mac_query`. Correctable `invalid_args` and
`not_found` results still reach the parent for a changed call, and all unrelated
tools retain their prior behavior.

The exact AppleScript bundle declares `tool_parser: "zaya_xml"` and
`supports_tools: true`, but its published specialization and examples target
`run_applescript`, not Computer Use's `agent_action`. That is a concrete
compatibility risk behind the unrelated actions. It is not yet promoted to the
root cause of the user's successful-action finalization report, and this urgent
candidate does not change automatic model routing or silently remove the model
from the Computer Use picker.

The focused Xcode run used the real `OsaurusCoreTests` workspace scheme and
the exact resolved vMLX revision above. `ComputerUseLoopRunTests`,
`AgentToolLoopTests`, and `AppleScriptToolSelectionGuidanceTests` all passed,
including the new required-action protocol re-ask, Chat serial and batch
terminal-failure stops, failed-`mac_query` no-follow-up control, correctable
desktop-error pivot control, and unrelated-tool non-regression. Result bundle:
`/tmp/osaurus-applescript-finalization-tests-dd/Logs/Test/Test-OsaurusCoreTests-2026.07.17_17-48-05--0700.xcresult`.
The bare CommandLineTools `swift test` lane remains a runner-configuration
blocker because that selected toolchain cannot import the existing `Testing`
module; it is not counted as a code failure or a passing row.

### Patched isolated Release live evidence

The final UI rows used the Release app at
`/tmp/osaurus-applescript-finalization-app-dd/Build/Products/Release/osaurus.app`,
bundle id `com.dinoki.osaurus.applescriptfinalizationproof`, isolated root
`/tmp/osaurus-applescript-finalization-live-root-20260717-1718`, local model
root `/Users/eric/models`, and exact vMLX revision
`a26c7ecec950f18e3d07c8402fbd8c80f40ac764`. The app was ad-hoc signed and
`codesign --verify --deep --strict` succeeded. Its executable SHA-256 is
`9dc8fff6dcfbd4fce5493b21ea3a99851ca08b61a555428710bd86ad5191faf4`.
No production app preferences or model root were reused.

While the live matrix was running, `origin/main` advanced to `2c76b9048` with
PR #2069's Bonsai onboarding/model-metadata changes. Those files do not overlap
this candidate. The branch was rebased, the focused suites passed again, and
the same isolated Release app was rebuilt from exact rebased head `3783b0d57`.
On relaunch the UI still showed Ornith MXFP8, Computer Use on with JANG_4M,
screen context off, and AppleScript on with JANG_6M/Confirm each. The exact
feedback sentence again produced an acknowledgement-only reply at 64.0 tok/s.
An explicit nonexistent-app `mac_query` then returned the grounded error
`Can't get application "DefinitelyNotARealMacApp"`; the parent reported that
error at 63.3 tok/s without inventing a title/date or calling another tool.

The real UI showed parent model `Ornith-1.0-9B-MXFP8`, Thinking unselected,
Accessibility granted, Screen Recording optional/off, per-agent screen context
off, Computer Use enabled, and AppleScript enabled with Confirm each. A quit
and relaunch preserved the parent model, helper selections, toggles, and screen
context setting. Computer Use was tested first with installed
`AppleScript 8B JANG_6M`, then with installed `AppleScript 8B JANG_4M`; no
MXFP4 model was loaded.

- JANG_6M `Open Calculator` produced one `computer_use` call, then canonical
  `execution_error`, `retryable:false` because its action `verb` was outside
  the `agent_action` enum. Parent metrics were TTFT 1.31s, 20.5 tok/s, 51
  tokens. The patched chat stopped after that red row: no second automation and
  no fabricated success.
- JANG_4M `Open Calculator` showed `Model did not call agent_action`, proving
  the exact protocol miss reached the outer corrective re-ask. Its subsequent
  model steps timed out and the run returned one terminal `execution_error`.
  Parent metrics were TTFT 1.14s, 28.9 tok/s, 58 tokens. Again there was no
  second automation or fabricated success. Neither AppleScript helper opened
  Calculator in these rows, so successful-action finalization remains blocked.
- With AppleScript and Computer Use both enabled, three fresh chats replayed
  the exact feedback sentence from the report. The replies were plain
  acknowledgements at 62.7, 61.3, and 62.0 tok/s. None selected `mac_query`,
  AppleScript, Computer Use, or any other tool.
- With global `Fast reads on the chat model` visibly ON, an explicit nonexistent
  app query generated on resident Ornith MXFP8 as the setting promises. The
  tool returned `status:partial` with the grounded value that the app was not
  running or found; the parent reported that failure at 60.0 tok/s and did not
  invent a document title.
- Toggling Fast reads OFF through Settings changed the next live query's feed:
  it waited for chat idle, unloaded Ornith, and generated on exact
  `OsaurusAI/Osaurus-AppleScript-8B-JANG_6M`. The dedicated row encountered two
  45-second script timeouts, a compile error, and AppleScript error `-1728`
  while macOS Automation still displayed `Not yet granted`; it was stopped at
  2m57 rather than allowed to continue. The returned envelope was exact
  `mac_query` `execution_error`, `retryable:false`. The patched parent emitted
  no second iteration and no answer. Fast reads was then visibly restored ON.
- CLI `footprint` during the JANG_4M handoff measured 5,942 MB for the proof app
  while the UI showed the parent cold/unloaded. This is supporting telemetry,
  not the requested Activity Monitor visual row; that visual footprint gate is
  still missing.

### Remaining live acceptance matrix

- Replay TextEdit, Calculator, and Safari navigation through Computer Use. A
  row passes only when the requested action is visibly correct and the same
  turn finishes without contradictory required-tool failure.
- Grant the isolated proof bundle's macOS Automation permission, then repeat a
  dedicated-model read and a state-changing AppleScript row. The current
  permission dialog is external to the Osaurus accessibility tree and the
  Computer Use controller is not allowed to operate UserNotificationCenter.
- Capture Activity Monitor `phys_footprint` visually during a helper load. The
  current 5,942 MB value is CLI support only.
- Resolve AppleScript 8B's `agent_action` compatibility separately from this
  narrow containment patch. Do not hide it with forced prompts, parser repair,
  sampler changes, or silent routing.

## Known current source evidence

### Current build and test state

The isolated app build started from exact Osaurus head `d16b06763` under
the proof bundle id `com.dinoki.osaurus.agentcuapplescriptproof`. Xcode resolved
the app's `vmlx-swift` dependency to implementation revision
`a26c7ecec950f18e3d07c8402fbd8c80f40ac764`. The ad-hoc signed Release app
launched with isolated root `/tmp/osaurus-agent-cu-applescript-root-d16b` and
local-model root `/Users/eric/models`. The patched Release executable was
regenerated at 2026-07-16 23:09 PDT and re-sealed ad hoc; `codesign --verify
--deep --strict` passed before relaunch. The direct and spawned Calendar rows
below use the same base and dependency revisions; the spawned rows use the
patched executable, while the direct row was captured from the pre-patch
Release artifact.

The first focused command used bare `swift test` and reached the test target,
but did not execute behavior tests because the selected toolchain could not
import Swift Testing (`no such module 'Testing'` from
`AgentCapabilityRowBuilderTests.swift:20`). That invocation is **BLOCKED**, not
a failure or pass of the spawn/Computer Use behavior. The equivalent selected
tests were then executed through the `OsaurusCoreTests` Xcode scheme at the
same head and vMLX resolution: all 12 existing `SpawnToolsetTests` and the
selected Computer Use foreground test passed. Xcode result bundle:
`/tmp/osaurus-agent-cu-applescript-focused-tests/Logs/Test/Test-OsaurusCoreTests-2026.07.16_22-32-19--0700.xcresult`.
These tests do not cover the legacy `nil` spawn mismatch or live app switching.

After the live failure isolated the child-versus-parent execution-scope bug, the
local patch added a focused regression and reran the complete selected spawn
suite. All 13 `SpawnToolsetTests` passed, including
`SpawnToolsetTests/agentToolDispatchUsesChildExecutionScope()`. Xcode result
bundle:
`/tmp/osaurus-agent-cu-applescript-focused-tests/Logs/Test/Test-OsaurusCoreTests-2026.07.16_22-56-25--0700.xcresult`.
That result was source/test evidence only; the separate patched Release live
evidence is recorded below.

The final combined run added the five `ToolExecutionScopeTests` and both
`ToolExecutionScopeWiringTests` to the same 13 spawn tests. Xcode reported
20 passed, 0 failed, and 0 skipped. Result bundle:
`/tmp/osaurus-agent-cu-applescript-focused-tests/Logs/Test/Test-OsaurusCoreTests-2026.07.16_23-25-22--0700.xcresult`.

### Spawned-agent capability ownership

Current main's `TextSubagentKind.resolveAgentTarget` stores the target agent's
own enabled tool specs using `agentChildToolSpecs(agentId:)`. The child toolset
combines those target-agent tools with any separately granted read-only tools,
deduplicates names, enforces a per-run call budget, and dispatches through
`ToolRegistry.shared.execute`. This is the correct ownership direction for the
reported Calendar case, but live proof must still show that the installed
calendar plugin is registered when the target agent is resolved and remains
available for each spawned iteration.

There is an uncovered legacy-state mismatch on the same path.
`AgentManager.effectiveEnabledToolNames(for:)` deliberately returns `nil` for
an unseeded agent, and direct chat interprets that as unrestricted access to
the current live registry. `TextSubagentKind.agentChildToolSpecs`, however,
uses `?? []`, turning the same legacy `nil` into a text-only spawned child.
Existing `SpawnToolsetTests` prove explicit `agentSpecs` union, allowlisting,
and call budgets; they do not exercise this manager-to-registry fallback. This
is a source-trace risk, not yet a reproduced live root cause. The visual matrix
must keep an explicit empty list distinct from legacy `nil`: disabled tools
must remain disabled while only the compatibility fallback gets parity.

The fresh-agent live reproduction found an additional, immediate failure after
schema construction. `/tmp/osaurus_debug.log` recorded the parent Assistant
request with 9 schemas (`spawn_agent` but no `get_events`) and the child request
with 15 schemas including `get_events`. `ToolRegistry.execute` enforces the
request's `ChatExecutionContext.toolExecutionScope`; `TextSubagentKind` built a
child allowlist but did not publish a child execution scope before dispatch, so
the child inherited the parent scope and received the registry's exact
`get_events is not available in this conversation` envelope. The local patch
creates one `ToolExecutionScope` from the child schemas and binds it around
every child dispatch. The one-scope-per-run lifetime preserves additive
`capabilities_load` activation. The focused child-scope regression and two
patched Release UI rows now pass. This evidence is specific to a freshly seeded
agent with the live Calendar registry present; legacy `nil` compatibility is
still a separate source risk.

### Patched spawned-Calendar live evidence

On patched Release relaunch, the chat label visibly remained `Gemma 4 12B it
MXFP8`. Runtime debug reported model id
`OsaurusAI/gemma-4-12B-it-MXFP8`, and `lsof` showed the process mapping the
13-shard local bundle at
`/Users/eric/models/OsaurusAI/OsaurusAI--gemma-4-12B-it-MXFP8`. The model
warmup completed in 4.35 seconds. This resolves the duplicate-display-name
ambiguity with process evidence; no MXFP4 bundle was loaded.

The keychain-disabled proof mode intentionally skipped plugin loading at
startup, so the first post-relaunch child had 11 schemas and no Calendar tool.
Settings -> Plugins still visibly showed Browser and Calendar installed. The
user-visible Refresh action loaded them and increased Tools from 59 to 84;
the live `/mcp/tools` surface then contained `create_event`, `get_events`,
`open_event`, and `search_events`. This is a proof-harness limitation plus a
real test-root isolation gap: `ToolsPaths.root()` resolves `~/.osaurus` instead
of honoring `OSAURUS_TEST_ROOT`.

The first generation immediately after that hot-load received all 15 child
schemas but produced no child delta or tool call for 112.3 seconds. It was
stopped from the UI and persisted the honest cancellation envelope. The next
clean new-chat retry completed:

- parent spawn JSON targeted `Calendar Agent` with the exact 2099-01-01 through
  2099-01-02 task;
- child ran 2 iterations in 3.49 seconds on
  `OsaurusAI/gemma-4-12B-it-MXFP8`, returned the grounded empty result, and
  reported 31.3 tok/s for 259 worker tokens;
- parent finished in 5.15 seconds with TTFT 1.19 seconds and 31.2 tok/s;
- cache telemetry reported 12 disk-L2 hits, 47 misses, and 18 stores.

A second prompt in the same chat delegated 2099-01-03 through 2099-01-04. It
returned a real all-day event from the Birthdays calendar, with the personal
title redacted from this GitHub-visible ledger. The child ran 2 iterations in
7.90 seconds at 31.7 tok/s for 428 worker tokens; the parent tool call took
9.59 seconds and its final row showed TTFT 1.08 seconds and 39.3 tok/s. Cache
telemetry reported 16 disk-L2 hits, 82 misses, and 25 stores. Post-run
`footprint` measured 2,071 MB physical footprint with a 4,738 MB peak for the
proof process.

### Direct Calendar live evidence

The isolated Release UI created `Calendar Agent` with an explicit
`gemma-4-12B-it-MXFP8` model selection. Its tool picker visually showed
Calendar 4/4 assigned and Browser 0/21. The read-only prompt requested events
from 2099-01-01 through 2099-01-02. Gemma first emitted a syntactically valid
`capabilities_load` call with the wrong semantic id
`plugin/osasaurus.calendar`; the host returned structured `not_found`, after
which the same run visibly showed `Searched capabilities`, `Loaded
capabilities`, and `Get events`. The final answer reported no events for that
range. The UI displayed TTFT 0.97s, 31.2 tok/s, and 34 tokens. This proves the
direct tool route and error recovery for this one prompt. The separate patched
spawned rows above prove fresh seeded-agent parity and a same-chat second turn;
legacy-agent compatibility remains unverified.

### Computer Use app switching

PR #2032 is present on main and is described as foregrounding apps on the
Computer Use open path. The actual driver, frontmost-app tracker, wait/observe
sequence, app-name resolution, and multiple-window behavior still need an
end-to-end trace. The report "stuck on the last window" remains unresolved
until a live run visibly switches apps and subsequent screenshots/AX context
track the new frontmost app.

### AppleScript 8B discovery

PR #2046 is present on main and added the Osaurus AppleScript 8B catalog row,
moved AppleScript model discovery to Settings -> Computer Use -> Models, and
redirected matching searches/imports away from the generic model catalog. The
exact local test bundle is installed and complete enough for runtime proof:
eight safetensor shards, tokenizer/template/config files, and 7.4 GB on disk.
Catalog visibility alone does not prove selection, load, execution, RAM, or
Computer Use app switching.

## Real-user questions that must be answered before promotion

1. Does the exact same Calendar Agent expose the same tool names and schemas in
   direct chat and when reached through `spawn_agent`?
2. If its plugin is disabled, unloaded, denied permission, or removed after
   agent creation, does both direct and spawned execution fail honestly rather
   than role-play success?
3. Does a spawned child retain its tools after one tool-result round and make a
   second grounded call without losing schema state?
4. Does Computer Use `open` make the requested app frontmost, wait until its
   window is actionable, and refresh both screenshot and AX context before the
   next model step?
5. What happens for an already-running app, minimized app, multiple windows,
   a localized/display-name mismatch, a missing app, and a delayed launch?
6. Can the model switch A -> B -> A in one run without acting on a stale frame
   or falsely reporting success?
7. Is AppleScript 8B discoverable from the documented Computer Use settings
   surface, selectable, persistent across relaunch, and never replaced by 16B
   without an explicit visible choice?
8. Does JANG_6M load through the exact bundled vMLX revision, produce coherent
   visible output and real AppleScript/Computer Use actions, report token/s,
   and remain within the intended physical-footprint gate?
9. Do Thinking, confirmation, screenshot/vision, automation permission, and RAM
   safety toggles all reach the runtime that actually performs the next task?
10. When Memory Safety blocks a model, does changing the documented user
    setting permit the next load, and does restoring the safer setting restore
    the warning/refusal without hidden MLX memory throttling?
11. Do cancellation, close-chat, and quit during 8B load or execution cleanly
    release the model and leave no zombie work?
12. After any shared fix, do Gemma and Bonsai still load, use tools, continue
    after tool results, avoid loops/marker leakage, and preserve truthful cache
    and RAM telemetry?

## Related prior evidence

`docs/GEMMA_BONSAI_EMERGENCY_PROOF_2026-07-15.md` is the authoritative prior
ledger for the merged schema-1 JANG loader pin, the still-partial Ornith
multi-step semantic failure, the deferred cache/RAM matrix, and why the
reported JANG_4M/MXFP8 behavior did not support a content-delta or tool-JSON
assembler diagnosis.

## 2026-07-20 repeated-edit, no-save, and reasoning-propagation checkpoint

This checkpoint is intentionally separate from the wider cache/TurboQuant and
model-family campaign. Its source base is Osaurus
`59334020f54950f16247a2b60474de7b11fbb54b`; the focused Xcode workspace
resolved vMLX Swift to
`f2b184841e98d969e46dec83109f27cd7bb57357`. No row below is a live pass until
the isolated Release app is operated through visible Settings and chat UI.

The primary local helpers for this checkpoint are the exact registered bundles
`JANGQ-AI/AppleScript-8B-JANG_6M` and
`JANGQ-AI/AppleScript-16B-A4B-JANG_4M` under `/Users/eric/models`. MXFP4 is out
of scope and must not be downloaded, loaded, or used as evidence.

### Change-by-change scope and regression ledger

| Change / reported issue | Owning source and intended scope | Main spillover questions | Focused evidence | Required live evidence | Current verdict |
| --- | --- | --- | --- | --- | --- |
| Successful TextEdit mutation repeats until duplicate text or failure | `AppleScriptLoop` success finalization already on current main terminates a successful action-only automation; exact/data-bearing tasks still require independent readback | Does it terminate only real successful action rows; do failures, denied confirmation, exact-content readback, and multi-step reads still continue correctly | `successfulActionStopsRepeatingModel`, `mutatingReturnNeedsReadBackForExactContent`, and neighboring loop tests passed in the current Xcode run | Seed `Hello from OracHQ`, request one replacement, inspect TextEdit, tool feed, and trace; repeat with larger-document partial replacement | **PARTIAL-LIVE — rebuilt Release JANGQ 16B changed `Hello World` to `Hello from OracHQ` exactly once, then changed `Hello from OracHQ` to `Hello again` exactly once. The second job used one mutation plus one read-only verification; no repeated edit occurred. JANGQ 8B and larger-document substring controls remain open.** |
| Model adds an unrequested Save workflow | TextEdit recipe now explicitly forbids `save`, Command-S, and Save menu unless requested; effect classifier now treats `save` as mutation rather than a read | Does requested Save still work; does unrequested Save require confirmation rather than auto-run; do other read-only scripts remain auto-runnable | recipe/classifier guidance tests passed in the current Xcode run | Replace unsaved text without asking to save, then separately ask to save; inspect approval cards, document state, and file side effects | **PARTIAL-LIVE — both rebuilt Release 16B replacements remained visibly Edited/unsaved and no Save command or workflow appeared. Requested-Save control remains open.** |
| Malformed AppleScript classified as read-only can consume the full loop | `AppleScriptLoop` now dry-compiles every proposed script before every gate, with the existing consecutive-invalid bound | Does a valid read still execute once; does a malformed read never execute; do runtime errors remain distinguishable from compile errors; does confirmation behavior remain unchanged for valid writes | `compileFailureBudgetCoversReadClassification` and the complete selected loop/effect suites passed | Trigger a bounded invalid-script correction, observe no application mutation and one terminal grounded failure; then run valid read/write controls | **PARTIAL — source/test only** |
| Parent puts generated instructions/scripts in literal `content`, or omits old/new replacement literals | `AppleScriptTool` schema guidance reserves `content`/`contents` for user-supplied literal bytes and names old/replacement text as separate exact blocks. `AppleScriptToolDispatch` now rejects unreferenced literal fields and script-like generated source masquerading as literal content, while preserving an explicit request to insert AppleScript source as text | Do JSON/schema parsing and committed tool arguments remain complete; are quotes/newlines/Unicode preserved; does ordinary `task`-only use remain unchanged; can a genuine code-as-text task still pass | `AppleScriptToolDispatchLiteralsTests`, schema guidance, selected loop, and app-knowledge suites exited 0 in the 2026-07-20 19:52 Xcode run | Rebuild Release, replay the exact second prompt, inspect the outer invalid-args correction and corrected committed invocation, and require exactly one unsaved TextEdit mutation | **PARTIAL-LIVE — the rebuilt Release binary no longer sent generated AppleScript as literal `content` for either exact reported replacement. The helper received the job, generated one approved mutation, and TextEdit reached the exact requested text. Quotes/newlines/Unicode and explicit code-as-text controls remain open.** |
| JANGQ helpers installed through External Models cannot be selected in native AppleScript settings | `AppleScriptModelCatalog` recognizes only dedicated `OsaurusAI/Osaurus-AppleScript-*` and `JANGQ-AI/AppleScript-*` prefixes; `AppleScriptModelsView` includes installed primary/external helpers in its native picker without adding a destructive catalog Delete row. The generic Computer Use picker intentionally excludes them because that loop requires `agent_action`, not `run_applescript` | Does auto-selection remain curated-only; do unrelated `other/AppleScript-*` names stay excluded; does explicit 8B/16B native selection persist and route the next run to that exact bundle; does no dedicated helper leak into chat/Spawn/Computer Use | primary-directory/external-source fixtures and model routing tests passed; the temporary Computer Use candidate was reverted after the live schema failure | Register `/Users/eric/models`, visibly select 8B then 16B under native AppleScript, quit/relaunch, and match each next native tool feed/load trace to the selected id | **PARTIAL-LIVE — native picker showed all four dedicated choices; JANGQ 8B persisted across relaunch; JANGQ 16B was visibly selected and its exact id loaded for both TextEdit controls. Computer Use routing was a failed experiment and is not part of the fix** |
| An anaphoric task such as “change the text in the file” loses the working app when Osaurus becomes frontmost | `AppleScriptKind.desktopSnapshot` now uses the existing `FrontmostAppTracker` handoff whenever Osaurus is frontmost; `AppleScriptAppKnowledge` limits fallback to explicit current/front-app or file/document cues | Could an unrelated task inherit stale app knowledge; does a genuinely frontmost non-Osaurus app still win; do named-app tasks remain authoritative; does the exact prompt now receive TextEdit recipes without globally injecting TextEdit | `workingDocumentFallback` passes with a battery-query negative control; prior named/frontmost tests also pass | Put TextEdit frontmost, return to Osaurus, send the exact original prompt, and require TextEdit in the helper prompt/approval plus one unsaved replacement | **PARTIAL — source/test pass; rebuilt Release exact-prompt rerun pending** |
| Dedicated helper accumulates parent/previous-job context and degrades into context rot | Each `AppleScriptLoop.run` constructs a new transcript containing only its task-specific system prompt/desktop/app recipe/literals plus `Task: <current task>`; only inner calls/results from that one run are appended. `TextSubagentKind` similarly creates a new seed from the target agent prompt plus the current delegated input and mints a unique spawn session id. Neither receives the parent transcript. | Does a second AppleScript job contain any first-job text; do within-job correction/readback still retain the needed tool result; does a spawned result return only its compact digest; does content-addressed prefix reuse remain valid without semantic transcript inheritance | Current source trace establishes the construction boundary; no new behavior test has yet captured two independent live request payloads | Run two deliberately disjoint AppleScript jobs and two disjoint spawns in one parent chat; compare every emitted request message and returned digest, and require zero prior-job text in the second helper request | **PARTIAL — source trace only** |
| SSD/prefix partial reuse corrupts a clean helper transcript or hybrid companion state | This AppleScript candidate does not modify the cache stack. The JANGQ 8B bundle is Qwen-derived, so a cache hit must restore or rederive every architecture-specific companion state before decode; a clean request array alone cannot exclude cache corruption | Do cold, exact-prefix, partial-prefix, and disk-only restore produce the same coherent script; do trace counters identify the actual tier; does a partial hit report the required async rederive/sync; does disabling paged RAM leave SSD lookup/store/reuse functional | **LIVE REPRO + SOURCE ROOT; ENGINE CANDIDATE UNVERIFIED** — Ornith fresh-process/new-chat exact SSD hits carried 48 companion states, but an exact indexed candidate bypassed `skipExactDiskBoundary` and the UI then full-prefilled; vMLX candidate excludes that exact candidate and skips validated duplicate writes | Through visible Server -> Cache settings keep paged RAM at its default Off, record a cold job, an exact repeat, a different partial-prefix job, unload/relaunch, then record SSD-only restore. Repeat with any explicit cache toggle changed and restore the default afterward | **PARTIAL-LIVE — SSD persistence/hits are real, and both 16B jobs were coherent, but the current binary reproduced the hybrid exact-hit rollback. Rebuild and prove safe partial restore plus JANGQ 8B before closure.** |
| JANGQ 8B silently reasons before every tool step when the UI did not request reasoning | Its template defaults `enable_thinking` to true when absent. Each `AppleScriptLoop.modelStep` marks the request as agentic; `ChatEngine.prepareDispatch` resolves the per-model agent policy; `MLXBatchAdapter.additionalContext` should inject `enable_thinking=false` for the default direct-agent policy. Explicit per-model choices must still win. | Is the kwarg present on every first and post-tool step; is this limited to agent/tool requests; do normal chat and explicit reasoning choices remain untouched; do Gemma/Qwen/DSV4 family-specific policies remain unchanged | `AgentReasoningPolicyTests`, `AgentReasoningDispatchTests`, and `LocalReasoningCapabilityTests` passed | With the visible UI state recorded, capture `enable_thinking` for every JANG_6M model step plus TTFT/token/s; repeat a multi-step tool turn and a 16B control. No speed/coherence claim is allowed from source alone | **PARTIAL — source/test only** |

Current focused result bundles are:

- `/private/tmp/osaurus-applescript-emergency-tests-derived-20260720/Logs/Test/Test-OsaurusCoreTests-2026.07.20_18-21-45--0700.xcresult`
- `/private/tmp/osaurus-applescript-emergency-tests-derived-20260720/Logs/Test/Test-OsaurusCoreTests-2026.07.20_18-26-42--0700.xcresult`
- `/private/tmp/osaurus-applescript-emergency-tests-derived-20260720/Logs/Test/Test-OsaurusCoreTests-2026.07.20_19-05-41--0700.xcresult` (**failed** first working-document assertion; retained intentionally)
- `/private/tmp/osaurus-applescript-emergency-tests-derived-20260720/Logs/Test/Test-OsaurusCoreTests-2026.07.20_19-07-27--0700.xcresult` (`AppleScriptAppKnowledgeTests`, exit 0)
- `/private/tmp/osaurus-applescript-emergency-tests-derived-20260720/Logs/Test/Test-OsaurusCoreTests-2026.07.20_19-28-04--0700.xcresult` (`ModelPickerItemChatCapabilityTests` plus `AppleScriptModelRoutingTests`, exit 0; includes the Computer-Use-only dedicated-model candidate boundary)
- `/private/tmp/osaurus-applescript-emergency-tests-derived-20260720/Logs/Test/Test-OsaurusCoreTests-2026.07.20_19-51-11--0700.xcresult` (`AppleScriptToolDispatchLiteralsTests`, selection guidance, loop, and app-knowledge suites: 53 passed, 0 failed, 0 skipped; the later live Computer Use failure caused the candidate picker route to be reverted)
- `/private/tmp/osaurus-applescript-emergency-tests-derived-20260720/Logs/Test/Test-OsaurusCoreTests-2026.07.20_20-05-18--0700.xcresult` (`SandboxManagerCleanupTests`: 5 passed, 0 failed, 0 skipped; includes cancellation/await of prefetch, provision, and start writers before removal)

### Second Release candidate: pre-working-app-fix live evidence

The next isolated Release executable had SHA-256
`6a4b96b83960698eab7afd2e38b6eff6bafc19a43725b65f7205ab10f5c3866a`.
Computer Use visibly showed `Models (4)` and the picker entries `Choose
automatically`, the curated Osaurus 8B, JANGQ 16B A4B JANG_4M, JANGQ 8B
JANG_4M, and JANGQ 8B JANG_6M. The per-agent JANG_6M selection, Confirm Each
mode, Ornith 1.0 9B MXFP8 parent, and visible parent Thinking Off state all
persisted across an app quit/relaunch. Server -> Settings -> Cache visibly
showed Prefix Cache On, GPU paged cache Off, Disk Cache On, SSM re-derive On,
and Codec `Engine Selected`.

The exact reported prompt then failed live after 24.3 seconds. The visible tool
card showed only `content: Hello from OracHQ` and task `Replace the text ... in
the file`; its result was a grounded non-compiling-script failure. The raw
JANGQ trace showed a generic 3,726-character system prompt, a Finder file
chooser, then three bounded compile failures. Runtime cache trace showed a cold
1,360-token helper prefix followed by partial SSD hits at boundaries 1,360 and
1,634 with hybrid re-derive logs. TextEdit remained unchanged. This is a real
failed row; it does not prove cache corruption because the helper never
received TextEdit as its target.

Under the identical visible cache/reasoning/model settings, a control prompt
that explicitly named the open TextEdit document produced one valid direct-set
script, one approval card, and no Save command. TextEdit visibly contained
exactly `Hello again` once and remained `Edited`/unsaved. The helper trace
showed JANGQ 8B JANG_6M, a 5,237-character TextEdit-aware system prompt, one
tool call in 6.5 seconds at 43.0 tok/s, and no inner retry. The final Ornith row
showed Thinking Off, zero reasoning deltas in the runtime stream, TTFT 1.33
seconds, 26.6 tok/s, and 79 tokens. The outer AppleScript elapsed display was
45.0 seconds because it included model handoff and human approval wait; it is
not helper decode time. The returned residency counters reported zero disk-L2
hits, six misses, and two stores for that control.

### JANGQ 16B native controls and rejected Computer Use route

The isolated Release app was operated with the parent set to Ornith 1.0 9B
MXFP8, parent Thinking visibly Off, Computer Use Off, Spawn Off, native
AppleScript On, Confirm Each, and helper
`JANGQ-AI/AppleScript-16B-A4B-JANG_4M`. For the explicitly scoped prompt
`In TextEdit, change ... “Hello from OracHQ” to “Hello again”`, the parent
first made a read-only `mac_query`, then the helper proposed exactly one direct
TextEdit mutation:

```applescript
tell application "TextEdit"
    set text of front document to "Hello again"
end tell
```

The approval card contained no Save command. After approval, TextEdit visibly
contained exactly `Hello again` once and its title remained `Untitled 2 —
Edited`, so no Save occurred. The parent finished with a visible `Done` answer,
TTFT 1.38 seconds, 51.0 tok/s, and 26 tokens. The dedicated helper trace named
the exact 16B bundle, recorded 2.7 seconds and 80.0 tok/s, and contained one
`run_applescript` call. This is one explicit-app native control, not proof of
the original anaphoric prompt or generic Computer Use.

For the second explicit prompt, seeded with visible `Hello World`, the parent
committed this outer argument shape:

```json
{
  "content": "tell application \"TextEdit\" ... keystroke ...",
  "task": "Select all text in the active TextEdit document and replace it with \"Hello from OracHQ\", then press Return."
}
```

That is a parent-to-helper contract violation: generated AppleScript was put
in the literal `content` field and the parent invented UI steps not requested
by the user. The helper produced a non-compiling script and stopped after
compile feedback. TextEdit visibly remained exactly `Hello World`; it was not
saved or partially mutated. This committed invocation establishes that this
failure is tool argument/schema construction, not content-delta streaming.
`AppleScriptToolDispatch` now returns `invalid_args` for unreferenced literal
fields and script-like generated literal content unless the user explicitly
asked to insert AppleScript source as text. The four new literal-contract tests
plus selected guidance, loop, and app-knowledge suites exited 0. A rebuilt
Release replay is still required before that change can be called effective.

A separate temporary route exposed both dedicated helpers in the generic
Computer Use picker. With 16B visibly selected, the trace loaded that exact
bundle, but it emitted two invalid `agent_action` envelopes and then no
required action; TextEdit remained unchanged and the turn ended failed after
26.0 seconds. This proves only that the specialized `run_applescript` bundle
does not reliably satisfy Computer Use's schema. The picker change was
reverted rather than adding a parser coercion or misrepresenting the model's
capability.

### Third Release candidate: literal-contract and exact reported edits

The current rebuilt app is
`/private/tmp/osaurus-applescript-emergency-release-derived-20260720/Build/Products/Release/osaurus.app`,
bundle id `com.dinoki.osaurus.applescriptemergency20260720`, executable
SHA-256
`114fbe282e9e2872abe88ca8c991da6ebc1b7c9e19f0ef5029bd94c54511fd9b`,
isolated root
`/private/tmp/osaurus-applescript-emergency-live-root-20260720`, and exact
vMLX pin `f2b184841e98d969e46dec83109f27cd7bb57357`. It was ad-hoc signed and
launched keychain-free with `/Users/eric/models` explicitly provided to the
isolated process. The real Cache settings UI showed Prefix On, paged GPU/RAM
Off, Disk On, Engine Selected/native, and SSM rederive On. The parent was exact
`Ornith 1.0 9B MXFP8`, visibly warm with Thinking Off; the selected native
helper was exact `JANGQ-AI/AppleScript-16B-A4B-JANG_4M`.

Two user-visible TextEdit controls were run:

1. Starting from visible unsaved `Hello World`, the prompt requested
   `Hello from OracHQ`. The parent first performed the relevant read. The
   helper proposed one direct TextEdit setter, the approval card was accepted,
   and TextEdit visibly contained exactly `Hello from OracHQ` once. The title
   remained Edited/unsaved. The parent ended with grounded success at TTFT
   1.45 s, 49.9 tok/s, and 25 tokens. No Save workflow appeared.
2. In a new chat starting from visible unsaved `Hello from OracHQ`, the exact
   reported replacement to `Hello again` produced one mutating script and one
   post-mutation read-only verification. After approval, TextEdit visibly
   contained exactly `Hello again` once and remained Edited/unsaved. The parent
   ended with grounded success at TTFT 1.41 s, 49.9 tok/s, and 31 tokens. There
   was no repeated mutation and no Save workflow.

These rows show that the rebuilt literal-field/schema guidance is effective
for the two exact explicit-TextEdit reports and that the response is not being
cut off by content-delta streaming. They do not close JANGQ 8B, requested Save,
larger-document substring replacement, permission denial, cancellation, or
generic Computer Use.

They also exposed a separate cache defect. The runtime reported exact Ornith
SSD hits with 48 recurrent companion states, including
`boundary=2234 remaining=0 ... skipExactDisk=true`, while the UI then showed
raw prefill advancing from zero in 512-token chunks. The pinned vMLX source
re-admits the prohibited exact boundary through its indexed-candidate loop;
without a safe N-1 GDN seed, the restored state is discarded and the prompt is
fully prefetched. A vMLX candidate now excludes the exact indexed candidate
and avoids rewriting a file that this process has already validated when its
fingerprint and SQLite row remain unchanged. That candidate is not in this
binary; its live verdict remains **PARTIAL** until the app is rebuilt against
the new pin and the visible prefill/counters/files prove the intended route.

### Cross-cutting live controls required before promotion

The following remain deliberately **PARTIAL / NOT RUN** after the current
Release evidence:

- JANGQ 8B one-step/multi-step replacements and a larger-document substring
  replacement; the two exact 16B one-step reports above are the only current
  mutation passes;
- app closed/already-open, Confirm Each accept/decline, requested Save, denied
  Save, cancellation, failure recovery, and quit/relaunch persistence;
- exact feedback-only acknowledgement with no `mac_query`, date invention, or
  stale tool selection;
- Computer Use only, AppleScript only, both abilities, and parent recovery
  after Spawn without recursive desktop-tool inheritance;
- per-step reasoning kwarg, visible Thinking state, TTFT, token/s, coherent
  visible answer, no protocol-marker leakage, no duplicate mutation, and no
  length-cap or stochastic-loop fake pass;
- Activity Monitor physical footprint and model unload/reload behavior;
- rebuilt-engine proof for the reproduced hybrid SSD exact-hit rollback and
  duplicate large-file writes, plus paged/L2/TurboQuant-KV controls. Cache
  storage, partial reuse, eviction, determinism, and toggled policy remain
  separate live rows and must not be inferred from a successful automation.

### Fourth diagnostic: exact outer/inner contract failures before the new candidate

The previous Release app (which did **not** contain the source changes below)
was used to separate four possible causes before another build:

1. With JANGQ 8B selected, the plain reported replacement produced a complete,
   parseable outer JSON call and a complete inner `run_applescript` call. The
   script itself appended `• New text replacement was added in TextEdit by
   OSaurus. Increase quotes if necessary.` and then the parent retried. There
   were zero reasoning deltas. This is a helper-generated script/termination
   failure, not content-delta truncation, tool-JSON assembly, or hidden
   reasoning.
2. With the common JANGQ 16B A4B JANG_4M helper selected, the same plain prompt
   produced complete JSON but invented invalid list operations and failed with
   AppleScript error `-1728`; TextEdit remained unchanged. Merely preferring
   the larger helper does not solve the contract.
3. When the parent correctly supplied `contents={oldText,newText}`, dispatch
   rejected it because the old validator recognized field names and the word
   `provided`, but not literal values already present in `task`. The parent
   burned several tool rounds, called an unrelated query, and eventually
   dropped the named literals.
4. With a task phrased in the intended named-value form, 16B emitted a complete
   multiline AppleScript program as assistant text instead of calling
   `run_applescript`. The old loop displayed that row as successful even though
   TextEdit had not changed, then the parent retried the job several times.

The candidate source therefore makes four narrow contract/state changes:

- accept an exact literal value as a valid task reference, replace those bytes
  with `{{name}}` before helper dispatch, and keep the named literal store as
  the only authoritative data channel;
- require the parent schema/prompt to use separate `oldText` and `newText`
  values for replacement instead of asking either model to re-type them;
- treat structurally complete multiline AppleScript emitted as plain assistant
  text as an invalid missing tool envelope, never execute it or report success,
  and make one bounded request for the required `run_applescript` call;
- after one successful replacement mutation, block every further mutation and
  permit only the existing read-back verification path.

The focused macOS Xcode rerun covering `AppleScriptLoopTests`,
`AppleScriptToolDispatchLiteralsTests`, `AppleScriptEffectClassifierTests`,
`AppleScriptToolSelectionGuidanceTests`, `AppleScriptModelRoutingTests`, and
`AppleScriptAppKnowledgeTests` exited 0 on 2026-07-20. The relevant cases
include `rawScriptTextRequiresToolEnvelope`,
`textEditReplacementRequiresReadBack`, and `referencedLiteralContract`. This
remains **PARTIAL**: the exact source has not yet been rebuilt and replayed in
the visible Release app, so no user-facing fix is claimed from the tests.

### Failed first Release candidate (visual evidence, 2026-07-20)

The first ad-hoc signed Release candidate used bundle id
`com.dinoki.osaurus.applescriptemergency20260720`, executable SHA-256
`dec06e2c64770af47233dcaf182df95adabe157df5e01be8fd8760fe4b7da253`, and
isolated root
`/private/tmp/osaurus-applescript-emergency-live-root-20260720`. Computer Use
visibly showed Accessibility and Screen Recording granted. Storage visibly
showed the primary Models Directory as `~/models` and 55 local models, but
Computer Use -> Models -> Model offered only `Choose automatically` and the
curated Osaurus AppleScript 8B. It did not offer the installed
`JANGQ-AI/AppleScript-8B-JANG_6M` or
`JANGQ-AI/AppleScript-16B-A4B-JANG_4M` bundles.

That is a **FAILED-LIVE** candidate, not a pass. The owning bug was that the
candidate enumerated `ExternalModelLocator` only; `~/models` is the primary
Models Directory and is owned by `ModelManager`'s merged local inventory. The
follow-up source now uses `ModelManager.localModelsSnapshotNonBlocking()` with
the same strict dedicated AppleScript id prefixes. Both primary-directory and
external-source fixtures pass, but the rebuilt picker has not yet been checked
visually.

### Fifth Release candidate: exact 16B completion and feedback regression

Status for this narrow row: **VERIFIED-LIVE**. Broader AppleScript, Computer
Use, reasoning-policy, cache-codec, and model-family rows remain separately
PARTIAL unless named below.

The exact app was the ad-hoc-signed Release build at
`/private/tmp/osaurus-ssd-stable-release-derived-20260721/Build/Products/Release/osaurus.app`,
bundle id `com.dinoki.osaurus.ssdstableproof20260721`, executable SHA-256
`e28cc1a1aad58514fa2cb325cf7f95bb098b6a93cd2a82f7e4f1ceae9244fb7d`,
isolated root
`/private/tmp/osaurus-ssd-stable-finalproof-root-20260721-0320`, and exact
resolved vMLX revision
`b87cdd6b2a9f05f600461e41b239b7197151d9ff`. The visible parent was
`Ornith 1.0 9B MXFP8` with Thinking Off. The global native AppleScript helper
was exact `JANGQ-AI/AppleScript-16B-A4B-JANG_4M`; the agent's AppleScript
choice was visibly `Choose automatically`, exercising inheritance rather than
a hard-coded per-agent helper.

The first build of this merged-pin candidate was a real failed live row. Its
16B proposal compiled but used invalid TextEdit runtime semantics. After the
runtime error the helper returned empty/EOS, while `AppleScriptLoop` entered
verification merely because one script had been attempted. That blocked a
corrective mutation and ended `Failed: Applescript`; TextEdit remained exactly
`Hello from OracHQ`. The owning state bug was the use of
`scriptsExecuted > 0` instead of successful execution. Current source enters
verification only after `succeeded > 0`, permits one bounded idempotent
correction after a real execution failure, and requires the authoritative
`{{newText}}` data placeholder before any proposed replacement can reach
compile, approval, or execution. It does not rewrite or execute a model script
automatically.

The final candidate was then operated through the real UI as follows:

1. TextEdit visibly contained exactly `Hello from OracHQ` and was marked
   Edited. The user sent the exact reported prompt, `Change the text in the
   file from “Hello from OracHQ” to “Hello again”.`
2. Dispatch recorded frontmost/working app `TextEdit`, a grounded task, and
   authoritative `oldText`/`newText` literals. The exact 16B helper emitted
   one bounded delimiter-based replacement using both placeholders. The
   approval card visibly contained no Save, shell, file, keystroke, formatting,
   or unrelated-app action.
3. After approval, TextEdit visibly contained exactly `Hello again` once and
   remained Edited/unsaved. The helper made one mutating call followed by one
   read-only verification, then stopped. Osaurus visibly finalized success in
   25.3 seconds; the parent answer reported TTFT 1.42 seconds, 50.8 tok/s, and
   25 tokens. There was no duplicate write and no Save workflow.
4. In the same chat the user sent only informational feedback: `For your
   information, the TextEdit edit completed successfully.` The parent replied
   with a plain acknowledgement at TTFT 1.65 seconds and 50.9 tok/s. No
   `mac_query`, time/date query, AppleScript, or other tool was invoked.

The final focused Xcode run includes the new
`replacementRequiresNewTextPlaceholder`,
`failedReplacementCanCorrectBeforeReadBack`, global-helper inheritance, and
stable-warmup-boundary controls. It completed with 176 passed, 0 failed, 0
skipped at
`/private/tmp/osaurus-ssd-stable-release-derived-20260721/Logs/Test/Test-OsaurusCoreTests-2026.07.21_04-35-44--0700.xcresult`.

This proves the reported common 16B TextEdit replacement, successful-action
finalization, no-unrequested-Save behavior, and feedback-only no-tool behavior
for this exact configuration. JANGQ 8B, requested Save, denial/cancellation,
larger-document and Unicode/quote replacement, generic Computer Use, Spawn,
and every reasoning-on control remain PARTIAL / NOT RUN in this candidate.
