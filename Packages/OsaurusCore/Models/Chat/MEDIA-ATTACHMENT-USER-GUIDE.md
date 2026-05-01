# Media attachments in chat — user + integration guide

This is the host-side guide for the osaurus chat composer's drag/drop
+ file-picker behavior for image, audio, and video attachments. The
engine-side spec lives in
`vmlx-swift-lm/Libraries/MLXLMCommon/BatchEngine/MEDIA-MODEL-MATRIX.md`.

---

## 1. What users see (UX summary)

The chat composer's drop zone + paperclip button advertise different
file types depending on which model is currently loaded. The
capabilities matcher (`ModelMediaCapabilities.from(modelId:)`) drives
this:

| Loaded model | Drop zone accepts | File picker shows |
|---|---|---|
| Nemotron-3-Nano-Omni (any quant tier) | image + audio + video | image + docs + audio + video |
| Qwen 2/2.5/3 VL, Qwen 3.5/3.6 MoE VL, Holo3 VL, SmolVLM 2 | image + video | image + docs + video |
| Image-only VLMs (PaliGemma, Idefics3, FastVLM, Pixtral standalone, GLM OCR, LFM2-VL, Gemma 3/4, Mistral 3/3.5/4) | image | image + docs |
| Dense LLMs (gpt-oss, Laguna, MiniMax text, Kimi, etc.) | (no media) | docs |

When a user drops a file the current model can't consume, the host
shows a toast: "Cannot attach X — the current model supports {Y} only."
No silent ignore.

---

## 2. What's allowed per family (capability matrix)

Pinned to the regex/substring matcher in
`Models/Configuration/ModelMediaCapabilities.swift`:

### Audio + image + video (omni)

- `OsaurusAI/Nemotron-3-Nano-Omni-30B-A3B-MXFP4` / `-JANGTQ4` / `-JANGTQ`
- Any future bundle whose id matches regex `nemotron-3-nano-omni|nemotron[_-]h[_-]omni`
- Locally-installed bundles with a `config_omni.json` sidecar — `from(directory:modelId:)` reads this directly

### Image + video (no audio)

- Qwen 2 VL / 2.5 VL / 3 VL — regex `qwen[2-3](\.\d+|_\d+)?[-_]?vl`
- Qwen 3.5 / 3.6 MoE VL bundles — regex `qwen3\.[5-6].*[-_]vl`
- Holo3 VL — regex `holo3.*[-_]vl`
- SmolVLM 2 — substring `smolvlm` or `smol-vlm`

### Image only

