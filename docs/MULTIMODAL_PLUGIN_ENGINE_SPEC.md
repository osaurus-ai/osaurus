# Multimodal plugin and engine integration spec

This is the working spec for an Osaurus council or multimodal chat plugin.
The expected product shape is:

- Users bring their own provider keys.
- The plugin can call local Osaurus/vmlx models and remote OpenAI-compatible
  providers.
- Image, video, audio, reasoning, and tool calls use the same structured chat
  contracts that the main app uses.
- The plugin does not invent its own prompt serializer unless the target
  provider requires it.

## T-M lane outcome

This lane turns multimodal plugin input/output from a product idea into a
reviewable contract. It is intentionally docs/spec only unless a later
implementation slice identifies a narrow, testable model or host API hole.

In scope:

- A canonical plugin input shape for text, image, audio, video, tools,
  reasoning preferences, member routing, and per-turn session identity.
- A canonical plugin output shape for streamed text, reasoning deltas, tool
  calls, final usage, member failures, and shared artifact references.
- Acceptance criteria that can be converted into tests before any broad council
  or plugin-browser feature work.
- A threat model for media exfiltration, key leakage, resource exhaustion,
  cross-agent contamination, tool abuse, and reasoning disclosure.
- Small implementation slices that keep model/runtime, plugin host, UI, and
  provider work independently reviewable.

Out of scope for this spec revision:

- A new ABI version.
- First-class generated image/audio/video output from local models.
- A plugin marketplace or community browser.
- Replacing the existing OpenAI-compatible request/stream format.

## Acceptance criteria

Any implementation PR claiming T-M multimodal plugin support must satisfy all
rows that match its slice. A docs-only slice satisfies this table by making the
future evidence explicit.

| Area | Required behavior | Evidence |
|---|---|---|
| Input contract | Plugins call `host->complete`, `host->complete_stream`, or the Osaurus HTTP API with ordered OpenAI-compatible content parts. `text`, `image_url`, `input_audio`, and `video_url` survive decode/re-encode without lossy string prompt flattening. | Codable tests for mixed content parts plus a plugin-host completion test that observes the mapped `ChatMessage` parts. |
| Local media mapping | Local execution maps images to `Chat.Message.images`, videos to `Chat.Message.videos`, and audio to `Chat.Message.audios`; valid WAV audio maps to samples where supported and mp4 video remains video mp4. | `MultimodalContentPartTests`, `MaterializeMediaDataUrlMCDCTests`, and one plugin-host fixture that exercises the same path through `complete_stream`. |
| Capability gating | A text-only local model never receives image/audio/video content. Unsupported media fails closed with a structured error or an explicit downgrade record. | Model-capability tests for text-only, image, video, and Nemotron-Omni-style audio cases. |
| Remote consent | Media bytes, local file contents, memory, folder context, tool output, and reasoning are not sent to remote members unless the user explicitly enabled that member and configured its BYO key. | Unit tests for member routing plus redacted log snapshots for denied and allowed remote routes. |
| Output contract | Streaming exposes visible text as `delta.content`, reasoning as `delta.reasoning_content`, tool calls as `delta.tool_calls`, and terminal state as `finish_reason` plus usage when available. Binary outputs are returned only as shared artifact references until a dedicated media-output ABI exists. | Stream parser tests and a manual plugin smoke that cancels, finishes, and handles tool-call termination. |
| Tool isolation | Tool calls are allowlist-checked, user-consented when sensitive, and returned only to the member/session that requested the matching `tool_call_id`. | Tool-call tests covering allowed, denied, cross-member mismatch, and timeout paths. |
| Session/cache isolation | Each council member has a stable session key, distinct media salt, and no cache sharing across members, agents, or changed media. | Local cache tests or structured logs showing member id, session key, media counts, and media salt. |
| Observability | Logs include member id, model id, provider kind, media counts, sanitized formats, timing, finish reason, and redacted error codes. Logs never include provider keys, auth headers, base64 media, raw tool output, or hidden reasoning. | Redaction tests plus Insights or structured-log snapshot checks. |

## Recommended integration paths

There are two supported ways to call multimodal generation.

### Path A: Osaurus OpenAI-compatible HTTP API

