# vmlx-swift Single Package Switch

This branch starts the Osaurus migration from the old split runtime graph to one
consolidated `vmlx-swift` package.

## Dependency Contract

OsaurusCore now has one direct inference dependency:

- `https://github.com/osaurus-ai/vmlx-swift`
- revision `85fdef633b00d90035741e66c285b6b35da2299a`

That package is expected to export the runtime modules Osaurus previously pulled
from separate roots:

- `MLX`
- `MLXLMCommon`
- `MLXLLM`
- `MLXVLM`
- `Tokenizers`
- `Jinja`

The Osaurus manifest must not add direct inference roots for `mlx-swift`,
`vmlx-swift-lm`, `swift-transformers`, or `Jinja`. Any new runtime surface should
land in `vmlx-swift` first, then Osaurus should consume it through this single
pin.

## Transitive Module Collision Handling

Osaurus still depends on non-inference packages that bring their own tokenizer
or HTTP helper stacks:

- `VecturaKit` -> `swift-embeddings` -> `swift-transformers`
- `swift-sdk` -> `EventSource`

`vmlx-swift` vendors modules that would otherwise collide with those target
names. SwiftPM target names are package-graph global, so the vmlx package now
prefixes its vendored implementation targets internally:

- `Tokenizers` -> `VMLXTokenizers`
- `Jinja` -> `VMLXJinja`
- `EventSource` -> `VMLXEventSource`
- `HuggingFace` -> `VMLXHuggingFace`
- `Hub` -> `VMLXHub`
- `Generation` -> `VMLXGeneration`
- `Models` -> `VMLXModels`

This keeps Osaurus direct runtime imports bound to the consolidated vMLX package,
allows VecturaKit and MCP transitive modules to keep their normal module names,
and avoids Osaurus-side SwiftPM `moduleAliases` that would diverge from the
package's own public contract.

`yyjson` is intentionally not prefixed. It is a C package with public
`yyjson_*` symbols, so vendoring a second copy under a different SwiftPM target
name still links duplicate C symbols when another transitive package uses the
upstream `yyjson` package. `vmlx-swift` depends on the single upstream yyjson
product instead.

One non-inference root remains intentional: `EventSource` is declared directly
with the `AsyncHTTPClient` package trait enabled. MCP already brings this package
transitively, but without the trait SwiftPM compiles EventSource's optional
AsyncHTTPClient source after `canImport(AsyncHTTPClient)` becomes true and before
the target has declared NIO/shim dependencies. The root trait makes that dependency
contract explicit.

## MTP Policy Boundary

The pinned `vmlx-swift` revision refuses native MTP activation unless the model
bundle has both:

- real MTP tensor evidence in the weights/index; and
- usable bundle-local `vmlx_mtp_tuning.json`.

Explicit user flags cannot force MTP sidecar loading on a bundle that fails that
gate. This is intentional: MTP must be detected from the model artifact, not from
the model name, and activation must be driven by measured tuning rather than a
generic fallback.

## Release Gate Still Required

This package switch is compile and wiring work. It is not a production claim by
itself. Before merging a full Osaurus runtime switch, run the live gate against
local models and record artifacts for:

- multi-turn text coherence and no looping;
- reasoning on/off and effort handling per family;
- tool parsing per family with tool result follow-up;
- `generation_config.json` sampling defaults without hidden guard floors;
- prefix cache, paged cache, block L2, TurboQuant KV, and SSM companion cache;
- cache-on/cache-off inverses;
- VL image/video turns with text-only resume;
- Nemotron Omni live voice input / Parakeet encoder path;
- Qwen MTP bundles with `vmlx_mtp_tuning.json`, including MTP on/off speed and
  coherence comparisons; and
- API surfaces used by Osaurus and OpenAI-compatible clients.

Any incoherent output, repeated EOS loop, missing reasoning close, or cache hit
with the wrong architecture state is a runtime bug to root-cause in `vmlx-swift`.
Do not compensate in Osaurus by forcing temperature, top-p, top-k, repetition
penalty, close tokens, or parser repairs.
