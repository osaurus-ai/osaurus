# Local image approval policy ownership

Status: draft candidate. Focused tests and native permission workflows are recorded below. The full119-case agent matrix completed58passed/57failed/4skipped. The independent sandbox fixture correction merged as PR3363; this branch is consuming it before refreshed whole-core CI. No image-fix merge, all-green, regression-free or broad image/model readiness claim.

## Reproduced behavior

In the private native Release, a custom agent generated an image, the user chose and confirmed Always Allow, then a second image call prompted again. The persisted generic tool policy was `image:auto`, but the agent's `subagentPermissions` still resolved image to Ask. The resolver also has a default/global owner branch, covered by component tests; the current built-in Orchestrator intentionally withholds image capability, so no currently exposed native Default image bug is claimed. The original native requests, two image outputs, prompts, complete parent continuations, resource/rate data and error rows remain retained.

The exact old model-free XCTest baseline completed55tests with52pass,3failing parameterized declarations,0skip and19issues. Two failing declarations cover image approval ownership for generate/edit and default/custom agents; the third is the separate historical-tool-reference issue. The image permission tests observed repeated prompts, unchanged Ask owner policies and generic registry auto writes. Both affected production source files were also byte-identical to0.25.32; this was not introduced by the numerical Turbo candidate.

## Intended existing contract

`SubagentToolVisibility.effectivePermission` reads `SubagentConfigurationStore.permissionDefaults` for Default/main chat and the launching custom agent's `AgentSettings.subagentPermissions` otherwise. Generate and edit share the image capability. An explicit Deny remains authoritative regardless of the generic tool registry.

`ToolPermissionPromptService.requestPolicyApproval` already supports caller-owned policies: it returns Allow Once / Always Allow / Denied without changing ToolRegistry. `SpawnPermissionGate` already uses that service and persists into the matching default/custom owner. This correction follows the same ownership contract for local images; it introduces no preference, control label or permission namespace.

## Bounded correction

Product changes are confined to `ImageSubagentKind.swift` and an additive full-outcome caller-owned approval entry point in `ToolPermissionPromptService.swift`. Existing generic approval behavior and narrow spawn-policy outcomes remain unchanged. Local generate/edit share their existing policy decision and denial messages. Ask uses caller-owned approval; Always Allow updates only the launching owner's image policy. Allow Once and Deny do not persist a grant. A queued approval rereads the current owner policy before presentation. Cancellation while an approval is unanswered cannot save a grant. If a custom launcher disappears, its current explicit approval is not redirected into global defaults.

Default-policy writes use the existing atomic mutate API. Custom-policy writes fetch the current agent on MainActor and use the existing AgentManager update API, matching the established spawn approval path. Its normal persistence/notifications remain in use rather than writing files behind the manager.

Model selection/identity, parameter preparation, the billable-remote approval branch and all image execution/residency/progress code are unchanged. There is no parser, sampler, prompt, cache, model-default, quota, RAM policy, tool schema, image numerical path or release change. Source equality of those sections is recorded separately; this bounds the source edit and does not substitute for live composition tests.

## Qualification ledger

Private retained evidence root: `/Users/eric/vmlx-private-evidence/sentry-inference-20261108/`.

- Original native failure and source cause: `cache-settings-contract-audit-20261109/image-discovery-audit1/zimage-contract-fix1/native-candidate1/chat-image-case1/CROSS-FLOW-CAUSE-REVIEW1.json` and `OUTPUTS-AND-RATES-RECEIPT1.json`.
- Exact original XCTest, command, child environment, logs, raw observations and xcresult: `cache-settings-contract-audit-20261109/image-crossflow-baseline1/`; derived summary and individual failures in `retroactive-merged-pr-audit-20261109/`.
- Current base715760a54a43942222eed3fff6a8ad348b17e24e, exact source hashes and unchanged-section checks: `image-permission-owner-20261109/SOURCE-BOUNDARY1.json`.
- Candidate1 focused11-suite plan, hashes, raw observations, log and xcresult: `image-permission-owner-20261109/component1/`. Real policy stores and the standard prompt-presenter seam are used; private empty model roots prevent accidental inference in Xcode tests. Result pending.
- Pending: fresh isolated Release UI, actual image calls/parent completion, Always Allow reuse, independent agent/default policy checks, settings navigation/relaunch, cancellation/recovery, applicable AgentLoop/AgentLoopFrontier matrix, exact-head CI and normal merge.

