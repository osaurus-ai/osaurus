---
title: Local Models
summary: Download and run MLX models on-device; Apple Foundation Models on macOS 26+.
order: 20
---

# Local Models

Osaurus runs open-weight models locally on Apple Silicon using MLX — no internet needed after download, and nothing you type leaves your Mac.

## Downloading models

- Settings… (⌘,) → Local Models shows the curated catalog with size estimates; download, pause, and delete from there.
- Or just ask the default Osaurus assistant in chat to download a model — it can list recommended models and start the download for you.
- Models are stored in `~/MLXModels` (override with the `OSU_MODELS_DIR` environment variable). Model weights live outside `~/.osaurus/`.

## Choosing a model

If an installed model has missing or damaged files, open its details in
**Local Models → On Device** and choose **Repair**. Osaurus checks file contents
against Hugging Face, restores changed or missing files, and displays progress
or a specific failure. Pause, Resume, and Cancel use the same controls as a
normal download. Intact files are kept. Repair can restore files you deliberately
edited or removed; ordinary model loading does not do this. External models stay
managed by their original application.

- Bigger models are smarter but slower and need more RAM; quantized variants (4-bit/8-bit) trade a little quality for much lower memory.
- The Models catalog is curated for Osaurus (tool calling, reasoning, and template support are validated), and the OsaurusAI page on Hugging Face hosts optimized bundles.
- Temperature, top-k, and the other sampling values come from each model bundle's own configuration unless you explicitly override them in Server → Settings → Sampling Defaults.

## Speculative Depth

Models with a supported native MTP head show **Speculative Depth** in the chat
model picker's options: Off, Auto, 1, 2, and 3. Flash Next starts **Off**, across
its quantizations; you can explicitly select Auto or a depth. Qwen3.8-27B keeps
its existing eligible depth-3 default. An explicit choice is preserved when
switching models or relaunching. A Flash Next default written automatically
does not switch 27B Off. Headless bundles, including Flash Next JANG_1L, do not
advertise MTP. Bundle safety blocks still apply. These controls do not override
your configured sampling settings or guarantee a throughput floor.

## Apple Foundation Models

On macOS 26+ with Apple Intelligence, the on-device Apple Foundation model is available as `foundation` — used out of the box as the "core model" for background jobs like memory distillation and chat titles (configurable in Settings → General → Core Model). It requires Apple Intelligence to be enabled in System Settings → Apple Intelligence & Siri. When it is turned off, the model is still downloading, or a request stalls, background jobs automatically run on your active chat model instead; the Core Model picker and Memory diagnostics show the reason.

## Model memory and loading

- Models load on first use. Residency (keep loaded / unload when idle) is configured in Server → Settings → Model Memory.
- RAM-safety settings (Server → Settings → Memory Safety) govern load admission and cache caps so a large model can't take down the system.
- If a model is too large for available RAM, Osaurus refuses the load with a clear error instead of letting the system swap or crash.
