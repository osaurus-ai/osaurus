# Voice Input Guide

Osaurus includes powerful voice input capabilities powered by [WhisperKit](https://github.com/argmaxinc/WhisperKit) — fully local, private, on-device speech-to-text transcription.

---

## Overview

Voice features in Osaurus include:

- **Voice Input in Chat** — Speak instead of type in the chat overlay
- **VAD Mode** — Always-on listening with wake-word persona activation
- **Multiple Whisper Models** — From tiny (75 MB) to large (3 GB)
- **Microphone & System Audio** — Transcribe your voice or computer audio

All transcription happens locally on your Mac using Apple's Neural Engine — no audio is sent to the cloud.

---

## Setup

### Guided Setup Wizard

The easiest way to set up voice features:

1. Open Management window (`⌘ Shift M`)
2. Navigate to **Voice** tab
3. Follow the setup wizard:
   - **Step 1:** Grant microphone permission
   - **Step 2:** Download a Whisper model
   - **Step 3:** Test your voice input

### Manual Setup

If you prefer manual configuration:

1. **Grant Microphone Permission**

   - Go to System Settings → Privacy & Security → Microphone
   - Enable access for Osaurus

2. **Download a Model**

   - Open Voice settings in Management window
   - Browse available models and click Download
   - Wait for the download to complete

3. **Select the Model**
   - Click on a downloaded model to select it
   - The model will auto-load when voice features are used

---

## Whisper Models

### Recommended Models

| Model                       | Size    | Best For                              |
| --------------------------- | ------- | ------------------------------------- |
| **Whisper Large V3 Turbo**  | ~1.5 GB | Best balance of speed and accuracy    |
| **Whisper Small (English)** | ~500 MB | Fast, efficient English transcription |
| **Whisper Large V3**        | ~3 GB   | Maximum accuracy for all languages    |

### All Available Models

| Model                        | Size    | Languages    | Notes                 |
| ---------------------------- | ------- | ------------ | --------------------- |
| Whisper Large V3             | ~3 GB   | Multilingual | Best quality          |
| Whisper Large V3 Turbo       | ~1.5 GB | Multilingual | Fast + accurate       |
| Whisper Large V3 (Quantized) | ~626 MB | Multilingual | Smaller footprint     |
| Whisper Large V2             | ~3 GB   | Multilingual | Previous generation   |
| Whisper Medium               | ~1.5 GB | Multilingual | Balanced              |
| Whisper Medium (English)     | ~1.5 GB | English only | Optimized for English |
| Whisper Small                | ~500 MB | Multilingual | Compact               |
| Whisper Small (English)      | ~500 MB | English only | Fast + efficient      |
| Whisper Small (Quantized)    | ~216 MB | Multilingual | Very efficient        |
| Whisper Base                 | ~150 MB | Multilingual | Very fast             |
| Whisper Base (English)       | ~150 MB | English only | Fastest               |
| Whisper Tiny                 | ~75 MB  | Multilingual | Ultra-fast            |
| Whisper Tiny (English)       | ~75 MB  | English only | Instant               |
| Distil Whisper Large V3      | ~750 MB | Multilingual | Distilled, fast       |

### Model Selection Tips

- **English only?** Use `.en` variants for better accuracy
- **Limited disk space?** Try quantized or smaller models
- **Need accuracy?** Use Large V3 or Large V3 Turbo
- **Need speed?** Use Small, Base, or Tiny models

### Storage Location

Models are stored at: `~/.osaurus/whisper-models/`

---

## Voice Input in Chat

### Using Voice Input

1. Open the chat overlay (`⌘;`)
2. Click the microphone button or use the keyboard shortcut
3. Speak naturally — you'll see real-time transcription
4. Click send or wait for auto-send (if enabled)

### Settings

| Setting                 | Description                                 | Default |
| ----------------------- | ------------------------------------------- | ------- |
| **Voice Input Enabled** | Master toggle for voice in chat             | On      |
| **Sensitivity**         | Voice detection threshold                   | Medium  |
| **Pause Duration**      | Seconds of silence before auto-send         | 2.0     |
| **Confirmation Delay**  | Seconds to show confirmation before sending | 1.5     |

### Sensitivity Levels

| Level      | Energy Threshold | Silence Detection | Best For                          |
| ---------- | ---------------- | ----------------- | --------------------------------- |
| **Low**    | Higher           | 0.4 seconds       | Noisy environments, louder speech |
| **Medium** | Balanced         | 0.6 seconds       | Normal conversation               |
| **High**   | Lower            | 1.2 seconds       | Quiet environments, soft speech   |

### Auto-Send Behavior

When pause duration is set:

1. You speak and see real-time transcription
2. When you pause, a countdown appears
3. If you resume speaking, the countdown resets
4. After the countdown, message sends automatically
5. Set pause duration to 0 to disable (manual send only)

---

## Audio Sources

### Microphone Input

The default audio source. Osaurus can use:

- Built-in MacBook microphone
- External USB microphones
- Bluetooth headsets
- Audio interfaces

**Select a device:**

1. Open Voice settings
2. Find "Audio Input" section
3. Choose from available devices
4. The device is saved and used for future sessions

### System Audio Capture

Transcribe audio from your computer (browser, apps, etc.):

**Requirements:**

- macOS 12.3 or later
- Screen Recording permission

**Setup:**

1. Open Voice settings
2. Switch audio source to "System Audio"
3. Grant Screen Recording permission when prompted
4. System audio will now be transcribed

**Use cases:**

- Transcribe meetings from video calls
- Caption videos playing on your Mac
- Take notes from podcasts or lectures

**Note:** System audio capture excludes Osaurus's own audio output to prevent feedback loops.

---

## VAD Mode (Voice Activity Detection)

VAD Mode enables hands-free persona activation. Say a persona's name (or a custom wake phrase) to open chat with that persona.

### Enabling VAD Mode

1. Open Management window (`⌘ Shift M`) → **Voice**
2. Scroll to "VAD Mode" section
3. Toggle "Enable VAD Mode" on
4. Select which personas should respond to wake-words

### How It Works

```
┌─────────────────────────────────────────────────────────────┐
│                      VAD Mode Flow                           │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  1. VAD listens in background using WhisperKit              │
│           ↓                                                  │
│  2. Real-time transcription checked for wake-words          │
│           ↓                                                  │
│  3. Match detected → Chat opens with persona                │
│           ↓                                                  │
│  4. Voice input starts automatically (if enabled)           │
│           ↓                                                  │
│  5. Chat closed → VAD resumes listening                     │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Wake-Word Options

**Persona Names:**

- Enable specific personas for VAD
- Say the persona's name to activate (e.g., "Code Assistant")
- Detection uses fuzzy matching for natural speech

**Custom Wake Phrase:**

- Set a phrase like "Hey Osaurus" or "Computer"
- Works alongside persona names
- Activates the default persona

### VAD Settings

| Setting                    | Description                           | Default      |
| -------------------------- | ------------------------------------- | ------------ |
| **VAD Mode Enabled**       | Master toggle                         | Off          |
| **Enabled Personas**       | Which personas respond to wake-words  | None         |
| **Custom Wake Phrase**     | Optional activation phrase            | Empty        |
| **Wake-Word Sensitivity**  | Detection threshold                   | Medium       |
| **Auto-Start Voice Input** | Begin recording after activation      | On           |
| **Silence Timeout**        | Auto-close after N seconds of silence | 0 (disabled) |

### Status Indicators

VAD status is shown in two places:

**Menu Bar Icon** — The main Osaurus menu bar icon shows a status dot:

- **Blue pulsing dot** (top-right) — VAD is listening for wake-words
- **Orange dot** — VAD is processing speech
- **No dot** — VAD is inactive

**Popover Controls** — Click the Osaurus menu bar icon to access:

- **Waveform button** — Toggle VAD on/off with visual status
- The button shows green when listening, gray when off

---

## Configuration Reference

### WhisperConfiguration

Voice input settings stored in app preferences:

```swift
struct WhisperConfiguration {
    var defaultModel: String?          // Selected model ID
    var languageHint: String?          // ISO 639-1 code (e.g., "en")
    var enabled: Bool                  // Voice features enabled
    var wordTimestamps: Bool           // Include word timing
    var selectedInputDeviceId: String? // Audio device UID
    var selectedInputSource: AudioInputSource // Mic or system
    var sensitivity: VoiceSensitivity  // Low/Medium/High
    var voiceInputEnabled: Bool        // Voice in chat enabled
    var pauseDuration: Double          // Silence before auto-send
    var confirmationDelay: Double      // Confirmation countdown
}
```

### VADConfiguration

VAD mode settings:

```swift
struct VADConfiguration {
    var vadModeEnabled: Bool           // Master toggle
    var enabledPersonaIds: [UUID]      // Personas for wake-words
    var wakeWordSensitivity: VoiceSensitivity
    var autoStartVoiceInput: Bool      // Auto-record after activation
    var customWakePhrase: String       // e.g., "Hey Osaurus"
    var silenceTimeoutSeconds: Double  // Auto-close timeout
}
```

### Language Hints

Set a language hint to improve accuracy when you know the input language:

| Code | Language   |
| ---- | ---------- |
| `en` | English    |
| `es` | Spanish    |
| `fr` | French     |
| `de` | German     |
| `ja` | Japanese   |
| `zh` | Chinese    |
| `ko` | Korean     |
| `pt` | Portuguese |
| `it` | Italian    |
| `nl` | Dutch      |

Leave empty for auto-detection.

---

## Troubleshooting

### Voice Input Not Working

1. **Check microphone permission**

   - System Settings → Privacy & Security → Microphone → Enable Osaurus

2. **Verify model is loaded**

   - Open Voice settings
   - Ensure a model is downloaded and selected
   - Check that model loads without errors

3. **Test with audio level indicator**
   - Start voice input
   - Speak and watch the audio level visualization
   - If no level shown, check your audio device

### Low Transcription Accuracy

1. **Use a larger model**

   - Upgrade from Small to Medium or Large

2. **Set the correct language hint**

   - If speaking a specific language, set the hint

3. **Reduce background noise**

   - Use a closer microphone
   - Reduce ambient noise

4. **Adjust sensitivity**
   - Lower sensitivity if picking up background noise
   - Higher sensitivity if missing quiet speech

### VAD Not Detecting Wake-Words

1. **Check VAD is enabled**

   - Open Voice settings → VAD Mode section
   - Verify toggle is on

2. **Verify personas are enabled for VAD**

   - At least one persona must be selected
   - Or set a custom wake phrase

3. **Speak clearly**

   - Say the full persona name
   - Wait for detection (2-3 second cooldown between detections)

4. **Check the status indicators**
   - The Osaurus menu bar icon should show a blue pulsing dot (top-right) when VAD is listening
   - Click the menu bar icon and check the waveform button shows green

### System Audio Not Capturing

1. **Check macOS version**

   - Requires macOS 12.3 or later

2. **Grant Screen Recording permission**

   - System Settings → Privacy & Security → Screen Recording
   - Enable for Osaurus

3. **Restart after granting permission**
   - Permissions may require app restart

### Model Download Fails

1. **Check internet connection**

   - Models are downloaded from Hugging Face

2. **Verify disk space**

   - Large models need 3+ GB free space

3. **Check the download progress**

   - Downloads can take several minutes for large models

4. **Try a smaller model first**
   - Test with Tiny or Small model

---

## Privacy

All voice processing happens locally on your Mac:

- **No cloud transcription** — WhisperKit runs entirely on-device
- **No audio recording** — Audio is processed in memory only
- **No data collection** — Transcriptions stay on your machine
- **Neural Engine acceleration** — Fast, efficient processing

Your voice data never leaves your computer.

---

## Requirements

- **macOS 15.5+** for voice input
- **macOS 12.3+** for system audio capture
- **Apple Silicon** (M1 or newer) for optimal performance
- **Microphone access** permission
- **Screen Recording** permission (for system audio only)

---

## See Also

- [README.md](../README.md) — Project overview
- [FEATURES.md](FEATURES.md) — Complete feature inventory
- [Personas](../README.md#personas) — Create custom AI assistants