The independent history-question/tool-intent failure remains unfixed. Broad existing AgentLoop results45pass/70fail/4skip, RAM-gate failures, physical M2/M3 absence and incomplete other image-family rows are retained separately. Green focused checks cannot turn those rows into passing evidence. No billable remote generation is authorized for proof.

SOURCE EVIDENCE: `ImageSubagentKind.swift` permission path; existing `SpawnPermissionGate` caller-owned policy contract; new `ImagePermissionOwnershipRegressionTests`; exact source-boundary receipt above.

LIVE EVIDENCE: original native failure and old XCTest artifacts named above. Candidate runtime/UI/matrix results are pending and must be added before any qualified or merge-ready claim.

Candidate1 completed:90/90tests in11suites,0fail/0skip; all five actual xctest PID flags verified and source bytes unchanged. Component2 adds the explicit legacy generic-Auto cross-product and resolves any unexpected queued card so a regression fails with a concrete result; product source is unchanged. Candidate2 and native Release qualification remain pending.

## Run approval and prompt-choice parity

Pre-merge review found that the first candidate used the narrow spawn-style approval API, which omits Allow for This Task. It was not merged or claimed native-qualified. Its two90/90component runs and successful unlaunched Release build at0e7ab802a4919db2b2e56a701f23ff9feb17c1c8 remain retained, including frozen compiled outputs. The build completed before the attempted cancellation preflight, so no process was signaled.

An unchanged-production control then measured the related existing run-approval defect: generate/edit both advertised the task-wide choice, but no ToolPermissionRunScope grant was recorded, so two calls in the same task prompted twice and another task prompted again. The stable-install control preserves full configuration equality and captures the actual test PID and five whitelisted runtime flags. The first cold-install attempt's unrelated spawnPoolSeeded migration and missed short-lived external PID sample remain explicitly documented; neither is hidden nor attributed to image permission. Source/commands/raw observations/xcresults: `image-permission-owner-20261109/run-approval-baseline1/` and `run-approval-baseline2/QUALIFICATION.json`.

The final candidate keeps all existing approval choices in a real agent task. The full-outcome caller-owned API reports Allow for This Task without writing ToolRegistry. The image gate records it in the actual task lease already created by AgentToolLoop, checks Deny first, and rereads owner/run approval for queued calls. A new task receives a fresh lease; no grant is saved for run approval. Always Allow remains the launching owner's persistent policy. Callers without a real task lease do not advertise that unsupported choice. Existing spawn callers retain the same narrow outcome mapping and no run button.

Pending final candidate component, concurrent sibling approvals, fresh native Release, actual images/parent continuation, run/default/custom persistence and relaunch, full applicable evals and exact-head CI. No model/runtime readiness claim.

## Queued approval publication ordering

Candidate3 passed91/92test declarations in12suites,0skip. The one failing parameterized declaration failed for both default and custom launchers: a blocker held two sibling image requests in the approval queue; after the first Always Allow, both image cards were still presented (three total prompts including the blocker). The task-wide lease regression passed. Full failed sources, actual PID flags, observations, log, xcresult and compiled-output snapshot are retained in `image-permission-owner-20261109/component3/`.

The exact cause is `ToolPermissionPromptService.resolve`: it resumes the first caller and immediately pumps the next request before that caller can publish its policy/lease grant. Candidate4 supplies a synchronous MainActor commit callback for the caller-owned image request, executed after its continuation is claimed but before resume and queue advancement. Denials/cancellation and unknown/already-resolved IDs do not commit. The existing generic approval entrypoints and original narrow spawn-policy function remain byte-identical, with a nil callback; no additional async forwarding hop is introduced for spawn.