Use this for most plugins. It is stable, provider-like, and naturally works
with BYO keys and remote/local routing.

Endpoints:

```text
POST /v1/chat/completions
POST /chat/completions
```

Message content parts supported by Osaurus:

| Part type | Shape | Local mapping |
|---|---|---|
| `text` | `{ "type": "text", "text": "..." }` | message text |
| `image_url` | `{ "type": "image_url", "image_url": { "url": "data:image/png;base64,..." } }` | `UserInput.Image.url` after materialization |
| `input_audio` | `{ "type": "input_audio", "input_audio": { "data": "<base64>", "format": "wav" } }` | valid WAV to `UserInput.Audio.samples`; fallback file URL for converter-backed formats |
| `video_url` | `{ "type": "video_url", "video_url": { "url": "data:video/mp4;base64,..." } }` | temp file, then `UserInput.Video.url` |

Assistant messages may include:

- `reasoning_content`: prior hidden/visible thinking text that local thinking
  templates may need on follow-up turns.
- `tool_calls`: OpenAI-style structured tool calls.

Tool-role messages should include:

- `tool_call_id`: the id from the assistant tool call being answered.

### Canonical plugin input

For ABI-hosted plugins, the request body for `host->complete` and
`host->complete_stream` is the same OpenAI-compatible JSON shape described
above. The plugin must keep multimodal data as structured content parts until
the host maps it into `ChatMessage` / vmlx types.

Minimum request:

```json
{
  "model": "local-vl-model-id",
  "session_id": "optional-stable-session-key",
  "stream_id": "optional-plugin-generated-uuid-for-complete_stream",
  "messages": [
    {
      "role": "user",
      "content": [
        {"type": "text", "text": "Describe this media."},
        {"type": "image_url", "image_url": {"url": "data:image/png;base64,..."}},
        {"type": "input_audio", "input_audio": {"data": "...", "format": "wav"}},
        {"type": "video_url", "video_url": {"url": "data:video/mp4;base64,..."}}
      ]
    }
  ],
  "tools": [],
  "metadata": {
    "member_id": "local-zaya-vl",
    "member_kind": "local_osaurus",
    "remote_media_allowed": false
  }
}
```

Input rules:

- Preserve content-part order. Do not merge media into text placeholders except
  when a deliberate downgrade step records what happened.
- Keep `session_id` stable per member and agent. Use a different session when
  the user switches member identity, provider, or privacy policy.
- Use `stream_id` only for `complete_stream` cancellation. It must be unique per
  active stream and generated by the plugin.
- Treat `metadata` as diagnostic context only. The host's security boundary is
  still the TLS-bound active agent and plugin context; caller-supplied agent
  ids or addresses are ignored by host APIs.
- Base64 media should be a request payload detail, not a logging surface.

### Canonical plugin output

V1 multimodal plugin output is text-first and stream-compatible. The plugin may
render or aggregate these events, but it should not reinterpret them as a
provider-specific format:

| Output | Shape | Handling rule |
|---|---|---|
| Visible text | `choices[].delta.content` or final `message.content` | Append to the visible member transcript. |
| Reasoning | `choices[].delta.reasoning_content` or `message.reasoning_content` | Render only when user policy allows it; never merge into visible text. |
| Tool call | `choices[].delta.tool_calls` or final `message.tool_calls` | Execute only after allowlist and consent checks, then return a matching tool-role message. |
| Terminal state | `finish_reason`, `usage`, `tool_calls_executed`, `shared_artifacts` | Close the member stream and record final metrics. |
| Member error | Standard error envelope with `error` and `message` | Fail that member; continue the council run unless every required member failed. |
| Binary output | `shared_artifacts` references | V1 has no raw image/audio/video generation bytes in `complete_stream`; put files in shared artifacts. |

Cancellation uses the existing `stream_id` plus `complete_cancel` contract. The
final cancelled response must include the same `stream_id`, partial content if
available, and redacted usage/tool/artifact metadata.

### Path B: In-process vmlx Swift

Use this only for core Osaurus code or a trusted local plugin host that links
against vmlx. This path gives direct access to `ModelContainer`, but it also
means the plugin owns load policy, memory policy, cancellation, and event
routing.

