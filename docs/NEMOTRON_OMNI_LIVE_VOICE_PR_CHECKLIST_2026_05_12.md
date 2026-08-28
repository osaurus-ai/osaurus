# Nemotron Omni Live Voice PR Checklist - 2026-05-12

## Scope

This checklist tracks the Osaurus side of live voice input for Nemotron Omni
models. This branch pins `vmlx-swift-lm` to `6561a72`, which can consume
`UserInput.Audio`, preserves pre-encoded Parakeet/audio embeddings, exposes a
reusable retained live PCM buffer with a streaming cursor for VAD/call-mode
polling, adds tracked Omni audio latency and chunk-stability benches, and keeps
media-placeholder cache restore token-aware. The pin also carries the refreshed
Parakeet/RADIO host-integration docs, the current proof that independently
encoded Parakeet chunks are not safe to concatenate, and the DSV4 Flash
long-prompt HSA top-k plus overlap-compressor state fixes. Omni audio support
is gated by `ModelMediaCapabilities.supportsAudio`.

## Current Hookups

- `SpeechService` exposes `LiveVoiceAudioSnapshot` and `currentLiveAudioWAVData()`.
- `ThreadSafeAudioBuffer` retains a bounded copy of the active live voice PCM
  separately from the short chunks drained by the streaming STT worker.
- `FloatingInputCard.sendVoiceMessage(_:)` captures the live PCM snapshot and
  WAV fallback before stopping transcription, stores the PCM against the
  generated audio attachment id in `LiveVoiceAudioInputRegistry`, and appends
  the WAV as `Attachment.audio(..., format: "wav")` when the selected model
  supports audio.
- `FloatingInputCard` now creates a stable live voice attachment id at recording
  start, periodically asks the resident Nemotron Omni runtime to pre-encode
  retained PCM snapshots while capture is active, and force-runs one final
  pre-encode during transcript cleanup before the chat message is submitted.
- `ChatSession.buildUserChatMessage(...)` converts supported image/audio/video
  attachments into multimodal `ChatMessage` content parts. This closes the UI
  bridge gap where live voice appended `Attachment.audio` but the in-app
  send path could still serialize the turn as plain text only.
- `ChatMessage` carries optional in-process `LocalAudioSamples` aligned to each
  OpenAI `input_audio` content part. The JSON-visible message still retains
  the portable base64 audio fallback for persistence and remote providers.
- `LiveVoiceAudioInputRegistry` can retain a fresh `.preEncoded` audio embedding
  for the same attachment id. `ModelRuntime` only consumes it when the stored
  source sample count and sample rate exactly match the final local PCM, so a
  stale periodic pre-encode cannot silently drop the tail of the user's speech.
- `ModelRuntime.extractAudioSources(from:)` maps aligned local PCM to
  `UserInput.Audio.samples` so current in-app voice turns avoid the
  WAV/base64/temp-file re-decode path, and maps fresh live pre-encoded audio to
  `UserInput.Audio.preEncoded` so vMLX skips request-time Parakeet. Valid API
  `input_audio` WAV payloads now decode directly to `UserInput.Audio.samples`;
  non-WAV and malformed audio still falls back to temp-file
  `UserInput.Audio.url` materialization for AVAudioConverter coverage.
- `ModelRuntime.preencodeLiveVoiceAudioIfResident(...)` pre-encodes against the
  already-resident model only. It does not cold-load a multi-GB Omni model from
  the voice UI; call-mode setups should keep the target model resident.
- `MLXBatchAdapter` now detects Nemotron Omni models and converts raw
  `UserInput.Audio` sources to `.preEncoded` audio embeddings before
  `processor.prepare(input:)`. Existing `.preEncoded` audio is preserved, which
  is the handoff point for a future live Parakeet/sound-projection component.
