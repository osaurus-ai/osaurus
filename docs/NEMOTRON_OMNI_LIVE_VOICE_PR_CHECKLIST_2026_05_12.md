# Nemotron Omni Live Voice PR Checklist - 2026-05-12

## Scope

This checklist tracks the Osaurus side of live voice input for Nemotron Omni
models. This branch pins `vmlx-swift-lm` to `c0f8b3b`, which can consume
`UserInput.Audio` and preserves pre-encoded Parakeet/audio embeddings. Omni
audio support is gated by `ModelMediaCapabilities.supportsAudio`.

## Current Hookups

- `SpeechService` exposes `LiveVoiceAudioSnapshot` and `currentLiveAudioWAVData()`.
- `ThreadSafeAudioBuffer` retains a bounded copy of the active live voice PCM
  separately from the short chunks drained by the streaming STT worker.
- `FloatingInputCard.sendVoiceMessage(_:)` captures the WAV before stopping
  transcription and appends it as `Attachment.audio(..., format: "wav")` when
  the selected model supports audio.
- Existing chat attachment flow converts `Attachment.audio` into
  `input_audio` content parts.
- `ModelRuntime.extractAudioSources(from:)` materializes `input_audio` into a
  temp audio file and hands `UserInput.Audio.url` to vMLX.
- `Packages/OsaurusCore/Package.swift` pins `vmlx-swift-lm` to `c0f8b3b` so
  the app consumes the Swift live-voice handoff support.
- Live voice timing is now visible in the normal debug path:
  - `FloatingInputCard` logs `snapshot_ms`, `wav_encode_ms`, `wav_bytes`,
    `sample_rate`, and `duration_ms` when a voice turn is captured.
  - `TTFTTrace` records `input_audio_count`, `input_audio_materialized_count`,
    `input_audio_bytes`, `input_audio_materialize_ms`, `prompt_prepare_ms`,
    `processor_prepare_ms`, `chat_audio_count`, `first_token_ms`, and
    `first_chunk_ms`.
  - OpenAI-compatible `/chat/completions` debug builds attach the same
    `TTFTTrace` to API requests and emit `/tmp/osaurus_ttft_trace.log` on SSE
    finish, tool-call finish, JSON finish, and handled API errors. This records
    endpoint/model/media counts plus the HTTP stream phases needed for
    headless audio latency benches.

## Verified Evidence

- `swift build --target OsaurusCore` passed after the live voice snapshot
  changes, after the `vmlx-swift-lm` pin bump to `c0f8b3b`, and after the
  TTFT/live-voice timing instrumentation. It also passed after the API-level
  `/chat/completions` trace recorder was added.
- Xcode app build passed from the workspace:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild
  -workspace osaurus.xcworkspace -scheme osaurus -configuration Debug
  -destination 'platform=macOS,arch=arm64'
  -derivedDataPath build/XcodeDerivedData-livevoice
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= build`.
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
- `swift test --filter LiveVoiceAudioSnapshotTests` is blocked by the existing
  local toolchain issue: the package test target imports Swift `Testing`, which
  is unavailable in this environment.
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

- Add a direct pre-encoded audio path only after an Osaurus voice component can
  emit stable Parakeet/sound-projection embeddings. The current WAV path is
  correct but pays model-side encoding.
- Add TTFAB coverage once a TTS backend is selected. Current evidence covers
  speech input into model output text, not first output audio byte.
- Keep audio attachment spillover and temp-file cleanup under review for longer
  call clips.