Candidate4 strengthens complete default-config/custom-agent equality checks, verifies image approval does not advance default/shared spawn authority revisions, exercises Deny despite a preexisting run lease, and covers both Always Allow and task-wide grants for queued default/custom siblings. A headless full-outcome request must not commit anything. Current component/native/eval/CI qualification remains pending.

Candidate4 complete:94/94test declarations in12suites,0fail/0skip. Default/custom queued sibling Always Allow and run-grant cross-products now present exactly two cards total (blocker plus one image approval); original C3presented three. Existing owner, task-expiration, Deny, cancelled/headless, exactly-once, full-store/other-agent equality and spawn authority checks pass. Raw metrics/child flags/source unchanged binding are in component4/. Fresh final native Release, GUI and broader eval/CI proof remain pending.

## Native qualification checkpoint, 2026-11-10 UTC

The preceding pending statements describe their original checkpoints. The final product source tested here is3c1e3655c830a5951ab11cde2fa1bcc8188fa5cd, with the official vMLX pin1bcd74ad182103a3b83941f61e57ee0bac23b330 and no local SDK overlay. The fresh private Release has binary SHA256f7fc512e703d1d1b463ca7a5d655d708c01b9011f8c6a3e47ad1dc40ba8711a5 and bundle version0.25.33 from the current canonical appcast/Makefile version. Earlier unlaunched binaries, packaging attempts and their metadata remain retained.

Actual Chat and Settings proof used an APFS clone of the closed prior private profile; its copied old history is distinguished from new requests. Four normal app launches captured the five intended actual PID flags, resources, rate data, private stores, complete turn snapshots and normal exits. No Terms, OS permission, real user profile, keychain, sampler or prompt override was introduced. A proof-created shared CLI directory fallback was restored to its original absence after the final normal quit, with a value equality guard against overwriting concurrent changes.

Native results under `image-permission-owner-20261109/native-candidate2/`:

- Agent A: actual Always Allow updated only its image policy and timestamp. Two real images and a third after normal relaunch completed without repeated approval. The matching agent editor showed Always Allow; global defaults, generic tool policy and runtime settings stayed unchanged for this approval.
- Task scope: after resetting A to Ask through the editor, two actual independent image calls were queued together. One Allow for This Task released both; both images and the parent completed. The full saved Ask-agent bytes stayed unchanged. The next user task asked again. Deny completed without an image or saved grant. Normal quit with another approval unanswered, followed by restart, still required explicit approval; no cancellation grant was saved.
- Agent B: created and configured through the real editor, with its own Ask policy and the same local image target. Despite A's saved grant and the legacy generic image-Auto setting, B showed its own approval. Its Always Allow changed only B's image policy and timestamp; A and the default/generic/runtime stores were byte-identical. Its real image and parent completed.
- Generate/edit composition: B selected the installed Qwen-Image-Edit target through the editor. A real edit used the prior tool result's source path, kept the model defaults, changed the blue ball to red, and reused the same image-kind grant. The parent resumed, Stop disappeared, input unlocked and the follow-up correctly recalled blue then red. The default30-step edit completed; its elapsed time and resources are evidence of this functional row, not a speed or low-RAM qualification.

Eight newly generated files are distinguished from the cloned old outputs: seven Z-Image-Turbo generations and one Qwen image edit. Seven visually match the requested object/edit; the orange-torus request produced a sphere-like object and remains a quality failure. All eight original PNGs, dimensions and hashes are retained in `GENERATED-CURRENT-OUTPUTS1.json` and `generated-current-native-originals1/`. Native rate/resource/Activity snapshots include every failed request and Foundation auxiliary generation; text-generation rate fields are nonempty. Diffusion images use elapsed time/steps rather than text tokens/s. Physical-footprint gates remain failed; no RAM improvement is claimed.

