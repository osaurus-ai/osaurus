# Text-to-Speech Guide

Osaurus can read assistant replies aloud. Two engines are supported:

- **On-Device (PocketTTS)** — the default. Fully local synthesis via [FluidAudio PocketTTS](https://github.com/FluidInference/FluidAudio) (kyutai/pocket-tts). English only, ~700 MB one-time model download, no network needed after that.
- **OpenAI-Compatible Server** — any server implementing the OpenAI `/v1/audio/speech` API: [openai-edge-tts](https://github.com/travisvn/openai-edge-tts), [Kokoro-FastAPI](https://github.com/remsky/Kokoro-FastAPI), LocalAI, or OpenAI itself. Use this for more voices, other languages, or a shared TTS box on your network.

Playback streams as audio is synthesized — speech starts before the full utterance is ready.

---

## Where TTS appears

- **Speaker button** on assistant messages in chat (shown when TTS is enabled). Tap to speak, tap again to stop; tapping a different message switches to it.
- **`speak` tool** — agents with the Voice capability enabled can speak their replies (Configure → Features → Output → Voice).
- **Preview** in Settings → Voice → Text-to-Speech, for testing a voice without leaving settings.

---

## Setup

### On-Device (PocketTTS)

1. Open the Management window (`⌘ Shift M`) → **Voice** → **Text-to-Speech**
2. Enable **Text-to-Speech**
3. Leave **Engine** on *On-Device (PocketTTS)*
4. Click **Download** on the PocketTTS Model card (~700 MB, one time)
5. Pick a voice and temperature, then use **Preview** to test

### OpenAI-Compatible Server

1. Enable **Text-to-Speech** and switch **Engine** to *OpenAI-Compatible Server*
2. Fill in the **Server** card:
   - **Endpoint** — base URL, e.g. `http://localhost:5050` (the `/v1/audio/speech` path is appended automatically; pasting the full path also works)
   - **Model** — sent as `model`, e.g. `tts-1`
   - **Voice** — free-form, whatever the server understands (`alloy`, `en-GB-SoniaNeural`, `af_sky`, …)
   - **API Key** — optional; leave empty for unauthenticated servers. Stored in the macOS Keychain, never in config files.
   - **Speed** — playback rate 0.25×–4×
3. Click **Test Connection** — it synthesizes a short utterance through the full request path, so a green *Connected* means real playback will work. Errors (bad URL, connection refused, HTTP errors, undecodable audio) appear inline.

Playback failures at any later point show up in the same Server card and in the unified log (Console.app, subsystem `ai.osaurus`, category `tts.service`).

---

## Audio format handling

Osaurus requests `response_format: "wav"` (24 kHz mono 16-bit) and sniffs what the server actually sends:

| Server sends | Behavior |
|---|---|
| WAV, 24 kHz mono 16-bit | Header parsed and stripped, audio streamed as it arrives (lowest latency) |
| Raw PCM, 24 kHz mono 16-bit | Streamed as-is |
| MP3 / FLAC / other CoreAudio-decodable | Buffered, decoded, and resampled after download completes — playback works, with a short extra delay |
| WAV at another rate / channel count | Rejected with an explicit error (no chipmunk audio) |
| Anything else | Rejected with an explicit error naming the format |

The compressed fallback exists because some servers can't produce WAV — notably the stock `travisvn/openai-edge-tts` Docker image, which ships without ffmpeg and always returns MP3.

### Running openai-edge-tts locally

Works out of the box (via the MP3 fallback):

```bash
docker run -d -p 5050:5050 -e REQUIRE_API_KEY=False travisvn/openai-edge-tts:latest
```

For lower-latency streaming WAV, build the image with ffmpeg:

```bash
docker build --build-arg INSTALL_FFMPEG=true -t openai-edge-tts:ffmpeg \
  https://github.com/travisvn/openai-edge-tts.git
docker run -d -p 5050:5050 -e REQUIRE_API_KEY=False openai-edge-tts:ffmpeg
```

Note: the auth default is on (`REQUIRE_API_KEY=True` with key `your_api_key_here`); either disable it as above or enter the key in the API Key field. Do not use the server's `response_format: "pcm"` path — it is broken upstream (feeds AAC into a PCM muxer), which is why Osaurus requests WAV.

---

## Configuration reference

Settings persist to `~/.osaurus/voice/tts.json` (API key excluded — Keychain only):

| Key | Default | Meaning |
|---|---|---|
| `enabled` | `true` | Master toggle; hides speaker buttons when off |
| `provider` | `pocketTTS` | `pocketTTS` or `openAICompatible` |
| `voice` | `alba` | PocketTTS voice |
| `temperature` | `0.7` | PocketTTS generation temperature (0.1–1.2) |
| `remoteEndpoint` | `http://localhost:5050` | OpenAI-compatible server base URL |
| `remoteModel` | `tts-1` | Model name sent to the server |
| `remoteVoice` | `alloy` | Voice name sent to the server |
| `remoteSpeed` | `1.0` | Speed multiplier (0.25–4.0) |

Per-agent voice overrides (the agent editor's voice picker) apply to both engines; for the remote engine the override string is passed to the server verbatim.

---

## Troubleshooting

- **Speaker button opens settings instead of speaking** — PocketTTS model not downloaded yet (on-device engine only; the remote engine needs no download).
- **"Server sent MP3 audio that could not be decoded"** — the body claimed to be audio but CoreAudio couldn't read it; check the server's logs.
- **"Server sent WAV audio in an unsupported format …"** — the server's converter is producing a non-24 kHz or non-mono WAV; fix its ffmpeg arguments.
- **Icon flips back immediately, no sound** — playback failed; the error is shown in Settings → Voice → Text-to-Speech (Server card) and logged to Console.app under subsystem `ai.osaurus`.
- **Nothing plays mid-conversation after switching audio devices** — the engine rebuilds onto the new output device automatically; a sub-second gap is expected, silence beyond that is a bug worth reporting.
