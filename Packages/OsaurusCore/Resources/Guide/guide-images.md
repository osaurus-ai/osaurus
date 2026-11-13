---
title: Image Generation
summary: Generate and edit images on-device with local image models; agents get one `image` tool.
order: 58
---

# Image Generation

Osaurus can create and edit images entirely on your Mac using local image models (FLUX, Qwen-Image, Z-Image Turbo, and other bundles via vMLX/mflux). No image ever leaves the device.

## Setup

- Settings… (⌘,) → Local Models → **Image**: browse and download on-device image model bundles (including native Wan 2.1 video bundles), or import one from Hugging Face.
- Settings… (⌘,) → Models → Model Defaults → **Images & Video**: the default generation model, the default edit model, the text-to-video and image-to-video models (local Wan or a cloud provider), and the **Image Model Load Policy**.
- Settings… (⌘,) → Images & Video: the permission for image jobs and local and cloud video jobs, and recent video jobs.
- Image models are large; they load on demand and can temporarily displace the resident chat model while a job runs.

## Using it in chat

- Just ask: "generate an image of …". Agents with image generation enabled call the single `image` tool.
- The same tool edits images: when the agent passes source image paths (from attachments or a prior result), the job runs in edit mode. Edit mode is only offered when a ready edit model is installed.
- Generation supports an optional negative prompt, size, step count, guidance scale, seed, and 1–8 images per call with local models. Edit mode takes as many ordered source images as the selected model's reference limit allows. Results render inline in the chat.
- A live progress card shows the job; you can stop it mid-run.

## API

The server exposes an OpenAI-compatible endpoint at `POST /v1/images/generations` when it is running, using the same local models.

Qwen-Image 2.1/Turbo results include `effective_parameters`: the actual dimensions, step count, guidance, seed and sampling schedule. Turbo uses its bundle's fixed schedule even when a different step count was requested. The generation panel displays the actual values after completion. Other backends omit this field until they support runtime parameter reporting; requested values are not a substitute for it.

## Notes

- Per-agent: enable **Image** under a custom agent's Subagents section (pick the gen/edit models and permission there). The built-in Orchestrator has no image tool of its own — add an image-enabled agent to Settings → Agents → Delegation → Allowed subagents and the Orchestrator delegates "generate an image of …" to it.
- If no image model is installed, the tool is not offered — download one in Local Models → Image first.
- Every image or video job is recorded in Main window → Insights (**Audio & Media** scope tab, **Media** rows) with the prompt, size, step count and provider. Local MLX jobs are **Local**; Venice jobs are **Cloud**; Osaurus Cloud jobs appear as **Router** rows.