- `Packages/OsaurusCore/Package.swift` pins `vmlx-swift-lm` to `6561a72` so
  the app consumes the Swift live-voice handoff, live PCM streaming cursor,
  tracked `OmniAudioLatencyBench` and `OmniAudioChunkStabilityBench`
  harnesses, and media-placeholder-aware cache restore guard, plus current
  Parakeet/RADIO integration documentation and the DSV4 Flash causal HSA
  indexer plus ratio-4 overlap-compressor state fixes.
- Parakeet/RADIO source, function, and documentation verification is an
  explicit release guard: the source repo must contain the encoder functions
  and bench/docs, the live remote must contain the pinned commit, Osaurus must
  resolve the same revision, and this check must be repeated after any final
  Osaurus commit/push before calling the PR ready.
- Live voice timing is now visible in the normal debug path:
  - `FloatingInputCard` logs `snapshot_ms`, `wav_encode_ms`, `wav_bytes`,
    `sample_rate`, and `duration_ms` when a voice turn is captured.
  - `TTFTTrace` records `input_audio_count`, `input_audio_materialized_count`,
    `input_audio_bytes`, `input_audio_local_sample_count`,
    `input_audio_local_preencoded_count`, `input_audio_materialize_ms`,
    `prompt_prepare_ms`,
    `processor_prepare_ms`, `omni_audio_preencode_input_count`,
    `omni_audio_preencode_converted_count`,
    `omni_audio_preencode_existing_count`, `omni_audio_preencode_ms`,
    `chat_audio_count`, `first_token_ms`, and `first_chunk_ms`.
  - OpenAI-compatible `/chat/completions` debug builds attach the same
    `TTFTTrace` to API requests and emit `/tmp/osaurus_ttft_trace.log` on SSE
    finish, tool-call finish, JSON finish, and handled API errors. This records
    endpoint/model/media counts plus the HTTP stream phases needed for
    headless audio latency benches.

## Verified Evidence

- `swift build --target OsaurusCore` passed after the live voice snapshot
  changes, after the `vmlx-swift-lm` pin bump to `638024b`, and after the
  TTFT/live-voice timing instrumentation. It also passed after the API-level
  `/chat/completions` trace recorder was added. Re-run after the `fb8fb39`
  media-cache pin bump passed with SwiftPM resolving `vmlx-swift-lm` at
  `fb8fb3959ac97598c6b4ddeba0516f01d84ddf0e`. The follow-up `b57fe98` pin
  adds the refreshed Parakeet/RADIO integration docs, the `81c8ef7` pin adds
  the Parakeet chunk-stability bench, and the `f728718` pin adds the DSV4
  Flash causal HSA top-k fix. The current `6561a72` pin also preserves DSV4
  ratio-4 overlap-compressor state across single-token decode calls. Re-run
  after the Nemotron Omni no-thinking default/profile fix also passed under
  Xcode's Swift toolchain.
- Focused Xcode-toolchain regression tests passed:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
  --filter 'ModelProfileRegistryTests/nemotron3_matchesNemotronProfile|MLXBatchAdapterTests/additionalContext_defaultsNemotronOmniThinkingOffButHonorsExplicitOptIn'`.
  This covers the shorter live model ids
  `dealign.ai/Nemotron-Omni-Nano-JANGTQ-CRACK` and
  `nemotron-omni-nano-jangtq-crack`, and the runtime default
  `enable_thinking=false` with explicit opt-in still honored.
- After current vMLX pin bumps, focused pin/provider/profile suites must run
  under Xcode's Swift toolchain on this machine; the Command Line Tools Swift
  path does not provide the Swift `Testing` module used by the shared tests.
- Parakeet/RADIO source/push/doc checks have passed repeatedly for the live
  library pin:
  `git ls-remote origin refs/heads/main` for `vmlx-swift-lm` returns
  `6561a72f93d6cd5e0202e8067b53fed5cf21a660`; `git grep` against the committed
  `vmlx-swift-lm` tree confirms `NemotronHParakeetEncoder`,
  `remapParakeetWeights`, `NemotronHRADIOVisionModel`,
  `remapRadioWeights`, `OmniAudioChunkStabilityBench`,
  `PARAKEET-RADIO-INTEGRATION.md`, and
  `docs/benchmarks/omni-audio-chunk-stability-2026-05-13.md`; Osaurus pins the
  same revision in `Packages/OsaurusCore/Package.swift` and the tracked
  resolved files; the Osaurus-resolved checkout also contains the same encoder
  functions, docs, and DSV4 causal top-k/overlap-compressor helpers.
- Focused UI/API attachment regression tests passed:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
  --filter 'ChatAttachmentSecurityTests|MultimodalContentPartTests'`.
  The tests cover the new user-message builder forwarding audio/video
  attachments when capabilities allow them, dropping audio/video when
  unsupported, and the existing `input_audio`/`video_url` mapping into vMLX
  `Chat.Message.audios` / `.videos`.
