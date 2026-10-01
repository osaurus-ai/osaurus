---
title: Voice — Dictation and Text-to-Speech
summary: Fully local speech-to-text, system-wide dictation, wake phrases, and spoken replies.
order: 130
---

# Voice

All voice features run on-device — no audio ever leaves your Mac.

## Voice input (speech-to-text)

- Settings… (⌘,) → Voice → Setup: grant Microphone access, download a Parakeet model (~600 MB), set the detection sensitivity, and test with the mic button. Voice settings are split into tabs: **Setup**, **Chat Voice**, **Transcription**, **Text-to-Speech**, **Wake Word**, and **Models**.
- Models: Parakeet TDT v3 (multilingual, 25 European languages — recommended) or v2 (English-only, slightly better English recall). Runs on the Neural Engine.
- In chat: turn on **Enable Voice Input** under Voice → Chat Voice, then tap the mic button. Sensitivity lives on Setup; Stop Mode, Pause Duration (default 2.0s auto-send; 0 = manual send), Confirmation Delay, and Clean Up Transcription live under Voice → Transcription → Stop Behavior & Cleanup.
- Audio Input can also capture System Audio (needs Screen Recording permission; excludes Osaurus's own output).

## Wake phrase / VAD mode

Off by default. Enable **Wake Word** (Voice → Wake Word) to listen for a custom wake phrase and route what follows to an agent; the menu bar icon pulses blue while listening.

## Dictation anywhere

Voice → Transcription → **Enable Transcription Mode** turns on system-wide dictation into any app via a global hotkey (needs Accessibility permission). An overlay shows Listening / Done; Esc cancels. The same tab holds the hotkey and the Stop Behavior & Cleanup controls shared with chat voice input.

## Text-to-speech

- Voice → Text-to-Speech: enable, pick a voice, and Preview. The engine (Pocket TTS or an OpenAI-compatible server) is under Advanced.
- Default engine: On-Device (PocketTTS) — English, ~700 MB one-time download, offline afterwards; choose a voice (default `alba`).
- Alternative: any OpenAI-compatible TTS server (`/v1/audio/speech`) — endpoint, model, voice, speed, optional API key (Keychain).
- In chat, a speaker button appears on assistant messages when TTS is on; agents can also be granted a `speak` tool in the agent's Abilities settings.
- Every dictation session and every spoken reply is recorded in Settings… (⌘,) → Insights (**Transcription** / **Speech** chips). On-device work is **Local**; an OpenAI-compatible TTS server shows as **Cloud** with the text that was sent.