- PaliGemma, Idefics 3, FastVLM, Llava-Qwen2
- Pixtral standalone (NOT the Mistral 3 wrapper — that's matched separately)
- GLM-OCR, LFM2-VL
- Gemma 3, Gemma 4 (the `-it` VLM variants)
- Mistral 3 / Mistral 3.5 (image only via Pixtral wrapper) — regex `mistral[-_](3|medium-3)`
- Mistral 4 VL — regex `mistral[-_]?4.*[-_]vl`

### Text only (no media)

Everything else — most dense LLMs, hybrid-SSM text models without VL
suffix (`Qwen3.5-35B`, `Qwen3.6-35B-A3B-mxfp4` without `-vl`, MiniMax
text, Laguna, Cascade-2 text, etc.)

**Boundary tests** in `ModelMediaCapabilitiesMCDCTests.swift` lock:

- Bare `nemotron-3` (text-only) does NOT match omni
- Bare `qwen3.5` / `qwen3.6` (no `-vl`) does NOT match imageVideo
- Bare `mistral-7b` (no 3 / medium-3 / -vl) does NOT match imageOnly
- Mistral 4 dense (no `-vl`) does NOT match imageOnly

---

## 3. Format extensions accepted

### Audio (Nemotron-3-Nano-Omni only)

| Extension | UTType bucket | vmlx canonicalization |
|---|---|---|
| `.wav` / `.wave` | `UTType.wav` | passthrough |
| `.mp3` / `.mpeg` | `UTType.mp3` | passthrough |
| `.m4a` / `.x-m4a` | `UTType.mpeg4Audio` | passthrough |
| `.mp4` (audio container) | `UTType.mpeg4Audio` | **canonicalizes to `.m4a`** |
| `.flac` | `UTType.audio` parent | passthrough |
| `.ogg` / `.opus` | `UTType.audio` parent | passthrough |
| `.aac` / `.wma` | `UTType.audio` parent | passthrough |

The audit-fix in `ModelRuntime.materializeMediaDataUrl` ensures the
audio-mime canonicalization (`mp4 → m4a`) only runs when the data URL
header starts with `audio/`. Locked by
`MaterializeMediaDataUrlMCDCTests.test_d6_videoMp4_keepsMp4Extension`.

### Video (omni + Qwen-VL family + SmolVLM 2)

| Extension | UTType bucket | Container preserved |
|---|---|---|
| `.mp4` | `UTType.mpeg4Movie` | `data:video/mp4` → `.mp4` |
| `.mov` | `UTType.quickTimeMovie` | `data:video/quicktime` → `.quicktime` |
| `.m4v` | `UTType.movie` parent | `.m4v` |
| `.webm` / `.mkv` / `.avi` | `UTType.video` parent | passthrough |

### Image (every VLM family)

PNG, JPEG, HEIC, TIFF, BMP, WebP via `CGImageSource`. The composer
auto-converts HEIC/TIFF/BMP → PNG inline so vmlx receives a uniform
`data:image/png;base64,...` shape.

---

## 4. Memory + cache behavior

### Inline payload limits

The composer enforces inline-byte caps before attaching:

| Modality | Cap | Rationale |
|---|---|---|
| Image | 16 MB (existing `maxImageSize`) | RADIO / Pixtral / Qwen ViT all comfortably handle ≤4K resolution |
| Audio | 50 MB | A 50 MB wav at 16 kHz mono is ~26 minutes — beyond that, route through streaming API |
| Video | 100 MB | Engine extracts 8 frames default; longer clips just sample fewer per-second frames anyway |

Files exceeding the cap show a toast and don't attach.

### Spillover to encrypted blob store

After the user sends a turn, `AttachmentBlobStore.spillIfNeeded`
walks the attachments and writes inline bytes that exceed the
modality threshold to `~/.osaurus/blob-store/<hash>` (encrypted by
the at-rest key from `StorageMigrationCoordinator`):

| Attachment kind | Spill threshold |
|---|---|
| Image | `spillThreshold` (existing — 64 KB) |
| Document | same `spillThreshold` |
| Audio | `Attachment.audioSpillThresholdBytes` = **256 KB** |
| Video | `Attachment.videoSpillThresholdBytes` = **64 KB** |

Audio uses a higher threshold because chat history reads are frequent
and small audio clips (< 256 KB ≈ 8 s wav) keep the SQLite page
cache warm. Video uses an aggressive 64 KB threshold — virtually
all real video attachments spill; the inline path exists only for
in-memory request lifetimes.

After spillover the chat-history JSON column carries:

- `audio_ref { hash, byteCount, format, filename }` (for audio)
- `video_ref { hash, byteCount, filename }` (for video)

Hydration on next read goes through `AttachmentBlobStore.read(hash)`,
same code path images already use.

### KV cache + media salt

vmlx's `CacheCoordinator` keys disk-cache entries on `(model,
prefix_hash, media_salt)`. The media salt is computed from the
pixel/audio bytes so different attachments → different salt → no
false sharing across requests. Tested via
`CacheCoordinatorMediaSaltTests` (8 tests, all green at pin
`03b4441`).

This means: re-attaching the same audio file across turns hits the
disk-cache. Different audio files do not collide.

### TurboQuant (JANGTQ) runtime compatibility

JANGTQ-quantized bundles work end-to-end with all modalities:

- **Nemotron-3-Nano-Omni JANGTQ4 / JANGTQ**: vmlx's
  `NemotronHJANGTQModel` handles the codebook MoE path while Parakeet
  + RADIO encoders run at full precision (encoder weights stay
  bf16/fp16 per the bundle's `mxtq_bits.vision_tower="passthrough_fp16"`
  config).
- **Qwen 3.5/3.6 MoE VL JANGTQ**: `Qwen35JANGTQModel` for the language
  decoder; vision tower stays full precision.
- **MiniMax M2 JANGTQ**: text-only, no media gate.

The host-side preflight `validateJANGTQSidecarIfRequired` checks for
`jangtq_runtime.safetensors` whenever `jang_config.json.weight_format
== "mxtq"`. Bundles missing the sidecar surface a clear error rather
than letting vmlx hit `abort()` in `TurboQuantSwitchLinear`.

### MXFP4 runtime

MXFP4 bundles need no sidecar — vmlx loads weights directly via the
standard MLX dequant path. All modality paths work uniformly.

---

## 5. Streaming + cancellation

`BatchEngine.generate` returns `AsyncThrowingStream<GenerationEvent, Error>`.
Event types are uniform across modalities:

- `.chunk(String)` — visible content tokens
- `.reasoning(String)` — `<think>` block tokens (Nemotron-3 with `enable_thinking=true`)
- `.toolCall(...)` — structured tool calls
- `.usage(...)` — final token counts on close

Audio + video preprocessing is **pre-prefill**. When the user clicks
send, the chat UI shows "transcribing audio…" / "extracting video
frames…" while preprocessing runs in `Task.detached`. Cancellation
during this window is cooperative — the file decode respects task
cancellation.

TTFT is measured via `TTFTTrace` and includes preprocessing latency.
Typical M5 Max numbers:

| Workload | TTFT | First-chunk latency |
|---|---|---|
| Text-only 4K prompt, Nemotron-3 MXFP4 | ~250 ms | ~250 ms |
| + 1 image | ~400 ms | ~150 ms ViT encode |
| + 8-frame video | ~800 ms | ~550 ms ViT encode |
| + 30 s audio | ~700 ms | ~450 ms Parakeet encode |

---

## 6. Programmatic API (for plugins / shortcuts)

```swift
import OsaurusCore

