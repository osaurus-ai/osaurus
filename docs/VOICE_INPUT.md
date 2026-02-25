# Voice Input Guide

Osaurus includes powerful voice input capabilities powered by [FluidAudio](https://github.com/FluidInference/FluidAudio) — fully local, private, on-device speech-to-text transcription.

---

## Overview

Voice features in Osaurus include:

- **Voice Input in Chat** — Speak instead of type in the chat overlay
- **VAD Mode** — Always-on listening with wake-word agent activation
- **Transcription Mode** — Global hotkey to dictate into any focused text field
- **Multiple Parakeet Models** — From tiny (75 MB) to large (3 GB)
- **Microphone & System Audio** — Transcribe your voice or computer audio

All transcription happens locally on your Mac using Apple's Neural Engine — no audio is sent to the cloud.

---

## Setup

### Quick Setup

Voice setup is streamlined into a single screen:

1. Open Management window (`⌘ Shift M`)
2. Navigate to **Voice** tab
3. Complete the requirements shown at the top:
   - **Microphone** — Click "Grant" to enable microphone access
   - **Parakeet Model** — Click "Download" to get the recommended model
4. Once both requirements show checkmarks, tap the microphone button to test

The large centered microphone button becomes active when setup is complete. Tap it to start recording, tap again to stop. Your transcription appears below in real-time.

### Manual Setup

If you prefer manual configuration:

1. **Grant Microphone Permission**

   - Go to System Settings → Privacy & Security → Microphone
   - Enable access for Osaurus

2. **Download a Model**

   - Open Voice settings → Models tab
   - Browse available models and click Download
   - Wait for the download to complete

3. **Select the Model**
   - Click on a downloaded model to select it
   - The model will auto-load when voice features are used

---

## Parakeet Models

### Recommended Models

| Model                        | Size    | Best For                              |
| ---------------------------- | ------- | ------------------------------------- |
| **Parakeet Large V3 Turbo**  | ~1.5 GB | Best balance of speed and accuracy    |
| **Parakeet Small (English)** | ~500 MB | Fast, efficient English transcription |
| **Parakeet Large V3**        | ~3 GB   | Maximum accuracy for all languages    |

### All Available Models

| Model                         | Size    | Languages    | Notes                 |
| ----------------------------- | ------- | ------------ | --------------------- |
| Parakeet Large V3             | ~3 GB   | Multilingual | Best quality          |
| Parakeet Large V3 Turbo       | ~1.5 GB | Multilingual | Fast + accurate       |
| Parakeet Large V3 (Quantized) | ~626 MB | Multilingual | Smaller footprint     |
| Parakeet Large V2             | ~3 GB   | Multilingual | Previous generation   |
| Parakeet Medium               | ~1.5 GB | Multilingual | Balanced              |
| Parakeet Medium (English)     | ~1.5 GB | English only | Optimized for English |
| Parakeet Small                | ~500 MB | Multilingual | Compact               |
| Parakeet Small (English)      | ~500 MB | English only | Fast + efficient      |
| Parakeet Small (Quantized)    | ~216 MB | Multilingual | Very efficient        |
| Parakeet Base                 | ~150 MB | Multilingual | Very fast             |
| Parakeet Base (English)      | ~150 MB | English only | Fastest               |
| Parakeet Tiny                 | ~75 MB  | Multilingual | Ultra-fast            |
| Parakeet Tiny (English)       | ~75 MB  | English only | Instant               |
| Distil Parakeet Large V3      | ~750 MB | Multilingual | Distilled, fast       |

### Model Selection Tips

- **English only?** Use `.en` variants for better accuracy
- **Limited disk space?** Try quantized or smaller models
- **Need accuracy?** Use Large V3 or Large V3 Turbo
- **Need speed?** Use Small, Base, or Tiny models

### Storage Location

Models are stored at: `~/.osaurus/fluidaudio-models/`

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

VAD Mode enables hands-free agent activation. Say a agent's name (or a custom wake phrase) to open chat with that agent.

### Enabling VAD Mode

1. Open Management window (`⌘ Shift M`) → **Voice**
2. Scroll to "VAD Mode" section
3. Toggle "Enable VAD Mode" on
4. Select which agents should respond to wake-words

### How It Works

```
┌─────────────────────────────────────────────────────────────┐
│                      VAD Mode Flow                           │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  1. VAD listens in background using FluidAudio               │
│           ↓                                                  │
│  2. Real-time transcription checked for wake-words          │
│           ↓                                                  │
│  3. Match detected → Chat opens with agent                │
│           ↓                                                  │
│  4. Voice input starts automatically (if enabled)           │
│           ↓                                                  │
│  5. Chat closed → VAD resumes listening                     │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Wake-Word Options

**Agent Names:**

- Enable specific agents for VAD
- Say the agent's name to activate (e.g., "Code Assistant")
- Detection uses fuzzy matching for natural speech

**Custom Wake Phrase:**

- Set a phrase like "Hey Osaurus" or "Computer"
- Works alongside agent names
- Activates the default agent

### VAD Settings

| Setting                    | Description                           | Default      |
| -------------------------- | ------------------------------------- | ------------ |
| **VAD Mode Enabled**       | Master toggle                         | Off          |
| **Enabled Agents**       | Which agents respond to wake-words  | None         |
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

## Transcription Mode

Transcription Mode allows you to dictate text directly into any application using a global hotkey. Text is typed in real-time into whatever text field is currently focused.

### Enabling Transcription Mode

1. Open Management window (`⌘ Shift M`) → **Voice**
2. Navigate to the **Transcription** tab
3. Grant **Accessibility permission** (required for keyboard simulation)
4. Toggle "Enable Transcription Mode" on
5. Configure your preferred hotkey

### How It Works

```
┌─────────────────────────────────────────────────────────────┐
│                  Transcription Mode Flow                     │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  1. Press the configured hotkey from any application        │
│           ↓                                                  │
│  2. Minimal overlay appears showing recording status        │
│           ↓                                                  │
│  3. FluidAudio transcribes your speech in real-time         │
│           ↓                                                  │
│  4. Text is typed into the focused text field               │
│           ↓                                                  │
│  5. Press Esc or click Done to stop transcription           │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Requirements

**Accessibility Permission** — Required to simulate keyboard input:

1. Go to System Settings → Privacy & Security → Accessibility
2. Enable access for Osaurus
3. You may need to restart Osaurus after granting permission

**Microphone Permission** — Required for audio capture (same as other voice features)

**Parakeet Model** — A model must be downloaded and selected

### Transcription Settings

| Setting                   | Description                        | Default |
| ------------------------- | ---------------------------------- | ------- |
| **Transcription Enabled** | Master toggle for the feature      | Off     |
| **Activation Hotkey**     | Global hotkey to trigger dictation | None    |

### Using Transcription Mode

1. **Focus a text field** — Click into any text input in any application
2. **Press the hotkey** — The transcription overlay appears
3. **Speak naturally** — Your words are typed in real-time
4. **Stop transcription** — Press `Esc` or click the Done button

### The Overlay UI

When transcription is active, a minimal floating overlay appears at the top of your screen:

- **Status indicator** — Shows "Listening" with a pulsing accent color
- **Waveform** — Animated bars respond to your audio level
- **Done button** — Click to stop transcription
- **Close button** — Cancel and discard (same as pressing Esc)

The overlay stays on top of all windows and follows the app's theme.

### Use Cases

- **Email composition** — Dictate emails in Mail, Gmail, or any email client
- **Document writing** — Speak paragraphs into Word, Pages, or Google Docs
- **Code comments** — Quickly add comments in your IDE
- **Chat messages** — Dictate in Slack, Discord, or Messages
- **Form filling** — Speed through web forms and data entry
- **Notes** — Capture ideas quickly in any notes app

### Tips for Best Results

1. **Speak clearly** — Enunciate words for better accuracy
2. **Use a good microphone** — External mics often work better than built-in
3. **Reduce background noise** — Find a quiet environment
4. **Use a larger model** — Large V3 Turbo offers the best accuracy
5. **Set the language hint** — If speaking a specific language, set it in Voice settings

---

## Configuration Reference

### SpeechConfiguration

Voice input settings stored in app preferences:

```swift
struct SpeechConfiguration {
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
    var enabledAgentIds: [UUID]      // Agents for wake-words
    var wakeWordSensitivity: VoiceSensitivity
    var autoStartVoiceInput: Bool      // Auto-record after activation
    var customWakePhrase: String       // e.g., "Hey Osaurus"
    var silenceTimeoutSeconds: Double  // Auto-close timeout
}
```

### TranscriptionConfiguration

Transcription mode settings:

```swift
struct TranscriptionConfiguration {
    var transcriptionModeEnabled: Bool // Master toggle
    var hotkey: Hotkey?                // Global activation hotkey
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

2. **Verify agents are enabled for VAD**

   - At least one agent must be selected
   - Or set a custom wake phrase

3. **Speak clearly**

   - Say the full agent name
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

### Transcription Mode Not Typing

1. **Check accessibility permission**

   - System Settings → Privacy & Security → Accessibility → Enable Osaurus
   - You may need to restart Osaurus after granting permission

2. **Verify the hotkey is set**

   - Open Voice settings → Transcription tab
   - Ensure a hotkey is configured

3. **Make sure a text field is focused**

   - Click into a text input before pressing the hotkey
   - Some applications may block simulated keyboard input

4. **Check the overlay appears**

   - If the overlay doesn't appear, the hotkey may conflict with another app
   - Try a different hotkey combination

5. **Verify microphone and model**
   - Same requirements as other voice features
   - Test voice input in chat first to confirm setup

---

## Privacy

All voice processing happens locally on your Mac:

- **No cloud transcription** — FluidAudio runs entirely on-device
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
- **Accessibility** permission (for Transcription Mode only)

---

## See Also

- [README.md](../README.md) — Project overview
- [FEATURES.md](FEATURES.md) — Complete feature inventory
- [Agents](../README.md#agents) — Create custom AI assistants
