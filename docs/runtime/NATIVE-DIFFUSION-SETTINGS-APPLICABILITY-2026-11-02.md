# Native diffusion settings applicability

Status: implementation and regression fixtures prepared; syntax/diff checks pass.
Focused execution, build and live UI validation remain pending. No model load,
inference, Studio deployment, publishing or release action is included.

The shared agent generation editor previously displayed autoregressive sampling
and penalty controls as effective for native DiffusionGemma. Its runtime instead
uses the bundle's denoising schedule and does not call the ordinary AR sampler or
penalty processor. Carriage in GenerateParameters does not establish consumption.

The editor now uses small local `config.json` metadata and the exact registered
`model_type=diffusion_gemma` to identify this route, including renamed bundles.
Unknown/remote models retain existing presentation. Decision models, AR targets
with diffusion drafters, architecture/name hints and unregistered type aliases do
not select native diffusion. Classification rereads the bounded metadata file
when the existing model/capability task refreshes; no new cache or model load is
introduced.

Temperature, Top P, Top K, Min P, repetition penalty, frequency penalty and presence
penalty stay visible but read-only for native diffusion. Saved Custom text remains
visible with an inactive explanation. Inherited rows say the setting is not used
rather than displaying an AR number as effective. The summary distinguishes the
inactive count from total configured overrides. Both creation and editing use
this same view.

This is presentation only. The draft, Codable/storage shape and request values
are unchanged; model changes never clear or rewrite saved/draft overrides.
Explicit Reset remains a user action. Max Tokens, Seed, Stop and existing native
prompt/reasoning/speculation capability controls remain available. No native
schedule, generation default, runtime admission or sampler mapping is changed.

Regression fixtures cover exact metadata classification, renamed local metadata,
changed/missing/malformed/oversized metadata, the seven-field matrix, explicit
zero/false/empty values, unsaved text, JSON round-trip and agent save/reload across
AR/native/AR model selection. The existing field titles and landing anchors stay
unchanged and already appear in SettingsSearchSelfFindProbe. The search catalog
and guide explain the new applicability state.

Remaining acceptance: focused AgentGenerationApplicabilityTests and persistence
suite plus neighboring editor/redesign/settings/search tests; app build; real
agent creation/editing, model switching, saving, navigation and relaunch. Inspect
both wide and narrow editor layouts and verify effective Max Tokens/Seed/Stop and
the native schedule through the actual request/runtime path. Source or isolated
tests alone do not establish live UI or model behavior.