Current vmlx primitives:

| API | Purpose |
|---|---|
| `MLXLMCommon.Chat.Message` | Structured role/content/media/tool/reasoning turn |
| `MLXLMCommon.UserInput` | Prompt plus images, videos, audios, tools, and template context |
| `ModelContainer.prepare(input:)` | Runs tokenizer, chat template, and media processor |
| `ModelContainer.generate(input:parameters:)` | Streams generation events |
| `GenerateParameters` | max tokens, sampling, prefill step, KV quant, compile flags, stop strings |
| `Generation.chunk` | Visible assistant text |
| `Generation.reasoning` | Reasoning pane delta |
| `Generation.toolCall` | Structured tool call |
| `Generation.info` | Terminal counts, timing, stop reason |

## Local vmlx Swift example

This example intentionally focuses on current request/stream shapes. The host
still chooses the exact downloader/tokenizer loader and local model path.

```swift
import Foundation
import MLXLMCommon

let modelURL = URL(fileURLWithPath: "/path/to/local/model")

let container = try await loadModelContainer(
    from: modelURL,
    using: tokenizerLoader,
    loadConfiguration: .default
)

let imageURL = URL(fileURLWithPath: "/tmp/input.png")
let audioURL = URL(fileURLWithPath: "/tmp/question.wav")
let videoURL = URL(fileURLWithPath: "/tmp/clip.mp4")

let chat: [Chat.Message] = [
    .system("Answer briefly. Use tools only when needed."),
    .user(
        "Describe the image, summarize the clip, and note anything audible.",
        images: [.url(imageURL)],
        videos: [.url(videoURL)],
        audios: [.url(audioURL)]
    ),
]

let input = UserInput(
    chat: chat,
    processing: .init(),
    tools: nil,
    additionalContext: [
        "enable_thinking": false
    ]
)

let prepared = try await container.prepare(input: input)

var params = await container.defaultGenerateParameters(
    fallback: GenerateParameters(maxTokens: 512)
)

let stream = try await container.generate(input: prepared, parameters: params)

for await event in stream {
    switch event {
    case .chunk(let text):
        print(text, terminator: "")
    case .reasoning(let text):
        // Route to a thinking pane, or ignore if the plugin does not expose it.
        print("[thinking] \(text)")
    case .toolCall(let call):
        // Execute only allowlisted tools, then send a tool-role follow-up.
        print("tool call: \(call.function.name)")
    case .info(let info):
        print("\nstop=\(info.stopReason) generated=\(info.generationTokenCount)")
    }
}
```

Important rules for in-process use:

- Prefer `UserInput(chat:)` over raw string prompts for multimodal chat.
- Put media on the `Chat.Message` that owns it. `UserInput(chat:)` copies those
  media arrays into top-level `images`, `videos`, and `audios` for processors.
- Preserve `reasoningContent` on assistant history when replaying a local
  thinking-model conversation.
- Preserve `toolCalls` on assistant messages and `toolCallId` on tool messages.
- Use `container.defaultGenerateParameters(fallback:)` if the plugin wants the
  bundle's `generation_config.json` defaults.
- Keep `additionalContext` model-aware. Common keys are `enable_thinking` and
  `reasoning_effort`, but not every family uses both.
- For trusted local live voice, prefer retained PCM snapshots or fresh
  `UserInput.Audio.preEncoded` embeddings. Do not concatenate independently
  encoded Parakeet chunks; current bench evidence shows they are not
  prefix-stable.

## HTTP examples

Image:

```sh
IMAGE_B64="$(base64 -i /tmp/input.png | tr -d '\n')"

curl http://127.0.0.1:4242/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d "{
    \"model\": \"local-vl-model-id\",
    \"stream\": true,
    \"messages\": [{
      \"role\": \"user\",
      \"content\": [
        {\"type\": \"text\", \"text\": \"Describe this image.\"},
        {\"type\": \"image_url\", \"image_url\": {\"url\": \"data:image/png;base64,$IMAGE_B64\"}}
      ]
    }]
  }"
```

Audio:

