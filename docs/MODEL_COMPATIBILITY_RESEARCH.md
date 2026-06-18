# Model Compatibility Research

This note covers the research-first lane for local model compatibility
requests:

- [#443](https://github.com/osaurus-ai/osaurus/issues/443) - Hugging Face
  cache import
- [#358](https://github.com/osaurus-ai/osaurus/issues/358) - Hunyuan
  `hunyuan_v1_dense`
- [#1065](https://github.com/osaurus-ai/osaurus/issues/1065) - DFlash
  speculative decoding
- [#886](https://github.com/osaurus-ai/osaurus/issues/886) - LongCat
  families
- [#833](https://github.com/osaurus-ai/osaurus/issues/833) - tensor
  parallelism

The current deliverable is host-side discovery and diagnostics only. Runtime
family enablement still belongs in vmlx-backed PRs with live proof; Osaurus
surfaces unsupported or unproven states instead of coercing model configs.

## Current Boundary

Osaurus owns model discovery, download state, user-visible catalog entries,
storage paths, model residency policy, request mapping, and health reporting.
The local generation path delegates model loading, family factories,
architecture-specific cache geometry, tool-call parsing, reasoning parsing,
and same-model batching to `vmlx-swift` through `BatchEngine`. That means a
new architecture should not be papered over in the host app by renaming
`model_type`, forcing a prompt template, or bypassing the upstream factory
registry. Host changes should make unsupported states legible, route verified
local artifacts into the existing storage model, and add no-load policy tests
that prove the right boundary is being crossed.

Current source map:

- `ModelManager`, `HuggingFaceService`, and `ExternalModelLocator` discover
  Hugging Face repos, local Osaurus model folders, Hugging Face cache
  snapshots, and LM Studio-style external bundles.
- `MLXModel.isDownloaded` accepts a directory with `config.json`, tokenizer
  assets, and at least one `*.safetensors` file.
- `ModelCompatibilityDiagnostics` reports local source, bundle completeness,
  unsupported Hunyuan/LongCat families, benchmark proof status, and future
  DFlash/tensor-parallel hooks without attempting a model load.
- `ModelRuntime` loads the selected directory into a vmlx `ModelContainer`
  and submits through `MLXBatchAdapter`.
- `docs/INFERENCE_RUNTIME.md` documents that vmlx owns KV topology,
  reasoning/tool parsing, and model factory support.

## Compatibility Matrix

| Request | Current status | First shippable step | Runtime boundary |
| --- | --- | --- | --- |
| Hugging Face local cache (#443) | Read-only HF cache and LM Studio discovery are implemented for verified MLX safetensors bundles; skipped candidates now have Models > On Device and Settings diagnostics. | Add optional manifest/digest verification before load if mutation protection is required. | Host-only discovery/storage work; no vmlx change if the snapshot already loads as MLX. |
| Hunyuan `hunyuan_v1_dense` (#358) | `mlx-community/HY-MT1.5-7B-bf16` advertises `model_type: hunyuan_v1_dense`; Osaurus now reports it as unsupported until vmlx has a native factory. | Enable catalog/runtime only after vmlx support and live validation land. | vmlx must own config mapping, weights, tokenizer/template behavior, and generation tests. |
| DFlash speculative decoding (#1065) | Osaurus has one target model per local generation request and no draft-model contract. | Design a feature-flagged draft/target request shape plus benchmark evidence requirements. | vmlx or a dedicated MLX adapter must own the speculative loop and acceptance verification. |
| LongCat Flash/Next (#886) | LongCat repos use custom code and new LongCat config shapes; LongCat-Next is a 74B any-to-any model that documents at least three 80GB GPUs for Transformers usage. Osaurus now reports LongCat local bundles as unsupported. | Keep local catalog entries hidden or blocked until native support and multimodal proof exist. | Native LongCat model classes, multimodal processors, lazy decoder paths, and cache geometry belong upstream. |
| Tensor parallelism (#833) | Osaurus runs one local MLX process and one local `BatchEngine` per resident model. | Produce a cluster design behind explicit auth and network policy; do not auto-discover or auto-join peers. | Distributed execution belongs in vmlx/external cluster runtime; host owns identity, policy, and UI only. |

## Hugging Face Cache Import

Hugging Face Hub uses a shared cache rooted at
`~/.cache/huggingface/hub` by default, with environment overrides through
`HF_HOME` or `HF_HUB_CACHE`. Model repositories appear as
`models--<org>--<repo>` folders containing `refs`, `blobs`, and
`snapshots`; snapshot entries are symlinks into content-addressed blobs.

Implementation shape:

1. Add a cache root setting with this precedence: explicit Osaurus setting,
   `HF_HUB_CACHE`, `HF_HOME/hub`, then `~/.cache/huggingface/hub`.
2. Scan only `models--*` folders and resolve `refs/main` to a concrete
   snapshot revision. Do not treat `refs` as model directories.
3. Register a snapshot only if it satisfies the same minimum shape as
   `MLXModel.isDownloaded`: `config.json`, tokenizer assets, and
   `*.safetensors`.
4. Store an Osaurus-local manifest keyed by repo id, revision, source, and the
   absolute snapshot path so imported models reappear on launch before a
   background rescan finishes.
5. Before `ModelRuntime` loads a cache-backed model, resolve the external path
   through `ExternalModelLocator` and keep the files in place. Full file digest
   verification is a future hardening step, not part of the current import
   contract.
6. Never mutate the HF cache from Osaurus. Delete/uninstall controls should
   clearly say "remove from Osaurus catalog" unless the implementation later
   adds an explicit cache-management mode.

Security notes:

- Follow symlinks only when the resolved target stays under the selected HF
  cache root. Reject absolute symlinks outside the root and any path
  containing `..` after standardization.
- The local SHA-256 manifest proves the artifact did not change between scan
  and load. It does not prove upstream provenance; the UI should label these
  as user-provided cache entries unless a future API-backed download manifest
  verifies Hub metadata.
- Do not copy cache files into `~/MLXModels` by default. Copying doubles disk
  usage and breaks the content-addressed cache benefit that users requested.

Tests when this implementation lands:

- Unit-test cache path precedence.
- Unit-test `models--org--repo` to `org/repo` parsing.
- Unit-test snapshot validation for tokenizer variants already accepted by
  `MLXModel.isDownloaded`.
- Unit-test symlink escape rejection and manifest mismatch rejection.

## Hunyuan Dense

Issue #358 points at HY-MT1.5 MLX variants whose configs use
`model_type: hunyuan_v1_dense`. The model card for
`mlx-community/HY-MT1.5-7B-bf16` also shows the `HunYuanDenseV1ForCausalLM`
architecture and a 262K max-position setting. This should be treated as a new
architecture family, not an alias for an existing dense Llama/Qwen family.

Implementation sequence:

1. Add a host-side unsupported-family diagnostic so users see:
   `Unsupported local model type: hunyuan_v1_dense. Osaurus needs vmlx Hunyuan
   Dense support before this model can run locally.`
2. Add no-load tests that feed a minimal Hunyuan config into detection code and
   assert the diagnostic, without trying to instantiate MLX.
3. Add or consume vmlx support for Hunyuan Dense config, attention, tokenizer
   template behavior, RoPE scaling, and generation defaults.
4. Only after real-model validation, allow curated or direct-import catalog
   entries to present as runnable.

Do not implement this by rewriting `model_type` in Osaurus. That would route
unknown weights through a wrong factory and risk shape traps or silent quality
loss.

## DFlash Speculative Decoding

DFlash is a draft-model speculative-decoding method. It is not just another
model family: it needs a target model, a compatible draft model, an acceptance
verifier, and benchmark evidence that the implementation remains lossless for
the sampled distribution.

Implementation sequence:

1. Add a disabled-by-default request shape in design first:
   `targetModelId`, `draftModelId`, `draftRevision`, `maxDraftTokens`,
   and `acceptanceMode`.
2. Require both target and draft artifacts to pass the same digest policy as
   normal local models before either can load.
3. Keep the speculative loop in vmlx or a dedicated MLX adapter so acceptance
   and rollback happen close to the token sampler and KV cache.
4. Expose only diagnostics in Osaurus at first: accepted tokens, rejected
   tokens, target forward passes, draft forward passes, TTFT, and steady-state
   tokens/sec.
5. Gate UI and API access behind a runtime feature flag until at least one
   target/draft pair passes the runtime validation standard.

Tests when this implementation lands:

- No-load request validation for missing draft, same draft/target id, and
  unsupported acceptance mode.
- Runtime benchmark artifact for one approved pair, with speculative mode off
  and on, using the same prompt set.
- Cancellation and unload tests proving both target and draft leases release.

## LongCat Families

LongCat-Flash-Omni and LongCat-Next are not simple text-only MLX imports.
The public model pages use custom-code mappings, new LongCat architectures,
any-to-any modality tags, and large hardware requirements. LongCat-Next's
model card documents at least three 80GB GPUs for Transformers usage and uses
lazy decoder paths. The `config.json` for LongCat-Next sets
`model_type: longcat_next`; LongCat-Flash-Omni exposes custom LongCat Flash
classes and multimodal routing.

Implementation sequence:

1. Add unsupported-family diagnostics for `longcat_next` and LongCat Flash
   custom-code configs.
2. Keep local LongCat catalog entries hidden or marked unsupported until vmlx
   has native support. Do not tell users a single Mac can run these locally
   unless real validation proves it.
3. Treat remote/API usage as a provider-compatibility topic, not a local MLX
   runtime topic.
4. If vmlx support lands, require model-family tests for text, image, audio,
   video, cache behavior, and memory pressure before enabling in the picker.

## Tensor Parallelism

Tensor parallelism is a cluster/runtime feature, not a model picker tweak.
External projects such as exo and distributed-llama show viable directions for
splitting inference across devices, but Osaurus's current local runtime is
single-process and single-host. Adding transparent peer discovery would cross
the identity, networking, and model-integrity boundaries at the same time.

Implementation sequence:

1. Design a separate authenticated cluster runtime before any code lands.
2. Require explicit user opt-in to join or host a cluster. No background LAN
   auto-join, no implicit model sharing, and no plugin-controlled cluster
   mutation.
3. Reuse the global proxy/network policy where applicable, but do not route
   privileged local model paths through arbitrary peers.
4. Verify every shard artifact by digest on the host that loads it.
5. Keep the local `BatchEngine` path unchanged until vmlx or a reviewed
   adapter provides a distributed execution API.

Security checks for the later implementation:

- Pair peers with signed credentials or local key material, not caller-supplied
  headers.
- Redact model paths, cache paths, tokens, and hostnames in logs.
- Reject file URLs, loopback pivot URLs, and unauthenticated peer commands.
- Require a clear rollback: disabling cluster mode returns all requests to the
  single-host local runtime.

## Implementation Order

1. Optional manifest/digest verification for external cache entries, if the
   project wants stronger mutation detection before load.
2. Hunyuan vmlx support, if upstream scope is accepted and real-model evidence
   is available.
3. DFlash API boundary and benchmark harness, still feature-flagged.
4. Tensor-parallel cluster design after model artifact integrity and network
   identity are reviewed together.

## Validation Standard

Runtime-family work that follows this design should use
[`RUNTIME_VALIDATION_STANDARD.md`](./RUNTIME_VALIDATION_STANDARD.md). A source
test can prove routing and policy, but it cannot prove model quality, cache
correctness, speed, or memory safety. Any future PR that enables a new runnable
family must include real-model evidence with the Osaurus SHA, vmlx SHA, model
revision, prompt set, cache tier, timing, memory, and verdict.