- Focused API WAV side-channel regression test passed:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
  --package-path Packages/OsaurusCore --filter
  MultimodalContentPartTests/mapping_audioWavDecodesToSamples`.
  This covers OpenAI-compatible `input_audio` WAV payloads mapping directly to
  `UserInput.Audio.samples` instead of a temp-file `UserInput.Audio.url`.
- API WAV side-channel regression set passed:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
  --package-path Packages/OsaurusCore --filter
  'MultimodalContentPartTests|MaterializeMediaDataUrlMCDCTests|MLXBatchAdapterTests/preencodeAudioSources_replacesRawAudioAndCountsInputs'`.
  This passed with `25` tests in `3` suites, preserving video/audio temp-file
  fallback coverage while adding the valid-WAV direct PCM path. The two
  `.preEncoded` mapping tests remain skipped for the existing standalone
  `MLXArray`/`default.metallib` fixture limitation.
- Xcode debug app build passed after the API WAV side-channel change:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild
  -workspace osaurus.xcworkspace -scheme osaurus -configuration Debug
  -destination 'platform=macOS,arch=arm64' ... build`. The build resolved
  `vmlx-swift-lm @ f728718`.
- Rebuilt debug app `/chat/completions` smoke passed for an
  OpenAI-compatible streaming `input_audio` WAV request. The cold-load request
  returned HTTP `200` and TTFT trace metrics
  `input_audio_materialized_count=0`, `input_audio_local_sample_count=1`,
  `omni_audio_preencode_converted_count=1`, `load_container_done=2388.6 ms`,
  `prompt_prepare_ms=1447`, and `first_token_ms=75`. A resident repeat also
  returned HTTP `200` with `load_container_done=0.1 ms`,
  `input_audio_materialized_count=0`, `input_audio_local_sample_count=1`,
  `omni_audio_preencode_converted_count=1`, `prompt_prepare_ms=1415`, and
  `first_token_ms=71`. This proves valid API WAV now reaches the same local
  PCM side channel as in-app voice before the Parakeet pre-encode adapter.
- Focused adapter pre-encode regression tests passed:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
  --filter MLXBatchAdapterTests/preencodeAudioSources_replacesRawAudioAndCountsInputs`.
  The helper replaces raw audio sources with encoder output and reports input,
  converted, and already-preencoded counts without requiring a model load.
- Focused local live-PCM bridge regression tests passed:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
  --filter 'ChatAttachmentSecurityTests/buildUserChatMessage_alignsLocalLiveAudioSamplesWithAudioInputs|MultimodalContentPartTests/mapping_usesLocalLiveAudioSamples'`.
  These cover attachment-id alignment from the live voice registry into
  `ChatMessage.audioInputsWithLocalSamples`, and `ModelRuntime` mapping the
  aligned input to `UserInput.Audio.samples`.
- Broader focused regression tests passed:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
  --filter 'ChatAttachmentSecurityTests|MultimodalContentPartTests|MLXBatchAdapterTests/preencodeAudioSources_replacesRawAudioAndCountsInputs|RemoteChatRequestEncodingTests'`.
  This rechecked the local PCM bridge together with multimodal
  audio/video mapping, the Nemotron Omni pre-encode adapter helper, and the
  DeepSeek remote `reasoning_effort` guard.
