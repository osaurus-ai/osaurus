# Text-to-Speech Guide

Osaurus can read assistant replies aloud. Three engines are supported:

- **On-Device (PocketTTS)** — the default. Fully local synthesis via [FluidAudio PocketTTS](https://github.com/FluidInference/FluidAudio) (kyutai/pocket-tts, the `english_2026-10` checkpoint). English only, ~530 MB one-time model download, no network needed after that. Files live under `~/.cache/fluidaudio/Models/pocket-tts/v2.1/english_2026-10/`; the pre-0.18 files left at the `pocket-tts/` root are removed after the new pack first loads.
- **On-Device (Kokoro)** — [hexgrad/Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) through FluidAudio's Core ML ports. English, Mandarin Chinese, Japanese, Spanish and French; each language is its own download (see the table below). Two runtimes: **Standard** (the 7-stage chain, every voice) and **Fast (v3)** (static-bucket pipeline, macOS 15+, English/Mandarin/Japanese with only their native voices). Files live under `~/.cache/fluidaudio/Models/kokoro-82m-coreml/` (Standard: `ANE`, `ANE-zh`, `ANE-ja`; Fast: `ANE-v3/<revision>/<en|zh|ja>`) plus the shared English G2P assets in `~/.cache/fluidaudio/Models/kokoro/`.
- **OpenAI-Compatible Server** — any server implementing the OpenAI `/v1/audio/speech` API: [openai-edge-tts](https://github.com/travisvn/openai-edge-tts), [Kokoro-FastAPI](https://github.com/remsky/Kokoro-FastAPI), LocalAI, or OpenAI itself. Use this for more voices, other languages, or a shared TTS box on your network.

Playback starts before the whole reply is synthesized. Text is split into sentence-sized chunks (on `.`, `!`, `?` and the fullwidth `。`, `！`, `？`); PocketTTS streams 80 ms frames within each chunk, while Kokoro renders a chunk at a time, so its first sound waits for the first sentence.

---

## Where TTS appears

- **Speaker button** on assistant messages in chat (shown when TTS is enabled). Tap to speak, tap again to stop; tapping a different message switches to it.
- **`speak` tool** — agents with the **Speak Tool** ability on can read a reply aloud when asked (Agent → Abilities → Overview → Output → Speak Tool). To read every reply aloud, use **Auto Speak Responses** in the Voice section of the agent's page.
- **Preview** in Settings → Voice → Text-to-Speech, for testing a voice without leaving settings.

---

## Setup

### On-Device (PocketTTS)

1. Open Settings… (`⌘,`) → **Voice** → **Text to Speech**
2. Enable **Text-to-Speech**
3. Leave **Engine** on *On-Device (PocketTTS)*
4. Click **Download** on the PocketTTS Model card (~530 MB, one time)
5. Pick a voice, then use **Preview** to test. **Temperature** starts at the value the checkpoint was tuned for (0.3); move the slider to override it, or **Use Model Default** to go back.

### On-Device (Kokoro)

1. Open Settings… (`⌘,`) → **Voice** → **Text to Speech**, enable **Text-to-Speech**
2. Under **Advanced**, set **Engine** to *On-Device (Kokoro)*
3. On the **Kokoro Model** card choose a **Language** and **Runtime**, then click **Download**. Loading also synthesizes one short sentence so the language's text frontend (Mandarin and Japanese dictionaries) is fetched and Core ML is warm before the first reply. FluidAudio reports no progress for that fetch or for the Fast (v3) download, so the bar shows *Preparing…* for those steps; Mandarin's polyphone model alone is about 160 MB.
4. Pick a **Voice** and **Speed** (0.5×–2.0×, the model's natural pace is 1.0×), then use **Preview**.

Sizes below are measured on a fresh cache and include each language's text frontend. English, Spanish and French Standard share the same ~80 MB Core ML chain, so adding a second of those languages costs only its frontend.

| Language | Standard | Fast (v3) | Default voice |
|---|---|---|---|
| English | ~95 MB, 54 voices (American, British, and accented English) | ~390 MB, 28 American/British voices | Heart (`af_heart`) |
| Mandarin Chinese | ~310 MB | ~385 MB, Mandarin voices only | `zf_001` |
| Japanese | ~285 MB | ~500 MB | Alpha (`jf_alpha`) |
| Spanish | ~85 MB | — (runs Standard) | Dora (`ef_dora`) |
| French | ~175 MB (includes the ~80 MB multilingual G2P fallback) | — (runs Standard) | Siwis (`ff_siwis`) |

Choosing Spanish or French sets **Runtime** to Standard and disables the picker. Changing language or runtime moves the voice to that pack's default when the current voice isn't in it. A voice that can't be used (an agent override from another engine, a hand-edited config) falls back to the configured Kokoro voice, then the language default, and logs a notice under `tts.service`.

Osaurus links FluidAudio with only its `TTS` trait. The `NemoTextProcessing` trait (NeMo text normalization, a prebuilt Rust library) is off because it can't be linked alongside Osaurus's other Rust code, so Kokoro uses FluidAudio's built-in normalizers for numbers, dates and units.

FluidAudio warns that macOS 26.4 and 26.5 carry an Apple BNNS bug that can intermittently crash Kokoro synthesis ([FluidAudio#844](https://github.com/FluidInference/FluidAudio/issues/844)); macOS 26.6 fixes it. On those versions the Kokoro Model card shows a warning saying so.

### Cancelling and deleting downloads

While a model downloads or loads, **Cancel** beside the spinner stops it; nothing stays in memory, and the next **Download** resumes partly downloaded files. Once anything is on disk, the model card shows **Downloads** with its size:

- **Delete Kokoro Downloads** removes every Kokoro language and runtime at once (Core ML models, voices, and the text-frontend dictionaries).
- **Delete Model** (PocketTTS) removes the PocketTTS model.

Both stop playback and free the model first. The next spoken reply downloads the current model again. Osaurus Classic and other copies of Osaurus on the same Mac share FluidAudio's `~/.cache/fluidaudio` folder, so deleting there removes their copy too.

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
| `provider` | `pocketTTS` | `pocketTTS`, `kokoro` or `openAICompatible`. An unknown value falls back to `pocketTTS` and keeps the other keys. |
| `voice` | `alba` | PocketTTS voice |
| `pocketTemperature` | absent | PocketTTS generation temperature (0.1–1.2). Absent uses the checkpoint's own default. Builds before FluidAudio 0.18 wrote `temperature`; a legacy `0.7` (the old Osaurus default) is read as "model default", any other legacy value is kept. |
| `kokoroLanguage` | `english` | `english`, `mandarin`, `japanese`, `spanish` or `french`; unknown values read as `english` |
| `kokoroRuntime` | `standard` | `standard` or `fast`; Spanish and French always run `standard` |
| `kokoroVoice` | `af_heart` | Kokoro voice id |
| `kokoroSpeed` | `1.0` | Kokoro speaking rate (0.5–2.0) |
| `remoteEndpoint` | `http://localhost:5050` | OpenAI-compatible server base URL |
| `remoteModel` | `tts-1` | Model name sent to the server |
| `remoteVoice` | `alloy` | Voice name sent to the server |
| `remoteSpeed` | `1.0` | Speed multiplier (0.25–4.0) |

Per-agent voice overrides (the agent editor's voice picker) list the voices of the current engine. An on-device engine that doesn't have the agent's voice uses the global voice instead, and the agent page says so; for the remote engine the override string is passed to the server verbatim.

---

## Troubleshooting

- **Speaker button opens settings instead of speaking** — the on-device model (PocketTTS, or the selected Kokoro language and runtime) isn't downloaded yet (on-device engine only; the remote engine needs no download).
- **"Server sent MP3 audio that could not be decoded"** — the body claimed to be audio but CoreAudio couldn't read it; check the server's logs.
- **"Server sent WAV audio in an unsupported format …"** — the server's converter is producing a non-24 kHz or non-mono WAV; fix its ffmpeg arguments.
- **Icon flips back immediately, no sound** — playback failed; the error is shown in Settings → Voice → Text-to-Speech (Server card) and logged to Console.app under subsystem `ai.osaurus`.
- **Nothing plays mid-conversation after switching audio devices** — the engine rebuilds onto the new output device automatically; a sub-second gap is expected, silence beyond that is a bug worth reporting.
