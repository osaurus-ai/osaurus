# Image-edit strength follows the engine contract

Status: original focused regressions pass; verification after rebasing onto the landed precision consumer, fixed Release app proof and PR landing pending.

The real development app reproduced a Qwen-Image-Edit failure after a valid request omitted `strength`. The app's shared image request builder supplied the historical partial-denoising default, `0.75`, although the engine declares partial strength unsupported and accepts only omission or `1`. Both admission estimation and execution used that invalid default. An earlier explicit `0.6` request correctly failed too; that failure must remain a rejection.

The request builder now receives the resolved engine limits used for validation. Omitted strength resolves to `1` when those limits prohibit partial denoising. Engines supporting partial denoising keep their existing default, and explicit caller values are preserved for validation. The catalogue/composer's strength capability reads the same declared support. Generation sampling, explicit parameters, cancellation, model handoff, agent-loop code and tool implementations are unchanged.

The metadata comes from the registered engine, so this also handles newly registered model families without a model-name allowlist. Missing metadata retains the existing compatibility policy. Both memory estimation and execution still share the same edit-request builder.

SOURCE EVIDENCE: based on Osaurus main `eb0e968c35657472826062d707b5e27a74ca69f9`, runtime pin `ca5bdc98313aafd080475207cda4c29ec85392ee`. The affected image source before this change is identical to the reproduced Release26 candidate. The independent image fix does not require the separate tied-head/cache-identity drafts.

Validation:

- 36 Swift Testing tests in six suites and 7 XCTest tests pass. The new suite exercises six cases through declared metadata, actual service/engine wrappers and composer projection: omitted full/partial strength, explicit rejection before the image loader, explicit supported strength preservation, and both composer capability states. Existing image producer, batch, composer, effective-parameter and Qwen/FLUX bridge checks pass.
- The native before-fix export contains both failures: explicit `0.6`, then omitted strength becoming invalid `0.75`. A third identical retry was denied to stop that failed workflow. The original generated image remains unchanged. Local evidence: `runtime-image-job-ui/BEFORE-FIX-FAILURE-RECEIPT.json` under `/Users/eric/vmlx-private-evidence/goal-storage-cache-resume-20261104`.
- The first compile and a subsequent incorrect NSError-string assertion are retained in the attempt logs. The final rejection test verifies the native error's typed field/value/allowed contract and the user-visible stream error, rather than Foundation's generic localized description.

LIVE EVIDENCE: the before-fix Release app generates the red cube and restores its invoking chat model, but editing fails as above. Fixed-build generation/edit, native effective parameters, parent restore and follow-up are pending. Component tests do not substitute for that app proof.

Known boundaries: the model omitted requested numeric size fields in the generation request, producing the 1024-square default instead of 512; no prompt coercion or dimension workaround was added. Repeated image approval after Always Allow leaves permission persistence unproven. The coordinator's best-effort memory-estimate catch means invalid parameters are not proven to preserve parent residency. Those observations do not justify modifying the agent loop or tool implementation in this change. No release or tag.

Current base: Osaurus main `66143dd33b9d8b9bdffe9b404b3fc47703d04e34`, runtime merge `309c2a2bae541188164af54f58e0740046f459a4`. The clean rebase carries the same image fix onto the actual landed consumer. The earlier four-file source snapshot and 43-test pass remain preserved; the affected component selection is rerun on this base before native promotion. The Gemma status-prose follow-up is bundled here to avoid an extra source-independent CI build. No loop or tool implementation edits.