- After rebase onto `osaurus/main`, the post-rebase focused package
  suite passed with `48` tests in `6` suites:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
  --package-path Packages/OsaurusCore --filter
  'RemoteChatRequestEncodingTests|RuntimePolicySourceTests/vmlxPinIncludesRuntimeHardening|MultimodalContentPartTests/mapping_audioWavDecodesToSamples|MaterializeMediaDataUrlMCDCTests|MLXBatchAdapterTests/preencodeAudioSources_replacesRawAudioAndCountsInputs|LiveVoiceResidentPreencodeIntegrationTests'`.
  The gated real-model test skipped in this default run, as intended.
- After the resident live-preencode scheduler landed, the same broader focused
  suite passed again with `46` tests in `4` suites. The two direct `.preEncoded`
  mapping tests are present but disabled because constructing a standalone
  `MLXArray` fixture in the SwiftPM test process currently fails to load
  `default.metallib`; production embeddings are produced inside
  `ModelContainer.perform`.
- A gated real-model integration test now exists for the resident live voice
  pre-encode path. It requires a local Nemotron Omni bundle, an audio fixture,
  and an MLX metallib from the app build:
  `OSAURUS_RUN_REAL_OMNI_PREENCODE=1 OSU_MODELS_DIR=<models-root>
  OSAURUS_OMNI_MODEL=<local-omni-id> OSAURUS_OMNI_AUDIO=<audio-file>
  OSAURUS_MLX_METALLIB=<default.metallib>
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
  --package-path Packages/OsaurusCore --filter
  LiveVoiceResidentPreencodeIntegrationTests`. The test warms a resident
  Nemotron Omni model, runs `preencodeLiveVoiceAudioIfResident(...)` on a real
  audio file, checks `status=stored`, checks exact source sample count/rate
  metadata, verifies a fresh `.preEncoded` registry lookup, verifies the
  stale-count guard rejects mismatched samples, and simulates the composer
  submit path by storing the final PCM snapshot under the same attachment id,
  building `ChatSession.buildUserChatMessage(...)`, and requiring
  `ModelRuntime.mapOpenAIChatToMLX(...)` to consume `.preEncoded` audio.
  Local run with `OSAURUS_MLX_METALLIB` passed again after rebase with
  `warm_ms=2780`, `samples=80620`, `encode_ms=1310`,
  `embedding_shape=[63, 2688]`, and `composer_submit=preencoded`. The prior
  post-composer assertion run also passed with `warm_ms=2807`,
  `samples=80620`, `encode_ms=1312`, `embedding_shape=[63, 2688]`, and
  `composer_submit=preencoded`; earlier run before the composer-submit
  assertion recorded max RSS about `13.1 GB`.
- `OmniAudioLatencyBench` on `Nemotron-Omni-Nano-JANGTQ-CRACK` measured the
  Osaurus BatchEngine path at `1514.1 ms` raw PCM first semantic delta on
  turn 1, `1498.6 ms` raw PCM on turn 2, `208.9 ms` pre-encoded Parakeet on
  turn 1, and `201.8 ms` pre-encoded Parakeet on turn 2. The bench recorded
  `63` media-placeholder tokens, known media token IDs `[18, 27]`, media
  placeholders spanning prompt indices `12...74`, and a 64-token cache suffix
  that still contains media tokens. This is not output TTS TTFAB; it measures
  first text delta before a separate TTS model.
- `OmniAudioChunkStabilityBench` on the same model and 5.0388 s audio fixture
  measured `10` prefix-vs-next/final comparisons, `10` unstable comparisons,
  and `stable_tokens_default=0` for every comparison at tolerance `0.01`.
  This confirms current Parakeet outputs are not prefix-stable and should not
  be concatenated from independently encoded live chunks.
- Xcode app build passed from the workspace:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild
  -workspace osaurus.xcworkspace -scheme osaurus -configuration Debug
  -destination 'platform=macOS,arch=arm64'
  -derivedDataPath build/XcodeDerivedData-livevoice
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= build`.
  Re-run after the `fb8fb39` pin bump passed with the workspace resolver
  checking out `vmlx-swift-lm @ fb8fb39`; the current dependency pin is
  `vmlx-swift-lm @ 6561a72`. Re-run after the Nemotron Omni
  no-thinking default/profile fix passed.
  Xcode still reports the local CoreSimulator framework mismatch, but the macOS
  app build succeeds.