// Build an audio attachment from a file URL:
let url = URL(fileURLWithPath: "/path/to/clip.wav")
let data = try Data(contentsOf: url)
let attachment = Attachment.audio(data, format: "wav", filename: "clip.wav")

// Or video:
let videoAttachment = Attachment.video(
    try Data(contentsOf: videoURL),
    filename: "scene.mp4"
)

// Append to pending queue (UI auto-rejects if model can't consume):
pendingAttachments.append(attachment)

// Or build a ChatMessage directly (for HTTP API path):
let message = ChatMessage(
    role: "user",
    text: "Transcribe this clip",
    imageData: [],
    audios: [(data: data, format: "wav")],
    videos: []
)
```

---

## 7. Capability detection — programmatic surface

```swift
import OsaurusCore

let caps = ModelMediaCapabilities.from(modelId: currentModelId)

if caps.supportsAudio {
    // show audio picker / drop zone
}
if caps.supportsVideo {
    // show video picker / drop zone
}

// Or summary string for tooltips:
print(caps.summary)
// → "image + video + audio"  (omni)
// → "image + video"          (Qwen-VL family)
// → "image"                   (image-only VLMs)
// → "text-only"               (dense LLMs)
```

For accuracy after model load, prefer:

```swift
let caps = ModelMediaCapabilities.from(
    directory: localModelDirectory,
    modelId: modelId
)
```

This reads `config_omni.json` + `config.json` directly, so
ambiguous IDs that the regex can't disambiguate (e.g. some
community-renamed bundles) resolve correctly via the on-disk config.

---

## 8. Test coverage

| Layer | Test file | Cases |
|---|---|---|
| Capability detection (regex/substring) | `Tests/Model/ModelMediaCapabilitiesMCDCTests.swift` | 27 MC/DC-shaped |
| API content-part round-trip | `Tests/Model/MultimodalContentPartTests.swift` | 9 |
| Data URL materialization audit fix | `Tests/Model/MaterializeMediaDataUrlMCDCTests.swift` | 11 MC/DC |
| Hybrid-cache substring matcher | `Tests/Service/IsKnownHybridModelMCDCTests.swift` | 14 MC/DC |
| Bug 3a guard (engine) | `vmlx Tests/MLXLMTests/EvaluateRepetitionPenaltyMCDCTests.swift` | 11 MC/DC |
| Reasoning stamp resolution (engine) | `vmlx Tests/MLXLMTests/ReasoningStampMCDCTests.swift` | 17 MC/DC |

Total: 89 MC/DC-shaped + media-modality tests. Run via:

```bash
cd Packages/OsaurusCore
swift test --filter "MediaCapabilities|MaterializeMediaDataUrl|IsKnownHybridModel|MultimodalContentPart"
```

---

## 9. Adding support for a new family

When vmlx adds video/audio support to a new family:

1. Update `vmlx-swift-lm/Libraries/MLXLMCommon/BatchEngine/MEDIA-MODEL-MATRIX.md`
   with the new entry (modality, cache topology, JANGTQ class)
2. Update `Models/Configuration/ModelMediaCapabilities.swift`
   `from(modelId:)` regex/substring branch + `from(directory:modelId:)`
   `videoCapableModelTypes` set
3. Add MC/DC test rows in `ModelMediaCapabilitiesMCDCTests.swift`
   for the new family + boundary case (e.g. bare-name without `-vl`
   suffix that should NOT match)
4. Update this doc's matrix in §2 + §3
5. Verify `AttachmentBlobStore.spillIfNeeded` switch is exhaustive
   (Swift will catch this at compile time anyway)

---

## 10. References

- Engine matrix: `vmlx-swift-lm/Libraries/MLXLMCommon/BatchEngine/MEDIA-MODEL-MATRIX.md`
- Parakeet + RADIO Nemotron-3 specifics: `vmlx-swift-lm/.../PARAKEET-RADIO-INTEGRATION.md`
- MC/DC strategy: `vmlx-swift-lm/.../MCDC-COVERAGE-STRATEGY.md`
- Cache coordinator policy: `vmlx-swift-lm/.../KV-SIZING-CONTRACT.md`
- Host integration: `vmlx-swift-lm/.../OSAURUS-INTEGRATION.md`
