---
title: Local Models
summary: Download and run MLX models on-device; Apple Foundation Models on macOS 26+.
order: 20
---

# Local Models

Osaurus runs open-weight models locally on Apple Silicon using MLX — no internet needed after download, and nothing you type leaves your Mac.

## Downloading models

- Management (⌘⇧M) → Models shows the curated catalog with size estimates; download, pause, and delete from there.
- Or just ask the default Osaurus assistant in chat to download a model — it can list recommended models and start the download for you.
- Models are stored in `~/MLXModels` (override with the `OSU_MODELS_DIR` environment variable). Model weights live outside `~/.osaurus/`.

## Choosing a model

- Bigger models are smarter but slower and need more RAM; quantized variants (4-bit/8-bit) trade a little quality for much lower memory.
- The Models catalog is curated for Osaurus (tool calling, reasoning, and template support are validated), and the OsaurusAI page on Hugging Face hosts optimized bundles.
- Generation defaults (temperature, top-k, etc.) come from each model bundle's own configuration unless you explicitly override them in Server → Settings → Generation defaults.

## Apple Foundation Models

On macOS 26+ with Apple Intelligence, the on-device Apple Foundation model is available as `foundation` — used out of the box as the "core model" for background jobs like memory distillation and chat titles (configurable in Settings → General → Core Model).

## Model memory and loading

- Models load on first use and can stay warm between requests (Settings → Chat → Warm Models on Load; residency policies in Server settings).
- RAM-safety settings (Server → Settings → Memory Safety) govern load admission and cache caps so a large model can't take down the system.
- If a model is too large for available RAM, Osaurus refuses the load with a clear error instead of letting the system swap or crash.