Failures are retained independently of the permission result:

- The first new request failed before approval because image models were unavailable to discovery. Re-selecting the same existing external image folder through the native picker exposed7records/6Ready; no discovery source patch was made and the filesystem/discovery cause is unassigned.
- The separate historical-reference bug still fails: asking what seed was used for each image returns correct facts plus a required-tool error. This candidate does not alter tool-choice enforcement.
- The recovery turn emitted a contradictory denial sentence before executing the approved image. Ordered native logs show15content deltas/73characters before the tool started, excluding that approval's later agent save as the insertion cause. `ChatEngine.streamResponseBody` logs a calls-only envelope when a call exists; that envelope is not evidence that pre-tool text was absent. Raw model/runtime cause remains unassigned; no output stripping or prompting rescue was applied. See `RECOVERY-DENIAL-ATTRIBUTION1.json`.
- Gemma QAT Thinking On executed two help calls with valid JSON and clean reasoning boundaries, but requested-answer quality was1/3: the empty image-setting lookup was followed by an invented location, and later history recall miscounted the empty result. Reset to model-default reasoning selected Off; a real UTC call and grounded follow-up passed2/2. A separate B image request in that default mode omitted the required prompt and used string-valued numbers, failing validation before permission. Model-versus-parser attribution for that malformed call is unassigned. It was not rerun until green; the Qwen parent was separately selected through saved agent settings for permission isolation.

The actual native Gemma QAT bundle was externally discovered as`OsaurusAI/OsaurusAI--gemma-4-E2B-it-qat-MXFP4`, not assumed to be the curated eval path. All four weight shards and relevant config/tokenizer/template files are byte-identical to the retained curated MXFP4 bundle; see `NATIVE-QAT-ACTUAL-BUNDLE-IDENTITY1.json` and `NATIVE-EVAL-QAT-BUNDLE-BYTE-PARITY1.json`. Defaults are temperature1.0/top-k64/top-p0.95. Explicit Thinking On requests carry`generation.enableThinking=true`; the Reset-to-default row is separately recorded. No BF16/source Gemma was loaded.

Contract correction: the current built-in Orchestrator intentionally does not expose image generation (`SubagentCapabilityRegistry.imageAvailable`). No native default-agent image prompt is claimed or force-enabled. The default-storage branch above is compatibility/component coverage of the existing policy resolver, not evidence of a current Orchestrator media bug. Actual native isolation covers two custom agents and unchanged global policy. After asynchronous external discovery, the Settings sidebar and On Device count both showed81installed models; the catalog separately showed123. Changing inventory observations are retained without inventing a count fix.

## Remaining gates at this checkpoint

Exact head3c1 has nine successful CI checks and one failed full core check. The retained xcresult reports12,632passed/1failed/61skipped,12,694declarations total, with expanded parameterized device counts preserved separately. The sole reported failure is`BuiltinSandboxToolsTests.sandboxWriteFile_generatesDocumentHostSideWithoutShellWrite`: its mock shell runner observed a`kill -0 12345`liveness probe. The background-exec fixture creates that mock PID and resets its runner without draining the registered poll. Controlled reproduction and scoped fixture cleanup are pending; neither the document-write assertion nor the CI gate is weakened. Raw job log, downloaded139MBxcresult archive, parsed summary and source review are in`ci-core-failure1/`.

The canonical AgentLoop76+AgentLoopFrontier43matrix is running on the fresh eval binary for3c1. Public Core bytes match the commit; the only private eval overlay retains evidence at cleanup. No grading, prompts, budgets, model defaults or runtime options were changed. Each source model is referenced through a private per-model symlink mirror so fixture model-folder operations cannot remove retained bundles. Commands, actual PID flags, fixture hashes, raw transcripts, forensics and resources are under`agent-matrix-candidate1/`. Raw scores and every failed-case attribution must be added after completion; earlier119case scores45pass/70fail/4skip remain intact and are not reclassified as passing.

