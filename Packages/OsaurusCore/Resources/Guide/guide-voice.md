---
title: Voice — Dictation and Text-to-Speech
summary: Fully local speech-to-text, system-wide dictation, wake phrases, and spoken replies.
order: 130
---

# Voice

All voice features run on-device — no audio ever leaves your Mac.

## Voice input (speech-to-text)

- Settings… (⌘,) → Voice → Setup: grant Microphone access, download a Parakeet model (~600 MB), set the detection sensitivity, and test with the mic button. The Voice page has **Voice Input in Chat** and rows for **Setup**, **Transcription**, **Text to Speech**, **Wake Word** and **Speech Models** (Local Models → Speech). The default speech model is in Models → Model Defaults → **Speech-to-Text Model**.
- Models: Parakeet TDT v3 (multilingual, 25 European languages — recommended) or v2 (English-only, slightly better English recall). Runs on the Neural Engine.
- In chat: turn on **Voice Input in Chat** on the Voice page, then tap the mic button. Sensitivity lives on Setup; Stop Mode, Pause Detection (default 1.5s of silence; 0 = manual send), Confirmation Delay (default 2.0s), and Clean Up Transcription live under Voice → Transcription → Stop Behavior & Cleanup.
- Audio Input can also capture System Audio (needs Screen Recording permission; excludes Osaurus's own output).

## Wake phrase / VAD mode

Off by default. Enable **Wake Word** (Voice → Wake Word) to listen for a custom wake phrase and route what follows to an agent; the menu bar icon pulses blue while listening.

## Dictation anywhere

Voice → Transcription → **Enable Transcription Mode** turns on system-wide dictation into any app via a global hotkey (needs Accessibility permission). An overlay shows **Listening** / **Processing**, with **Stop and insert** to finish early; Esc cancels. The same tab holds the hotkey and the Stop Behavior & Cleanup controls shared with chat voice input.

## Text-to-speech

- Voice → Text to Speech: enable, pick a voice, and Preview. The engine (On-Device (PocketTTS), On-Device (Kokoro), or an OpenAI-compatible server) is under Advanced → **Engine**.
- Default engine: On-Device (PocketTTS) — English, ~530 MB one-time download, offline afterwards; choose a voice (default `alba`). **Temperature** uses the model's own default until you move it; **Use Model Default** resets it.
- On-Device (Kokoro): Kokoro-82M in English, Mandarin Chinese, Japanese, Spanish or French. The **Kokoro Model** card has **Language** (each language is its own download, about 85–500 MB) and **Runtime**: **Standard** has every voice; **Fast (v3)** synthesizes quicker with only the language's native voices and needs macOS 15 (English, Mandarin and Japanese only — Spanish and French stay on Standard). The **Voice** card has **Voice** (default Heart for English) and **Speed** (0.5×–2.0×, default 1.0×). Changing language or runtime switches to that pack's default voice when the current one isn't in it. Kokoro speaks a sentence at a time, so the first words start after the first sentence is synthesized.
- Voice models load on first use, not at launch: the first spoken reply (or the first mic tap) loads the model before it starts, and Text to Speech shows **Load Now** to load it ahead of time. Only under critical memory pressure do idle voice models unload; they reload on next use.
- **Cancel** beside the download spinner stops a download or load; the next **Download** resumes it. Once files are on disk, **Downloads** on the model card shows their size: **Delete Kokoro Downloads** removes every Kokoro language at once, **Delete Model** removes PocketTTS. The next spoken reply downloads again.
- On macOS 26.4 and 26.5 the Kokoro Model card warns that a Core ML bug can quit Osaurus while Kokoro speaks; macOS 26.6 fixes it.
- Alternative: any OpenAI-compatible TTS server (`/v1/audio/speech`) — endpoint, model, voice, speed, optional API key (Keychain).
- In chat, a speaker button appears on assistant messages when TTS is on; agents can also be granted a `speak` tool with **Speak Tool** in the agent's Abilities settings. An agent's own **Voice** (agent → Voice, with Auto Speak on) lists the voices of the current engine; a saved voice that engine doesn't have falls back to the global voice, and the agent page says so.
- Every dictation session and every spoken reply is recorded in Main window → Insights (**Audio & Media** scope tab, **Transcription** / **Speech** rows). On-device work is **Local**; an OpenAI-compatible TTS server shows as **Cloud** with the text that was sent.
