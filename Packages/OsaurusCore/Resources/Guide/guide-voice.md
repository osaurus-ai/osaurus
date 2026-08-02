---
title: Voice — Dictation and Text-to-Speech
summary: Fully local speech-to-text, system-wide dictation, wake phrases, and spoken replies.
order: 130
---

# Voice

All voice features run on-device — no audio ever leaves your Mac.

## Voice input (speech-to-text)

- Management (⌘⇧M) → Voice: grant Microphone access, download a Parakeet model (~600 MB), and test with the mic button.
- Models: Parakeet TDT v3 (multilingual, 25 European languages — recommended) or v2 (English-only, slightly better English recall). Runs on the Neural Engine.
- In chat: tap the mic button. Settings include Sensitivity, Pause Duration (default 2.0s auto-send; 0 = manual send), and Confirmation Delay.
- Audio Input can also capture System Audio (needs Screen Recording permission; excludes Osaurus's own output).

## Wake phrase / VAD mode

Off by default. Enable VAD Mode in Voice settings to listen for a custom wake phrase and route what follows to an agent; the menu bar icon pulses blue while listening.

## Dictation anywhere

The Transcription tab enables system-wide dictation into any app via a global hotkey (needs Accessibility permission). An overlay shows Listening / Done; Esc cancels.

## Text-to-speech

- Voice → Text-to-Speech: enable, pick an engine, and Preview.
- Default engine: On-Device (PocketTTS) — English, ~700 MB one-time download, offline afterwards; choose a voice (default `alba`).
- Alternative: any OpenAI-compatible TTS server (`/v1/audio/speech`) — endpoint, model, voice, speed, optional API key (Keychain).
- In chat, a speaker button appears on assistant messages when TTS is on; agents can also be granted a `speak` tool in the agent's Abilities settings.
