# Local image approval policy ownership

Status: candidate; focused qualification is running. No merge or broad image/model readiness claim.

## Reproduced behavior

In the private native Release, a custom agent generated an image, the user chose and confirmed Always Allow, then a second image call prompted again. The persisted generic tool policy was `image:auto`, but the agent's `subagentPermissions` still resolved image to Ask. Default chat uses the global image-kind policy and has the same ownership mismatch. The original native requests, two image outputs, prompts, complete parent continuations, resource/rate data and error rows remain retained.

The exact old model-free XCTest baseline completed55tests with52pass,3failing parameterized declarations,0skip and19issues. Two failing declarations cover image approval ownership for generate/edit and default/custom agents; the third is the separate historical-tool-reference issue. The image permission tests observed repeated prompts, unchanged Ask owner policies and generic registry auto writes. Both affected production source files were also byte-identical to0.25.32; this was not introduced by the numerical Turbo candidate.

## Intended existing contract

`SubagentToolVisibility.effectivePermission` reads `SubagentConfigurationStore.permissionDefaults` for Default/main chat and the launching custom agent's `AgentSettings.subagentPermissions` otherwise. Generate and edit share the image capability. An explicit Deny remains authoritative regardless of the generic tool registry.

`ToolPermissionPromptService.requestPolicyApproval` already supports caller-owned policies: it returns Allow Once / Always Allow / Denied without changing ToolRegistry. `SpawnPermissionGate` already uses that service and persists into the matching default/custom owner. This correction follows the same ownership contract for local images; it introduces no preference, control label or permission namespace.

## Bounded correction

Only `ImageSubagentKind.swift` changes in product code. Local generate/edit share their existing policy decision and denial messages. Ask uses caller-owned approval; Always Allow updates only the launching owner's image policy. Allow Once and Deny do not persist a grant. A queued approval rereads the current owner policy before presentation. Cancellation while an approval is unanswered cannot save a grant. If a custom launcher disappears, its current explicit approval is not redirected into global defaults.

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
