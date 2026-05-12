# Nemotron Omni Live Voice PR Checklist - 2026-05-12

## Scope

This checklist tracks the Osaurus side of live voice input for Nemotron Omni
models. It assumes vMLX can consume `UserInput.Audio` and that Omni audio
support is gated by `ModelMediaCapabilities.supportsAudio`.

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

## Verified Evidence

- `swift build --target OsaurusCore` passed after the live voice snapshot
  changes.
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
  5. Confirm response stream starts and TTFT trace includes preprocessing time.
- Negative smoke:
  1. Select a text-only model.
  2. Send a voice message.
  3. Confirm no audio attachment is appended; only cleaned transcript text is
     sent.

## Remaining Work

- Add app-level timing logs around live voice handoff:
  `snapshot_ms`, `wav_bytes`, `input_audio_materialize_ms`,
  `prepare_ms`, `first_token_ms`, `first_chunk_ms`.
- Add a direct pre-encoded audio path only after an Osaurus voice component can
  emit stable Parakeet/sound-projection embeddings. The current WAV path is
  correct but pays model-side encoding.
- Add TTFAB coverage once a TTS backend is selected. Current evidence covers
  speech input into model output text, not first output audio byte.
- Keep audio attachment spillover and temp-file cleanup under review for longer
  call clips.