```sh
AUDIO_B64="$(base64 -i /tmp/question.wav | tr -d '\n')"

curl http://127.0.0.1:4242/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d "{
    \"model\": \"nemotron-omni-model-id\",
    \"stream\": true,
    \"messages\": [{
      \"role\": \"user\",
      \"content\": [
        {\"type\": \"text\", \"text\": \"Transcribe this audio and answer the question.\"},
        {\"type\": \"input_audio\", \"input_audio\": {\"data\": \"$AUDIO_B64\", \"format\": \"wav\"}}
      ]
    }]
  }"
```

Video:

```sh
VIDEO_B64="$(base64 -i /tmp/clip.mp4 | tr -d '\n')"

curl http://127.0.0.1:4242/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d "{
    \"model\": \"local-video-vl-model-id\",
    \"stream\": true,
    \"messages\": [{
      \"role\": \"user\",
      \"content\": [
        {\"type\": \"text\", \"text\": \"Summarize this clip.\"},
        {\"type\": \"video_url\", \"video_url\": {\"url\": \"data:video/mp4;base64,$VIDEO_B64\"}}
      ]
    }]
  }"
```

Tool follow-up:

```json
[
  {
    "role": "assistant",
    "content": "",
    "tool_calls": [
      {
        "id": "call_weather",
        "type": "function",
        "function": {
          "name": "get_weather",
          "arguments": "{\"location\":\"San Francisco\"}"
        }
      }
    ]
  },
  {
    "role": "tool",
    "tool_call_id": "call_weather",
    "content": "{\"temperature_f\": 62}"
  }
]
```

## Council plugin design

A council plugin should not be a single prompt string passed to N providers.
It should be a coordinator with explicit member capabilities.

Suggested member config:

```json
{
  "id": "local-zaya-vl",
  "display_name": "Local ZAYA VL",
  "kind": "local_osaurus|openai_compatible|custom_http",
  "base_url": "http://127.0.0.1:4242/v1",
  "model": "ZAYA1-VL-8B-JANGTQ4",
  "api_key_ref": "keychain://osaurus/plugins/council/local-zaya-vl",
  "modalities": ["text", "image", "video"],
  "supports_tools": true,
  "supports_reasoning": true,
  "timeout_seconds": 90
}
```

Execution flow:

1. Normalize the user turn into one internal content-part list: text, images,
   audio, video, and optional tool specs.
2. Resolve each council member's modality support. Reject unsupported media or
   downgrade intentionally, for example image caption by a local VLM before
   sending text to a text-only remote member.
3. Build per-member OpenAI-compatible messages.
4. Fan out with per-member timeouts and cancellation.
5. Stream member deltas to the UI under member ids.
6. Execute only allowlisted tool calls, then send tool-role follow-ups to the
   same member session.
7. Feed member final answers into a synthesizer member or local model.
8. Persist `reasoning_content` only when the user setting permits it and the
   target model requires it for multi-turn continuity.

## BYO key rules

- Store provider keys in Keychain or the approved Osaurus secret store. Config
  files should contain only `api_key_ref`, never raw key bytes.
- Do not send local files, media bytes, memory entries, folder context, or tool
  outputs to a remote provider unless the user explicitly enabled that member.
- Redact `Authorization`, provider keys, base64 media, and tool outputs in logs.
- The plugin should support a "local only" mode where every remote member is
  disabled.
- Failed/missing BYO keys should fail that member cleanly, not the full council
  run, unless all members fail.

## Capability and model checks

Before submitting to a local Osaurus model:

- Use `ModelMediaCapabilities.from(modelId:)` or
  `ModelMediaCapabilities.from(directory:modelId:)` to validate media support.
- Keep text-only models from receiving image/audio/video content parts.
- Treat audio support as Nemotron-Omni-only until another local model advertises
  a proven audio processor.
- ZAYA1-VL must be detected as `zaya1_vl` / VLM, not routed through text-only
  ZAYA. A config parse failure here usually means the model-family or quant
  metadata detector is wrong, not that the user media should be dropped.
- For local thinking models, set the same model options the app uses. Do not
  invent a plugin-only thinking policy.
- If the model is local and cached, keep the same member/session stable across
  turns so prefix cache can hit.
- Keep media byte identity stable. Re-encoding the same file differently can
  produce a different media salt and defeat cache reuse.

