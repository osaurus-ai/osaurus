---
title: Image Generation
summary: Generate and edit images on-device with local image models; agents get one `image` tool.
order: 58
---

# Image Generation

Osaurus can create and edit images entirely on your Mac using local image models (Flux-family bundles via vMLX/mflux). No image ever leaves the device.

## Setup

- Management (⌘⇧M) → Images → Models: browse and download on-device image model bundles, or import one from Hugging Face.
- Management → Images → Settings: choose the default generation model and (separately) the default edit model, plus the permission and model load policy.
- Image models are large; they load on demand and can temporarily displace the resident chat model while a job runs.

## Using it in chat

- Just ask: "generate an image of …". Agents with image generation enabled call the single `image` tool.
- The same tool edits images: when the agent passes source image paths (from attachments or a prior result), the job runs in edit mode. Edit mode is only offered when a ready edit model is installed.
- Generation supports an optional negative prompt, size, step count, guidance scale, seed, and up to 4 images per call. Results render inline in the chat.
- A live progress card shows the job; you can stop it mid-run.

## API

The server exposes an OpenAI-compatible endpoint at `POST /v1/images/generations` when it is running, using the same local models.

## Notes

- Per-agent: image generation is a spawnable capability toggled in the agent's Configure tab.
- If no image model is installed, the tool is not offered — download one in Management → Images → Models first.
