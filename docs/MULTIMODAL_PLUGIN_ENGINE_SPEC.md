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
