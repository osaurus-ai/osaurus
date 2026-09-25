# Generation defaults correctness

## Contract

- Bundle output limit: first valid positive integral `max_new_tokens`, then `max_tokens`; never context size or `max_length`. JANG sampling defaults remain primary over generation_config per field.
- Local precedence remains explicit request/agent value, saved user Sampling Defaults, resolved bundle snapshot, engine fallback. Loaded runtime holders own their bundle defaults until reload; model metadata changes invalidate catalog defaults, and a read interrupted by invalidation retries before returning or caching its value.
- CoreModelService omission preserves native model/provider temperature. Callers explicitly requesting a temperature retain that choice. Auxiliary cache and residency intent are unchanged.
- `top_q` is unsupported, not an alias for `top_p` or `top_k`.

## Path audit

ChatEngine passes optional request sampler fields and distinguishes explicit max output caps. MLXBatchAdapter.effectiveGenerationSettings applies precedence; ModelRuntime loads defaults directly from the resolved directory and retains them in the holder, avoiding ambiguous catalog aliases. AgentSubagentRunner carries agent temperature and child output cap and leaves other sampler fields absent; ordinary remote providers receive the optional wire request rather than local bundle defaults. HTTP agent-run resolves explicit request over saved agent settings. Responses max_output_tokens and Anthropic max_tokens map into the chat request.

Metadata-only repair does not mutate an already-loaded holder's snapshot; unload/reload constructs a new one. Changing the defaults cache does not claim that all capability caches are generation-safe: LocalReasoningCapability background publication remains a separately tracked review item.

## Evidence and pending proof

17 exact-source parser boundary rows passed; deterministic defaults-cache invalidation probe passed and the missing-epoch negative control failed as expected. Permanent regressions cover parser aliases, malformed caps, reload/override precedence, omitted utility temperature and stale publication. These CPU probes do not establish live chat, spawned child, provider, restart, UI or full eval completion. The current qualified-source/test/runtime matrix is recorded in `/Users/eric/vmlx-private-evidence/raptor06-speed-2026-09-23/parallel-closeout-2026-09-25/generation/`.