## Reasoning policy

The plugin should expose three modes:

| Mode | Behavior |
|---|---|
| Off | Ask local models to disable thinking when supported; do not render reasoning |
| On | Pass model-specific thinking context and render `.reasoning` separately |
| Auto | Follow Osaurus model defaults and family policy |

Rules:

- Do not display raw `<think>` tags. The engine should emit `Generation.reasoning`
  for reasoning bytes and `Generation.chunk` for visible bytes.
- Do not force fake close tags in plugin code.
- Preserve `reasoning_content` only for model families that need it on
  follow-up turns and only if the user setting allows it.
- Ling-family models are non-reasoning in current Osaurus policy.

## Tool policy

Remote and local models can emit tool calls, but the plugin is responsible for
execution policy.

- Only execute tools from an allowlist.
- Require user consent for tools that touch filesystem, network, shell, memory,
  or secrets.
- Bind each tool result to the originating `tool_call_id`.
- Feed tool-role replies back to the same member that requested the tool.
- Prevent cross-member tool-call contamination. Member A's tool result should
  not be sent as a tool-role reply to member B unless the synthesizer explicitly
  includes it as plain text evidence.

## Cache/session policy

For local Osaurus members:

- One council member should map to one stable chat session key.
- Do not rebuild the system prefix differently on every turn unless the member
  intentionally needs new context.
- Keep memory/tool sections deterministic so prompt hashes remain useful.
- Different media should produce distinct media salt and avoid false cache hits.
- Switching members must not share cache state.
- Keep cache claims topology-specific. ZAYA/ZAYA1-VL CCA, hybrid SSM, DSV4
  compressor state, and dense KV do not have interchangeable prefix-cache
  semantics.

For remote members:

- Provider context caching is provider-specific. Do not assume local vmlx cache
  behavior applies remotely.

## Threat model

The T-M surface crosses local media, remote providers, tools, memory, and
agent-scoped plugin state. Treat every crossing as an explicit policy decision.

| Threat | Impact | Required mitigation |
|---|---|---|
| Media exfiltration to a remote member | Private screenshots, audio, video, pasted files, or folder context leave the machine unexpectedly. | Remote members are disabled by default for local artifacts. Each remote member needs explicit user enablement, a BYO key, and a per-run routing record for which media kinds were sent. |
| Provider key leakage | BYO keys appear in config files, logs, tool output, crash reports, or model-visible context. | Store only Keychain-backed refs in plugin config. Redact `Authorization`, provider keys, cookies, and signed URLs before logging or returning errors. |
| Prompt/tool injection through media or metadata | OCR text, audio transcript, EXIF, filenames, captions, or remote member output tricks the plugin into running tools or revealing secrets. | Treat media-derived text as untrusted user content. Require the normal tool allowlist and consent path, and never promote media metadata into system or developer instructions. |
| SSRF and private-network reachability | A plugin or provider fetches `image_url` / `video_url` content from localhost, link-local, RFC1918, or metadata services. | Prefer data URLs or host-owned artifact reads for local media. For plugin outbound HTTP, use `host->http_request` and its SSRF guard; for provider-sent URLs, validate the URL policy before handing it off. |
| Resource exhaustion | Large videos/audio, base64 expansion, council fan-out, or repeated retries starve host memory, disk, GPU, or worker threads. | Enforce request size caps, per-member timeout, plugin inference concurrency, temp-file cleanup, and retry budgets. Emit `plugin_busy`, timeout, or structured media-size errors instead of queueing unbounded work. |
| Cross-agent or cross-member contamination | A plugin sends agent A's memory/media/tool output to agent B, or member A receives member B's tool result. | Rely on host active-agent scoping for `complete`/`dispatch`; ignore caller-supplied agent ids. Key plugin state by `(plugin_id, agent_id, member_id, session_id)` and bind tool replies to the originating `tool_call_id`. |
| Reasoning disclosure | Hidden reasoning or model-private thinking is displayed, persisted, sent to remote providers, or included in synthesizer prompts without consent. | Keep reasoning deltas on a separate channel. Persist or forward `reasoning_content` only when the user setting and model-family continuity requirement both allow it. |
| Cache confusion | Re-encoded media or shared session keys produce false cache hits, stale context, or cross-member state reuse. | Preserve media byte identity where possible, include media salt in local cache evidence, and never share local session/cache keys across members or agents. |

