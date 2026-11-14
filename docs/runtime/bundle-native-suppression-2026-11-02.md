# Bundle-native token suppression

Status: the exact-final-pin host build and 258 focused tests pass. Real-model and UI qualification remain pending.

Osaurus previously omitted `suppress_tokens` while reading a local model's generation defaults, although the runtime's native generation-config decoder supports it. The local app now retains the bundle-declared integer list through the exact-directory defaults snapshot, JANG-over-HF merge, selected thinking-mode overlay, effective settings, and `GenerateParameters.suppressTokens`.

Omission inherits the lower-priority bundle value. An explicit empty list in the higher-priority bundle or mode clears that inherited list. Explicit temperature, top-p, top-k, output-token and seed overrides preserve the exclusion list. No API or UI suppression override is introduced: the existing request schema has none. Invalid list fields remain absent under the host's existing field-by-field metadata parser; valid integer arrays match the runtime decoder.

No exclusion is invented. An omitted or empty list leaves suppression inactive. This change does not add reasoning floors, EOS rescues, sampler defaults, or output caps.

`BundleNativeSuppressionTests` covers native-decoder agreement, invalid shapes, omission/empty overlays, exact-directory loading, explicit sampler precedence, and the actual CPU logits processor across successive steps. `LocalGenerationDefaultsTests.vmlxParity` now asserts adoption instead of naming the old omission as a known gap.

Completed with Xcode Swift6.4 and an isolated build/profile/models directory: `swift build --build-tests --jobs 2`, then `swift test --skip-build --jobs 2` for the affected suppression, defaults, thinking-mode, generation plumbing, repetition/seed carrier, agent settings/editor/speculation, Responses, MTP sampler-preservation, adapter resolution and both pin-contract suites. The exact-final-pin run at host `5982d2637d2b71095de15da9d52ca3d298100f58` passed **258 tests in 16 suites** in 1.734 seconds. No full model was loaded; the processor uses controlled CPU logits, and the host dispatch fixture is explicitly nonlocal. Existing speculation carrier/planning tests preserve nil/false/true and Off strategy selection without claiming actual inference.

The initial missing-metallib lookup failure and a 248-test run with one invalid fixture capability request remain retained. The fixture incorrectly requested a local-only speculation setting on a nonlocal fake; the corrected test explicitly verifies rejection before service invocation, while the shared sampler fixture declares its boolean reasoning capability. Production capability validation is unchanged. The exact build-produced metallib was provisioned at the test executable lookup path and archived before subsequent builds; no shader or production behavior was changed to make the harness pass.

Still required: build and exercise the app with a bundle that actually declares exclusions, checking saved/effective settings, selected mode, full tool continuation and actual token output. Source inspection and these unit fixtures are not per-family runtime/UI proof.

Speculation and architecture limits remain separate: DSpark and DFlash2 use existing eligibility/fallback behavior for active processors. Native MTP routes its static suppression processor through draft and verifier sampling. Native block-diffusion sampling does not use the AR logits processor; this patch does not claim native suppression support for that route. The separate parameter-parity audit retains that applicability gap and the pre-existing forced-behavior defects for investigation.


## Merged runtime consumed by this change

All four dependency surfaces and both pin-contract expectations now select merged
runtime `65f5156c89ff8ef70bd8a82aa3ab03e577f6fda6`
([runtime PR #720](https://github.com/osaurus-ai/vmlx-swift/pull/720)). It includes
the earlier merged output-limit correction from
[PR #719](https://github.com/osaurus-ai/vmlx-swift/pull/719) and the native generation
contract fixes: no automatic minimum reasoning floor, native diffusion EOS instead
of a nonempty-answer rescue, and immutable explicit/bundle suppression logits.
DeepSeek-V4-0731 Low restores its native empty prefix; its native High/Max contract
and the V4.1 contract remain intact.

Runtime-local qualification passed **21 encoder tests in one suite plus 77
contract tests in seven suites: 98 tests in eight suites**. The tested head and
merge have identical trees. The scope includes native 0731 prompt bytes, V4.1
encoder behavior, default versus explicit suppression, surviving probabilities,
unchanged caller aliases, rank/dtype coverage, native diffusion EOS and cache
commit through constant-logit CPU fixtures. Both Linux SwiftPM and Jinja CI lanes
passed. Advisory lint and the self-hosted Mac queue were not substituted for this
scope. No workflow or approval gate was overridden.

These are source/unit contracts, not real-family inference or UI proof. In
particular they do not establish speed, full model quality, long-context RAM,
media/tool/cache compatibility, or correct advanced settings for every installed
family. Existing failed attempts and earlier evidence remain retained. The host build/tests above cover the exact final pin. Appropriate real-model/UI
qualification remains required before a production-ready claim. No release/tag or Studio update
is part of this follow-up.
