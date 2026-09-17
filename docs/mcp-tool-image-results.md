# MCP tool image results

## Defect and scope

An actual native Chat run with Chrome DevTools MCP 1.9.0 reproduced a media
transport defect: a 3,750-byte PNG was serialized as 5,000 base64 characters
inside 5,228 characters of tool-result text. The subsequent Gemma E2B 8-bit
request reported `images=0`, with prompt tokens increasing from 6,371 to 9,873.
The tool turn had no attachments. This establishes an Osaurus integration bug,
not the cause of a particular user's freeze or a low-memory reproduction.

Baseline source: `9f064f4022c48eaba447e87bd7f9c3dd6af00897`; the MCP converter,
registry normalization, image bridge and adapter are identical in main
`4a329449bf2026a049b50aa3b582ff81759f75bf`. Engine pin:
`8ba593aff16c13cf526211b8477c0a037f0122af`. Baseline app SHA-256:
`dcc9ee578450668d55e5f44885fb50f74509d9274d8aa5fa777b30054f80e5cc`.
The 128GB M5 Max test used an isolated profile/browser and local-only fixture,
with screenshot dimensions bounded to 320x240. Native bundle sampling was
T1/P.95/K64/minP0, thinking off, no MTP. All three generation steps stopped
normally (80.706/79.447/77.813 tok/s); this was a failed image-forwarding row.

## Contract

- MCPProviderTool stages only *typed* image data (including embedded image
  resources) as content-addressed AttachmentBlobStore blobs. No URI fetching.
- A compact `mcp_content` success envelope preserves text entries, image order,
  duplicate image positions and tool identity. Base64 image bytes never enter
  the text output cap or text tokenizer. Oversized accompanying text uses the
  existing universal cap without splitting the image-reference structure.
- Single text results are enveloped at the typed boundary. Server text that
  resembles an internal media envelope remains literal text.
- ToolResultMediaBridge resolves only validated hash references. Native Chat,
  AgentSubagentRunner, saved-history rendering and existing remote provider
  encoders share the same image-part path and two-tool-message live window.
- Image validation and blob writes run off MainActor, with cooperative
  cancellation checked before result publication. Invalid image data or failed
  storage throws an error instead of reporting an attached image.
- No model, tokenizer template, sampler, RAM safety or cache policy is changed.
  MCP audio is a separate contract and is not covered by this image correction.

## Acceptance status

PARTIAL: baseline source/runtime defect reproduced; correction and regression
tests added. Fresh build, tests, corrected live image request, follow-up,
second tool call, history/relaunch, cache and resource proof are pending.
No merge or regression-free claim. Private baseline receipts are retained in
the `handoff-parity-2026-09-16/implementation/run9-mcp-vl-evidence` evidence
directory. No screenshots or model/user artifacts are committed here.
