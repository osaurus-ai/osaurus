# Native diffusion settings applicability

Status: focused validation passed on source 418; the later accessibility
correction below has syntax/diff checks and awaits a fresh build, tests and AX
inspection. Actual app UI and real-model/runtime qualification remain pending.
No model load, inference, Studio deployment or release action is included.

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

## Focused validation

The exact tested host/UI source is `418a10e02e2fbf4c5c561199b03674a52dfdbb5b`,
including host branch `4365e03f1965326380c423035a7e84dc20c12063`, with runtime
`65f5156c89ff8ef70bd8a82aa3ab03e577f6fda6`. Xcode Swift 6.4 compiled from the
isolated UI worktree using the closed suppression cache, two jobs, an isolated test
profile, empty model directory and disabled test Keychain. The source-path
rebuild completed in 710.74 seconds. All runs exited 0:

| Run | Tests | Suites | Test time |
| --- | ---: | ---: | ---: |
| UI applicability plus editor/draft/settings persistence/search/landing | 53 | 9 | 1.381s |
| Exact final host affected matrix | 258 | 16 | 1.748s |
| Deduplicated host and UI union | 293 | 22 | 1.966s |

All five new applicability/classification/persistence cases passed. The 53 UI and
258 host counts overlap 18 existing tests; they must not be added as 311 distinct
tests. The host matrix includes suppression/defaults, advanced-field dispatch,
thinking mode, generation plumbing, repetition/seed carriers, agent settings and
speculation, Responses, MTP sampler preservation, adapter resolution, runtime
source policy and image bridge contracts.

For CPU processor fixtures, only the exact cache-produced
`mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib` was copied to the
test binary's `mlx.metallib` lookup. SHA256:
`1ab6edb333f42c50879a628f35f3664b221d3e6096a60cb2ee2c4d7cb1147b8d`.
That injected lookup was archived after the passes and removed before any next
build; the produced source and all previous receipts remain preserved. The
private `parameter-parity/PAR04-REBASED-VALIDATION-FINAL-418a10e02.json` receipt
records source, binary, resource and raw-log hashes. There were no failures in
these three runs. They are metadata/host/controlled-CPU fixtures, not app UI or
real-model speed, cache, quality or family qualification.

## Accessibility follow-up from the fresh app

The fresh 418 app displayed the correct inactive saved values, but its AX tree
repeated each inactive label and omitted the numeric text. The retained
`parameter-parity/par04-ui-native-unsaved.ax.txt` captures that failure; the visual
values included 0, 0.8, 11 and 0.07. The inactive value stack now exposes one
read-only accessibility element with ignored children, the parameter title as
its label, and the saved text plus inactive explanation as its value. Inherited
rows expose the inactive status. Visual values, classification, editing and
persistence are unchanged. This correction has syntax/diff checks only; the
root agent will build a fresh app, rerun the 293-test matrix and inspect actual
AX labels/values. The test results above remain tied to the earlier 418 source.

Remaining acceptance: frozen Release app build; real agent creation/editing,
model switching, saving, navigation and relaunch. Inspect
both wide and narrow editor layouts and verify effective Max Tokens/Seed/Stop and
the native schedule through the actual request/runtime path. Source or isolated
tests alone do not establish live UI or model behavior.