- No-model-load API trace smoke passed against the same built app on port 4242:
  - JSON `/chat/completions` with an unknown model returned HTTP 404 in
    `5.3 ms` total and wrote a trace block containing `http_json_error_written`,
    endpoint/model/media counts, and `http_response_status=404`.
  - SSE `/chat/completions` with an unknown model returned an in-band SSE error
    with HTTP 200 in `4.2 ms` total and wrote a trace block containing
    `http_sse_error_written`, endpoint/model/media counts, and
    `http_response_status=200`.
- Built-app API smoke passed against the debug app with
  `nemotron-omni-nano-jangtq-crack` loaded from a local model bundle.
  The health endpoint reported the model loaded, and OpenAI-compatible
  `/chat/completions` accepted `input_audio` WAV content.
- A pre-fix default API smoke exposed the live-call visible-output bug: the
  model streamed only `reasoning_content` for text/audio turns unless the
  request explicitly set `enable_thinking=false` / `reasoning_effort=no_think`.
  Root cause was model-id matching: the live id
  `nemotron-omni-nano-jangtq-crack` did not match `NemotronThinkingProfile`,
  so `MLXBatchAdapter` fell through to generic `enable_thinking=true`.
- Rebuilt-app default API smoke after the fix passed with no request-level
  thinking overrides:
  - text cold load: first visible `content` delta `2588.8 ms`, total
    `2697.9 ms`, no `reasoning_content`; trace shows `load_container_done`
    `2377.1 ms`, `first_token_ms=62`, and
    `http_first_semantic_delta_kind=content`.
  - warm raw WAV audio: first visible `content` delta `3218.8 ms`, total
    `3574.7 ms`, text `A single electronic beep`, no `reasoning_content`;
    trace shows `input_audio_materialize_ms=1`, `prompt_prepare_ms=21`,
    `first_token_ms=109`, and a `3079.8 ms` wait inside
    `chatengine_streamDeltas_done` before HTTP receives the stream.
  - warm follow-up retaining the audio turn: first visible `content` delta
    `3264.6 ms`, total `3409.8 ms`, text `yes`, no `reasoning_content`;
    trace shows `input_audio_materialize_ms=1`, `prompt_prepare_ms=48`,
    `first_token_ms=111`, and `http_first_semantic_delta_kind=content`.
  - process RSS after the three-turn smoke was about `12.4 GiB`
    (`12723.6 MB` reported by `ps`), with `77128.4 MB` free+speculative VM.
- Rebuilt-app API smoke after the adapter pre-encode hook passed with no
  request-level thinking overrides:
  - cold text warmup: first visible `content` delta `2967.3 ms`, total
    `3077.8 ms`, visible text `Ready.`, no `reasoning_content`.
  - warm WAV audio: first visible `content` delta `1634.8 ms`, total
    `1893.5 ms`, visible text `A guitar is played in this audio.`, no
    `reasoning_content`; trace shows `input_audio_materialize_ms=0`,
    `omni_audio_preencode_input_count=1`,
    `omni_audio_preencode_converted_count=1`,
    `omni_audio_preencode_existing_count=0`,
    `omni_audio_preencode_ms=1368`, `processor_prepare_ms=14`, and
    `first_token_ms=50`.
  - repeated warm WAV audio: first visible `content` delta `1553.0 ms`, total
    `1667.1 ms`, visible text `Tick`, no `reasoning_content`; trace shows
    `omni_audio_preencode_ms=1327`, `processor_prepare_ms=15`, and
    `first_token_ms=47`.
  - process RSS after the smoke was about `12.4 GiB` (`12972.5 MB` reported by
    `ps`).
