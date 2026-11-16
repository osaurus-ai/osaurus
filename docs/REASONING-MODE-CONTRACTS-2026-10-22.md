# Bundle-declared native reasoning modes

Diplodocus Preview4 declares think=reasoning_effort high and no_think=reasoning_effort low. It does not read enable_thinking. Previously the picker offered None/Low/High: None sent enable_thinking=false, leaving its native high default active, while Low selected the actual Off rail but was labelled as a lower effort.

The app now recognizes the explicit two-mode metadata contract and offers None (Off)/High. It sends exactly reasoning_effort low/high, preserves saved/native low requests as Off, and does not synthesize a request when the user leaves the choice unset. The mapping requires declared think/no_think modes, matching closed native efforts, supported transport and an explicit default mode; a plain low/high list retains its existing semantics. No model-name heuristic, template change, sampler override or reasoning close/open injection. Fixed-native-only contracts, Qwen low/medium/xhigh and Nemotron on/medium/off keep their existing paths.

Focused regression tests cover exact kwargs on UI/native API/legacy toggle paths, required-tool context, saved option migration, omitted controls and the negative plain-list case. Current actual app proof and test run are pending; do not call this merge-ready until they are recorded on the PR. The unrelated engine checkpoint pin retains865691945. No release/tag.


## Shared declaration formats (follow-up)

The same resolver now accepts `chat.reasoning_efforts` and
`capabilities.reasoning_efforts`, with `reasoning_effort_default` (or
`default_reasoning_effort`). These are native template kwargs. A positive-only
list exposes only those efforts; it does not invent an Off button. Explicit
unsupported Off or unknown named-mode requests are typed HTTP 400 errors through
ChatEngine and the local adapter. An omitted control remains omitted, including
required-tool turns. Existing ladder snapping remains unchanged.

Confirmed installed contracts without loading weights:

| Bundle group | Native contract | Resolution |
| --- | --- | --- |
| Qwen3.8 27B JANGH2 / JANG_4D | enable_thinking + low/medium/xhigh, default xhigh | Existing root reasoning block |
| Qwen3.8 Flash-Next JANG_1L/2L/4S/4M/6S/JANGH4 | Same template contract | Existing template closed-set fallback |
| Naive N0.5 Flash JANGHT2.5 | low/high/max, default max; no native Off | Added capabilities flat-list format |
| GLM 5.3 Flash JANGHT2.4 | low/high/max, default max; no native Off | Added chat flat-list format |

All eight installed Qwen templates hash to
`c3cf9e34abf4f9e36c2d72165aa9c132d3e2a725b6c2586aaa3a8af9d7a81041`.
Quantization names do not participate in reasoning contract resolution. This
source/metadata audit does not claim fresh generation proof on eight models.
The original closed-set resolver dates to commit 092e81cf (August 14); that is
not evidence of which release first encountered a newer flat-list bundle.

Tests cover both new placements, affine/JANGH/JANGHT names, exact declared kwargs,
required tools, omission, unsupported requests, typed API errors, explicit Off,
and malformed declarations. Existing Qwen and Nemotron tests remain in the same
suite. Source parity: same-model children forward explicit reasoning controls;
different-model children resolve their own model contract rather than inheriting
the parent's efforts. No sampler, template, seed, speculative-depth, memory-safety
or cache policy changes are included.

Validation status for this follow-up: focused tests and fresh app proof pending.
The earlier native Off/High app proof applies to #3166, not to this follow-up.
RAM/checkpoint ownership and all-family long-context qualification remain open.
