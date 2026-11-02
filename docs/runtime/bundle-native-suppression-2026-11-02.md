# Bundle-native token suppression

Status: implementation prepared; tests and live qualification pending.

Osaurus previously omitted `suppress_tokens` while reading a local model's generation defaults, although the runtime's native generation-config decoder supports it. The local app now retains the bundle-declared integer list through the exact-directory defaults snapshot, JANG-over-HF merge, selected thinking-mode overlay, effective settings, and `GenerateParameters.suppressTokens`.

Omission inherits the lower-priority bundle value. An explicit empty list in the higher-priority bundle or mode clears that inherited list. Explicit temperature, top-p, top-k, output-token and seed overrides preserve the exclusion list. No API or UI suppression override is introduced: the existing request schema has none. Invalid list fields remain absent under the host's existing field-by-field metadata parser; valid integer arrays match the runtime decoder.

No exclusion is invented. An omitted or empty list leaves suppression inactive. This change does not add reasoning floors, EOS rescues, sampler defaults, or output caps.

`BundleNativeSuppressionTests` covers native-decoder agreement, invalid shapes, omission/empty overlays, exact-directory loading, explicit sampler precedence, and the actual CPU logits processor across successive steps. `LocalGenerationDefaultsTests.vmlxParity` now asserts adoption instead of naming the old omission as a known gap.

After the Studio build finishes, run the focused `BundleNativeSuppressionTests`, `LocalGenerationDefaultsTests`, `ThinkingSamplingDefaultsTests`, `GenerationParameterPlumbingTests` and `MLXBatchAdapterTests` lanes in an isolated test environment. Then build and exercise the local app with a bundle that actually declares token exclusions, checking request/effective settings, selected mode, tool continuation and actual token output. Source inspection and unit tests are not per-family runtime proof.

Speculation and architecture limits remain separate: DSpark and DFlash2 use existing eligibility/fallback behavior for active processors. Native MTP routes its static suppression processor through draft and verifier sampling. Native block-diffusion sampling does not use the AR logits processor; this patch does not claim native suppression support for that route. The separate parameter-parity audit retains that applicability gap and the pre-existing forced-behavior defects for investigation.