Read-only Sentry-bot refresh2still lists21proposals and no new proposal after3361. Existing overlapping claims remain independently reviewed; no bot PR is adopted from its title, stack sample or green tests alone. Teammate-owned release work is untouched.

SOURCE EVIDENCE: final3c1 product files`ImageSubagentKind.swift`and`ToolPermissionPromptService.swift`; committed source binding`FINAL-COMMITTED-SOURCE-BINDING1.json`; unchanged generic/narrow approval boundaries`CANDIDATE4-SERVICE-BOUNDARY.json`; current Orchestrator visibility contract in`SubagentCapabilityRegistry.swift`.

LIVE EVIDENCE: native captures06–34;`APPROVAL-PERSISTENCE-IMMEDIATE1.json`;`TASK-ONLY-SAME-TASK-RECEIPT1.json`;`B-OWNER-PERSISTENCE-IMMEDIATE1.json`;`SHARED-CLI-PATH-RESTORE1.json`; per-launch Activity/rate/resource snapshots and four normal-exit receipts. Full matrix and corrected full CI are still required; this is not a merge-ready or model-family readiness claim.

## Completed full matrix, 2026-11-10 02:06 UTC

The exact3c1 matrix exited1 with source unchanged and sampler exit0:
AgentLoop42passed/30failed/4skipped of76;
AgentLoopFrontier16passed/27failed/0skipped of43;
combined58passed/57failed/4skipped of119. The119trial transcripts cover115executed unique fixtures; two three-trial fixtures account for the additional four transcripts. Four host/model-prerequisite skips produced no transcript. No score was rerun until green or regraded to hide a failure.

`agent-matrix-candidate1/MATRIX-REVIEW1.json` retains every failed/skipped case's raw checks, query when executed, judge output, rate/resource telemetry and transcript links. The57observed failures include wrong/missing tool arguments, unmet exact file/database postconditions, incorrect answers, omitted calls, batching/continuation errors, compaction expectations and incomplete exits. Their model-versus-parser/runtime/cache causes are unassigned without an appropriate controlled reference; this score alone does not establish57production bugs or57regressions from this change. The historical matrices remain65/50/4,54/61/4and45/70/4. Per-case outcome flips in both directions are recorded, not treated as causal improvement or regression from unseeded draws and differing sources/workspaces.

One long live-web case was sampled while actively decoding after its first search. It eventually failed with`lengthExhausted`,16,403total completion tokens across two steps and35.9tok/s, without the required shell/curl call. The existing normal response limit was unchanged. Its raw judge verdicts do not override the deterministic failed exit/tool checks. The in-progress sample and final failed observation remain in`LIVE-DATA-INPROGRESS-OBSERVATION1.json`and`LIVE-DATA-COMPLETED-FAILURE2.json`.

All437model-step diagnostics have a decode-rate field;11empty-output steps have0tokens/0tok/s and remain explicitly listed, rather than being described as positive throughput. Actual Activity records cover447inference requests, including judge and delegated-worker calls:418have empty generation overrides,3request the fixture's4,096output limit,13the fixture's8,192limit and13explicit Thinking On. No CLI sampler/thinking/output override was added. Bundle defaults remain temperature1.0/top-k64/top-p0.95. Sampled peak physical footprint6,929,207,424bytes exceeds4,002,479,278target weight bytes: RAMFAIL, not a low-RAM or model-readiness pass.

None of these115executed fixtures exposed or called the image tool. The matrix therefore provides broad surrounding-flow observations, while the changed image approval contracts are covered by the94component declarations and the actual native custom-agent flows. The new commit callback is supplied only by the image caller; the generic and old narrow policy APIs are byte-identical and default to nil. This source boundary is not an assignment of the57failures' underlying causes.

