# Nemotron Omni Live Voice PR Checklist - 2026-05-12

## Scope

This checklist tracks the Osaurus side of live voice input for Nemotron Omni
models. This branch pins `vmlx-swift-lm` to `fb8fb39`, which can consume
`UserInput.Audio`, preserves pre-encoded Parakeet/audio embeddings, exposes a
reusable retained live PCM buffer with a streaming cursor for VAD/call-mode
polling, adds a tracked Omni audio latency bench, and keeps media-placeholder
cache restore token-aware. Omni audio support is gated by
`ModelMediaCapabilities.supportsAudio`.

## Current Hookups

- `SpeechService` exposes `LiveVoiceAudioSnapshot` and `currentLiveAudioWAVData()`.
- `ThreadSafeAudioBuffer` retains a bounded copy of the active live voice PCM
  separately from the short chunks drained by the streaming STT worker.
- `FloatingInputCard.sendVoiceMessage(_:)` captures the WAV before stopping
  transcription and appends it as `Attachment.audio(..., format: "wav")` when
  the selected model supports audio.
- `ChatSession.buildUserChatMessage(...)` converts supported image/audio/video
  attachments into multimodal `ChatMessage` content parts. This closes the UI
  bridge gap where live voice appended `Attachment.audio` but the in-app
  send path could still serialize the turn as plain text only.
- `ModelRuntime.extractAudioSources(from:)` materializes `input_audio` into a
  temp audio file and hands `UserInput.Audio.url` to vMLX.
- `MLXBatchAdapter` now detects Nemotron Omni models and converts raw
  `UserInput.Audio` sources to `.preEncoded` audio embeddings before
  `processor.prepare(input:)`. Existing `.preEncoded` audio is preserved, which
  is the handoff point for a future live Parakeet/sound-projection component.
- `Packages/OsaurusCore/Package.swift` pins `vmlx-swift-lm` to `fb8fb39` so
  the app consumes the Swift live-voice handoff, live PCM streaming cursor,
  tracked `OmniAudioLatencyBench` harness, and media-placeholder-aware cache
  restore guard.
- Live voice timing is now visible in the normal debug path:
  - `FloatingInputCard` logs `snapshot_ms`, `wav_encode_ms`, `wav_bytes`,
    `sample_rate`, and `duration_ms` when a voice turn is captured.
  - `TTFTTrace` records `input_audio_count`, `input_audio_materialized_count`,
    `input_audio_bytes`, `input_audio_materialize_ms`, `prompt_prepare_ms`,
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
  `fb8fb3959ac97598c6b4ddeba0516f01d84ddf0e`. Re-run after the Nemotron Omni
  no-thinking default/profile fix also passed under Xcode's Swift toolchain.
- Focused Xcode-toolchain regression tests passed:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
  --filter 'ModelProfileRegistryTests/nemotron3_matchesNemotronProfile|MLXBatchAdapterTests/additionalContext_defaultsNemotronOmniThinkingOffButHonorsExplicitOptIn'`.
  This covers the shorter live model ids
  `dealign.ai/Nemotron-Omni-Nano-JANGTQ-CRACK` and
  `nemotron-omni-nano-jangtq-crack`, and the runtime default
  `enable_thinking=false` with explicit opt-in still honored.
- Focused UI/API attachment regression tests passed:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
  --filter 'ChatAttachmentSecurityTests|MultimodalContentPartTests'`.
  The tests cover the new user-message builder forwarding audio/video
  attachments when capabilities allow them, dropping audio/video when
  unsupported, and the existing `input_audio`/`video_url` mapping into vMLX
  `Chat.Message.audios` / `.videos`.
- Focused adapter pre-encode regression tests passed:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
  --filter MLXBatchAdapterTests/preencodeAudioSources_replacesRawAudioAndCountsInputs`.
  The helper replaces raw audio sources with encoder output and reports input,
  converted, and already-preencoded counts without requiring a model load.
- `OmniAudioLatencyBench` on `Nemotron-Omni-Nano-JANGTQ-CRACK` measured the
  Osaurus BatchEngine path at `1514.1 ms` raw PCM first semantic delta on
  turn 1, `1498.6 ms` raw PCM on turn 2, `208.9 ms` pre-encoded Parakeet on
  turn 1, and `201.8 ms` pre-encoded Parakeet on turn 2. The bench recorded
  `63` media-placeholder tokens, known media token IDs `[18, 27]`, media
  placeholders spanning prompt indices `12...74`, and a 64-token cache suffix
  that still contains media tokens. This is not output TTS TTFAB; it measures
  first text delta before a separate TTS model.
- Xcode app build passed from the workspace:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild
  -workspace osaurus.xcworkspace -scheme osaurus -configuration Debug
  -destination 'platform=macOS,arch=arm64'
  -derivedDataPath build/XcodeDerivedData-livevoice
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= build`.
  Re-run after the `fb8fb39` pin bump passed with the workspace resolver
  checking out `vmlx-swift-lm @ fb8fb39`. Re-run after the Nemotron Omni
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
- Built-app API smoke passed against
  `build/XcodeDerivedData-livevoice/Build/Products/Debug/osaurus.app` with
  `OSU_MODELS_DIR=/Users/eric/models` and
  `nemotron-omni-nano-jangtq-crack` loaded from
  `/Users/eric/models/dealign.ai/Nemotron-Omni-Nano-JANGTQ-CRACK`.
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
  Evidence files are under `/tmp/osaurus-live-smoke-evidence/` with the prefix
  `default_after_patch_`.
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
    `ps`). Evidence files are under `/tmp/osaurus-live-smoke-evidence/` with
    the prefix `preencode_after_patch_`.
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
- vMLX real-model bench passed on the local JANGTQ2 Omni-Nano bundle:
  `build/evidence-20260512/nemotron_omni_live_voice_jangtq2_clean_20260512_155446.log`
  in `vmlx-swift-lm`.
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
     `input_audio_materialize_ms`, `prompt_prepare_ms`, `first_token_ms`, and
     `first_chunk_ms`.
- Negative smoke:
  1. Select a text-only model.
  2. Send a voice message.
  3. Confirm no audio attachment is appended; only cleaned transcript text is
     sent.

## Remaining Work

- Add direct live pre-encoded audio emission from the Osaurus voice component.
  The adapter now preserves `.preEncoded` audio, but the current HTTP/UI WAV
  path still pays request-prep Nemotron audio encoding before the stream is
  returned.
- Add TTFAB coverage once a TTS backend is selected. Current evidence covers
  speech input into model output text, not first output audio byte.
- Keep audio attachment spillover and temp-file cleanup under review for longer
  call clips.