## Implementation slices

These slices are intentionally small enough to land independently. Each slice
should update this spec if the implementation discovers a narrower contract.

| Slice | Scope | Acceptance gate |
|---|---|---|
| T-M0 spec baseline | Keep `docs/MULTIMODAL_PLUGIN_ENGINE_SPEC.md` and the development plan current. No code. | `git diff --check` over touched docs and a clean worktree before PR publication. |
| T-M1 host API contract tests | Add plugin-host tests proving `host->complete` / `complete_stream` preserve `image_url`, `input_audio`, `video_url`, `reasoning_content`, and `tool_calls` through the existing OpenAI-compatible request path. | Focused plugin and model mapping tests; no ABI version bump unless a missing field is proven. |
| T-M2 capability discovery | Expose local model media capabilities to plugins through an existing safe surface, preferably `list_models().models[].capabilities`, before adding any new callback. | Tests for text-only, image, video, and audio capability rows; docs in `osaurus_plugin.h` if the response shape changes. |
| T-M3 member request model | Introduce an internal `CouncilMemberRequest` or equivalent typed model for member id, provider kind, model id, modalities, session key, consent flags, timeouts, tools, and reasoning policy. | Unit tests for unsupported-media rejection, deliberate downgrade records, redacted errors, and stable per-member session ids. |
| T-M4 streaming/output adapter | Normalize member stream events into visible text, reasoning, tool calls, terminal usage, cancellation, member errors, and shared artifacts. | Stream parser tests for stop, length, tool_calls, max_iterations, cancelled, timeout, and all-member-failed cases. |
| T-M5 tool and consent gate | Route member tool calls through allowlist and sensitive-tool consent, then return tool-role replies only to the requesting member. | Tool isolation tests for allowed, denied, timeout, malformed args, and cross-member `tool_call_id` mismatch. |
| T-M6 observability and redaction | Add structured logs for member id, provider kind, model id, media counts, sanitized formats, durations, finish reason, cache/media-salt hints, and redacted failures. | Redaction tests verifying no auth header, provider key, base64 media, raw tool output, or reasoning text reaches logs. |
| T-M7 manual smoke plugin | Add or update a small local plugin fixture that sends image, audio, video, reasoning, and tool-call prompts through the public host API. | Manual smoke notes plus focused automated fixture checks; no network provider required for the local-only path. |

## Plugin validation matrix

Before shipping a council/multimodal plugin, run:

| Scenario | Expected result |
|---|---|
| Text-only local member | text streams, no media accepted |
| Local image VLM | image content reaches `Chat.Message.images` and answer references image |
| Local video VLM | video content reaches `Chat.Message.videos`; mp4 stays video mp4 |
| Local omni | audio reaches `Chat.Message.audios`; valid WAV maps to samples and resident live voice can use fresh pre-encoded Parakeet |
| Mixed council, image prompt | image-capable members receive image; text-only members are skipped or get caption downgrade |
| BYO key missing | only that member fails with a redacted error |
| Remote timeout | council continues with other members and reports timeout |
| Tool call | tool is allowlist-checked, executed, and fed back with matching `tool_call_id` |
| Reasoning on/off/on | UI state and engine context stay consistent across turns |
| Same media, turn 2 | local member cache can hit where topology supports it |
| Changed media, turn 2 | local member cache does not false-hit across media |

## Osaurus-side gaps worth adding before large plugin work

These are not required to start a plugin, but they will make future debugging
much cleaner:

- Add `videos`, `audios`, and media salt to `MLXBatchAdapter.prepareInput`
  structured logs.
- Add a first-class internal `CouncilMemberRequest` type rather than passing
  loosely-shaped dictionaries between plugin layers.
- Add a plugin-facing media-capability endpoint so a plugin can ask the app
  what the currently loaded local model accepts.
- Add a plugin-facing runtime-smoke command that returns the same JSON fields
  described in `RUNTIME_VALIDATION_STANDARD.md`.
- Add a redaction helper shared by remote providers and plugins so BYO key logs
  cannot drift.
