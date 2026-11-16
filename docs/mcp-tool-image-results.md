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

## Source and live evidence

Tested implementation: `37cfacbf00da61641eab0a964a0a0836b7cda43f`, based on
main `4a329449bf2026a049b50aa3b582ff81759f75bf`. Isolated development app
SHA-256: `3be94334a6c03fe58e805eed804616422b1f4890409aa077c8b648356b4d9792`.
Engine pin is unchanged. The evidence-only documentation follow-up does not
change compiled code, resources, tests, or configuration; the binary remains
identified by its actual tested source, not the documentation commit.

SOURCE EVIDENCE: `MCPProviderTool.swift:289-427` stages typed images off the UI
actor; `MCPProviderManager.swift:769` publishes the converted result;
`ToolResultMediaBridge.swift:33-97` resolves the original bytes through the
existing attachment store. The file-image implementation from #2791 is retained,
not replaced. No changed-file overlap with handoff drafts #2796/#2798, and
main's #2792 tool-stream and #2784 RAM-admission fixes are unchanged.

LIVE EVIDENCE: actual Chrome DevTools MCP 1.9.0 native Chat screenshot returned
the same 3,750-byte PNG as the baseline, now as 351 bytes of tool text plus an
image attachment. The subsequent runtime preparation logged `images=1`,
6,838 prompt tokens and normal completion at 76.480267 tok/s. A second visual
fixture, image-dependent follow-up, repeated screenshot, active MCP wait
cancellation and continuation all executed. The follow-up reused a disk-prefix
boundary at 7,784 tokens with 160 remaining tokens; repeated image positions
retain the same content-addressed blob. This is not a paired speed benchmark.

A real delegated child executed its own screenshot, prepared `images=1`, and
completed at 78.219845 tok/s; its parent completed at 79.122170 tok/s. Continuing
the same child retained the image and answered the middle blue square/BIRCH
question at 80.646847 tok/s, with normal parent continuation. Reopening the
original screenshot chat after app relaunch retained `images=2` and answered
the image question at 79.534169 tok/s. Cards settled, Stop disappeared, and
input unlocked. Original image blobs were re-read and hash-checked from history.

Proof model: `OsaurusAI/gemma-4-E2B-it-8bit`, snapshot
`433003a1e3fbfd10819ad15179d5e3c4d02d7ea7`, isolated 128 GB M5 Max2. Bundle
T1/P.95/K64, effective minP0, thinking off, MTP off; no sampler overrides.
All image continuations above ended normally, not at an output-length ceiling.
This does not qualify other quants, a 16 GB machine, or the reporter's freeze.

## Automated results and retained limitations

Focused run: 101 tests in 13 suites passed, including existing file-image tests
and new typed-MCP image, cap, order, duplicate, anti-forgery, malformed-data,
history, remote-encoding, pre-cancel and storage-failure cases. Seven required
CI jobs passed for the tested implementation in run `35277710053`.

Full current-source catalogs, with unchanged fixtures and raw scores:

| Catalog | Passed | Failed | Errored | Skipped | Total |
| --- | ---: | ---: | ---: | ---: | ---: |
| AgentLoop | 45 | 6 | 1 | 4 | 56 |
| AgentLoopFrontier | 20 | 17 | 5 | 0 | 42 |

These are **not all-pass** scores. Every non-pass and returned rubric is reviewed
in the private `EVAL-REVIEW-37cf.md`. Failures include incomplete model work,
invalid tool arguments, empty-after-tool continuations, unavailable dedicated
worker fixtures, a stale error-rejection expectation, and false-positive and
false-negative self-judge verdicts. Raw outcomes are not rewritten. The prior
same-catalog baseline was 42/8/2/4 and 17/21/4/0 respectively; unseeded outcome
variation does not establish a causal quality improvement or regression freedom.
These loopback catalogs do not transport MCP images; native UI evidence above
is the image-path proof.

During the final catalog app run, sampled app physical footprint peaked at
3,668,249,600 bytes; the kernel's lifetime maximum was 4,639,771,456 bytes.
Swap stayed at 1.81 GiB. The original supervisor limits were retained. Normal
Quit at 16:16:56 verified zero owned survivors. Test-agent tool assignments and
the MCP provider were restored through the real UI; test-only discovery
defaults were restored to their original absence. No release/tag/install.

Limits still open: occasional incorrect visual descriptions despite transported
images; separate pre-inference model-discovery filesystem stalls; a separately
reproduced required/named Gemma tool-choice path dropping user media; full
raster validation/pixel budgeting; mid-image-conversion cancellation; live
external-provider transport; and the broader RAM/delegation audit. The MCP
correction does not claim to fix those paths. Audio is unchanged. Existing
two-image-bearing-tool-message history policy is unchanged.

Private evidence root:
`/Users/eric/vmlx-private-evidence/handoff-parity-2026-09-16/implementation`.
Receipts: `run9-mcp-vl-evidence`, `run10-mcp-vl-fixed-evidence`,
`run12-mcp-vl-fixed-evidence`, `RUN10-MCP-REVIEW.md`, `RUN12-MCP-REVIEW.md`,
`EVAL-REVIEW-37cf.md`, `MCP-37CF-DIFF-REVIEW.md`, the exact-source catalog JSONs,
and `ui15-supervisor.stdout`. Focused test log SHA-256:
`1f0e0cb6e07a63b4aa70635ffa5895890dd5c13bd6c6b5954ce1d7a3ccfbfc53`.
No screenshots or model/user artifacts are committed to the repository.