After the process exited,116exact transcript-referenced workspaces and the PID-owned runtime root were APFS-cloned into private evidence. The manifest hashes1,508files totaling51,548,838,102logical bytes with bounded8MiB streaming reads; symlinks are preserved rather than followed, and original temporary paths remain. See`agent-matrix-candidate1/retained-runtime1/MANIFEST.json`. Existing source bundles survived the private model-link operations. The final native summary is`native-candidate2/NATIVE-QUALIFICATION2.json`;`FINAL-FOUR-LAUNCH-RATE-LEDGER1.json`records all76inference/media Activity rows within the four actual launch/normal-quit windows, with no missing text-rate fields. Diffusion throughput uses elapsed time, not text tokens/s.

The controlled sandbox fixture baseline is building separately against original main715760a5plus only a regression test. Its actual background liveness poll and host document writer are exercised through mock runners for success, thrown-error and owned-child-cancellation exits. The no-shell-write assertion remains intact. No cleanup fix has been applied before that control runs. Corrected full CI and the independent tool-reference issue remain outstanding. Read-only bot refresh3still lists21unchanged proposals; no additional bot fix was adopted.

SOURCE EVIDENCE: final3c1 product binding and service-boundary receipts above; exact fixture inventory/source hashes in`agent-matrix-candidate1/PLAN.json`and`RESULT.json`; no public Core overlay.

LIVE EVIDENCE: completed119-case reports,119trial transcripts,`MATRIX-REVIEW1.json`, retained runtime/workspace manifest, native qualification2and the final four-launch rate ledger. These are raw failed and passing results; PR3362remains draft with its single failed core CI check until the fixture control and correction are qualified.

## Independent fixture correction and source reuse

PR3363 merged normally at794836cfbf128c10b6620e43c7fac232f3880d27.
The controlled original fixture reproduced the leaked liveness poll after
success, a thrown error and cancellation; its success row also observed the
original fake PID12345 from the failed image-PR CI. The corrected fixture
passed69/69declarations in four suites,0fail/0skip,71expanded argument rows.
All three lifecycle rows observed the poll in its original runner, no leftover
entry, zero shell calls in the next document runner and an unrelated entry
preserved. The original document no-shell assertion is byte-identical.

All ten exact-head CI checks succeeded. The successful workflow retains test
products rather than xcresults: its unchanged upload condition is failure or
cancellation only. The complete actual core log reports the sandbox suite
passed17.307seconds, the original document assertion passed0.007seconds and
the full command `Test Execute Succeeded`. The581,458,797-byte CI archive,
904,873,584-byte test binary, actual test plan, defined new-test symbols and
build manifest are retained. The compiled CI source tree equals the qualified
commit. The formatter does not expose every parameter row or an exact overall
declaration count; those CI numbers are not invented. Exact three-row counts
come from the retained local xcresult and actual testPID58357. Both the failed
baseline and first candidate compile failure remain retained.

Private receipts are under`sandbox-background-fixture-20261109/`:
`QUALIFICATION1.json`,`COMMITTED-SOURCE-BINDING1.json`,
`core-ci-verification1/VERIFICATION2.json`and`PR3363-MERGED1.json`.
The actual squash merge tree exactly matched the qualified source tree.
This correction changes only the unit fixture and its documentation.

This image branch is integrating that merged test correction and the completed
evidence document. App/runtime/config/dependency/eval sources must remain
byte-identical to the tested3c1 product projection. A new head binding records
that comparison before push. Existing native binaries, profiles, PNGs,
workspaces, raw failures and the full58/57/4matrix remain valid evidence for
that unchanged product projection; they are neither discarded nor described
as newly rerun or green. The affected combined unit/full-core checks must run
on the integrated head. No model/sampler/reasoning/prompt/cache change is
introduced to improve a score.

SOURCE EVIDENCE: original3c1 binding and the integration projection comparison;
merged test-only correction794836c, exact normal merge receipt and preserved
non-test Core equality.

LIVE EVIDENCE: original94/94image components, four actual native launches and
119-case matrix remain in their original paths. The independent correction's
69/69local xcresult, actual three lifecycle receipts and full successful CI
job/source archive remain separate. Integrated-head checks are pending.