- Warm latency control from the built app:
  - text-only streaming request: first semantic SSE delta at `358.3 ms`, total
    `777.4 ms`.
  - first audio streaming request after warm text load: first semantic SSE delta
    at `5304.7 ms`, total `5513.7 ms`.
  - repeated audio streaming request: first semantic SSE delta at `1601.1 ms`,
    total `1815.3 ms`.
  - Osaurus logs showed model cache hits for the audio requests; audio
    `prepareInput` was `38 ms` on the first audio request and `16 ms` on the
    repeated request, while the vMLX `engine.generate(...)` await dominated the
    first semantic delta.
- `swift test --filter LiveVoiceAudioSnapshotTests` without `DEVELOPER_DIR`
  remains blocked by the local Command Line Tools selection: the package test
  target imports Swift `Testing`, which is unavailable from that path. Use
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` for Swift Testing
  checks on this machine.
- vMLX real-model bench passed on a local JANGTQ2 Omni-Nano bundle.
- That bench exercised text multi-turn, audio encoder smoke, full audio
  `LMInput`, mixed image + audio, media-salt isolation, reasoning toggle, and
  hybrid SSM warm-pass parity: `13 passed, 0 failed`, `bench_exit=0`.

## PR Gates

- Build: `swift build --target OsaurusCore` from `Packages/OsaurusCore`.
- Unit test when the toolchain supports it:
  `swift test --filter LiveVoiceAudioSnapshotTests`.
- Manual app smoke:
  1. Select a Nemotron Omni model that reports `supportsAudio=true`.
  2. Start voice input and speak a short utterance.
  3. Confirm the sent chat turn contains cleaned transcript text plus an audio
     attachment.
  4. Confirm the vMLX request includes `input_audio`.
  5. Confirm response stream starts and `/tmp/osaurus_ttft_trace.log` includes
     `input_audio_local_sample_count`, `input_audio_local_preencoded_count`,
     `input_audio_materialize_ms`, `prompt_prepare_ms`, `first_token_ms`, and
     `first_chunk_ms`.
  6. The gated real-model test covers the same attachment-id handoff into
     `ChatSession.buildUserChatMessage(...)`; this manual smoke still covers
     the actual microphone/paste/overlay UI loop.
- Negative smoke:
  1. Select a text-only model.
  2. Send a voice message.
  3. Confirm no audio attachment is appended; only cleaned transcript text is
     sent.
- Repeated Parakeet/RADIO source verification before merge:
  1. Confirm `vmlx-swift-lm` live remote `main` contains commit `6561a72`.
  2. Confirm source contains `NemotronHParakeetEncoder`,
     `NemotronHRADIOVisionModel`, `extractAudioEmbeds`, `extractImageEmbeds`,
     and `OmniAudioChunkStabilityBench`.
  3. Confirm Osaurus `Package.swift` plus workspace, app project, and
     `OsaurusCore` `Package.resolved` files pin full revision
     `6561a72f93d6cd5e0202e8067b53fed5cf21a660`.
  4. Confirm the Osaurus-resolved checkout contains the same Parakeet/RADIO
     functions and docs after dependency resolution.

## Remaining Work

- Do not replace periodic full-snapshot pre-encoding with chunk-concatenated
  Parakeet outputs on the current encoder. The chunk-stability bench shows the
  outputs are not prefix-stable. Any future causal/incremental path needs a
  stateful encoder proof with explicit lookahead and rollback semantics.
- Add TTFAB coverage once a TTS backend is selected. Current evidence covers
  speech input into model output text, not first output audio byte.
- Keep audio attachment spillover and temp-file cleanup under review for longer
  call clips.
