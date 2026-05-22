# AtlasCloud Provider Review

## Summary

This change adds AtlasCloud as a first-class remote provider preset using its documented OpenAI-compatible LLM endpoint:

- Host: `api.atlascloud.ai`
- Protocol: `HTTPS`
- Base path: `/v1`
- Chat endpoint: `/chat/completions`
- Auth: `Authorization: Bearer <api-key>`
- Tested model: `deepseek-ai/DeepSeek-V3-0324`

## What Changed

### Provider preset

- Added `ProviderPreset.atlasCloud`
- Added preset metadata for:
  - display name
  - description
  - icon
  - gradient
  - console URL
  - docs URL
  - help steps
- Wired AtlasCloud to the existing OpenAI-compatible provider path with `providerType: .openaiLegacy`

### Onboarding

- Added AtlasCloud to the curated cloud provider list in onboarding

### Documentation

- Updated `README.md` to mention AtlasCloud in supported cloud providers
- Added an AtlasCloud section to `README.md` with the provided logo image
- Updated `docs/REMOTE_PROVIDERS.md` with AtlasCloud preset details

### Tests

- Added targeted preset coverage for:
  - configuration values
  - known preset registration
  - preset matching by host
  - chat completions endpoint resolution

## Local-Only Changes

- AtlasCloud API key is intended to stay local only and must not be committed
- Stored locally in the repo root `.env`, which is already ignored by git
- Integration verification can be done without starting the full app by using:
  - targeted Swift tests
  - direct API requests against `https://api.atlascloud.ai/v1/chat/completions`
- AtlasCloud docs show `deepseek-v3` in examples, but live validation with this key succeeded using the discovered model ID `deepseek-ai/DeepSeek-V3-0324`

## Validation Results

- `GET /v1/models` succeeded and returned 107 models for this key during local verification
- `POST /v1/chat/completions` succeeded with model `deepseek-ai/DeepSeek-V3-0324`
- The response returned the exact expected text `atlascloud-ok`

## Environment Blockers

- `swift test --filter ProviderPresetsTests` was blocked by the local sandbox and required `--disable-sandbox`
- `swift test --disable-sandbox --filter ProviderPresetsTests` was then blocked by this machine failing to fetch SwiftPM dependencies from GitHub
- `xcodebuild` is unavailable because the active developer directory points to Command Line Tools instead of a full Xcode install

## Review Focus

- Confirm the product wants AtlasCloud branded as `AtlasCloud`
- Confirm `openaiLegacy` is the preferred runtime path for AtlasCloud chat completions
- Confirm whether product wants to document the docs alias `deepseek-v3` or the live-tested model ID `deepseek-ai/DeepSeek-V3-0324`
