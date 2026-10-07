# Local JSON Schema output

Status: proposed source implementation, unmerged. Real local-model, streaming, multi-turn and cache proof is pending. This document describes the intended contract, not a release or readiness claim.

`json_schema` requests pass the supplied schema through the local MLX runtime to a genuine next-token grammar mask. The existing bundle/request sampler selects among grammar-allowed tokens. This feature adds no prompt instruction, closing-token bias, whitespace bias, repetition penalty or hidden sampler override.

## HTTP request examples

Use an installed local MLX model with a supported tokenizer and an actual non-reasoning output envelope. The examples intentionally omit sampler overrides. Replace the model identifier with your local model.

Chat Completions (`POST /v1/chat/completions`):

```json
{
  "model": "your-local-model",
  "messages": [{"role": "user", "content": "Describe the current task in one sentence."}],
  "stream": false,
  "response_format": {
    "type": "json_schema",
    "json_schema": {
      "name": "task_summary",
      "strict": true,
      "schema": {
        "type": "object",
        "properties": {"answer": {"type": "string"}},
        "required": ["answer"],
        "additionalProperties": false
      }
    }
  }
}
```

Responses (`POST /v1/responses`):

```json
{
  "model": "your-local-model",
  "input": "Describe the current task in one sentence.",
  "stream": true,
  "text": {
    "format": {
      "type": "json_schema",
      "name": "task_summary",
      "strict": true,
      "schema": {
        "type": "object",
        "properties": {"answer": {"type": "string"}},
        "required": ["answer"],
        "additionalProperties": false
      }
    }
  }
}
```

The Responses format is converted into the same local schema request used by Chat Completions. `strict` does not enable extra unsupported keywords or silently rewrite omitted schema fields. The schema itself defines which properties are required and whether extra properties are allowed.

If the model normally opens a reasoning envelope, the caller must explicitly select its supported native non-reasoning mode. For example, `enable_thinking:false` is appropriate only for models whose own template supports that control; it is not a universal model switch. The runtime checks the prepared prompt and rejects active reasoning envelopes rather than silently changing model behavior. Reasoning-plus-schema, tool-call envelopes, remote-agent/agentic execution and nonlocal provider routes are not qualified by this feature and are rejected. Block-diffusion generation is unsupported.

## Supported schema subset

The engine validates this bounded subset before compiling a grammar:

- Primitive `type`, or a nonempty distinct array of primitive type names; `true` and empty schemas.
- Object `properties`, `required`, and boolean/schema `additionalProperties`. Required names must be declared properties; nonempty named `properties` require explicit `additionalProperties:false`. Object constraints require an explicit object type.
- Array schema `items`, `minItems`, `maxItems`; bounds are integers from 0 through 1024. Array constraints require an explicit array type.
- `enum` or `const`, optionally with a consistent type, without other constraint siblings. Enums contain 1 through 1024 values.
- `anyOf`, with 1 through 128 branches and no other constraint siblings.
- `$defs`/`definitions` and acyclic local `$ref` using simple `#/...` schema paths, without constraint siblings. External, escaped/percent-encoded, cyclic, missing and annotation/data-target references are rejected.
- Annotation fields `title`, `description`, `$comment`, `default`, `examples`. They do not constrain generation or inject prompts.

Generic objects without named properties retain the permissive default when `additionalProperties` is omitted. Explicit `$schema` dialect declarations are rejected pending dialect qualification. Nonempty named-property schemas with omitted, true or schema-valued `additionalProperties` are rejected. The pinned donor can otherwise admit a repeated named key through its additional-property rule with the wrong value type; a CPU matcher reproduction confirmed this bypass. The runtime does not silently close such schemas.

Unsupported features include `oneOf`, `allOf`, `not`, conditionals, dependencies, numeric bounds/`multipleOf`, `uniqueItems`, `contains`, `pattern`, `format`, `minLength`, `maxLength` and unknown keywords. `false` schemas are rejected. Limits are 1 MiB schema input, depth 64 and 10,000 visited nodes; reference depth is also bounded.

Unsupported syntax produces an explicit typed engine error, mapped to request rejection where validation occurs before generation. Unsupported features are not silently ignored. String-length constraints are excluded because the pinned compiler's length-constrained branch does not fully implement JSON escaped-character semantics.

The bundle tokenizer adapter currently requires BPE with a plain ByteLevel decoder, empty continuation/end-of-word suffixes and explicitly disabled tokenization-space cleanup. Added-token bytes, non-stop special IDs and vocabulary gaps are handled explicitly. Other decoder families or ambiguous metadata are rejected; individual decoded tokens are not used to guess vocabulary bytes.

## Completion, streaming and cache contract

Schema requests use request-local autoregressive decoding. MTP/speculative decoding is disabled only for that request; ordinary requests and global settings retain their behavior. Full-precision SSD/prefix cache state remains model state. Every schema request creates an independent matcher, including cache-hit requests and requests changing their schema. Matcher state is not restored from a cached prompt.

Streaming deltas are provisional fragments, not complete validated objects. Success requires natural completion with a grammar-authorized stop token. Length exhaustion, cancellation, mask failure and incomplete output are not schema success. A failure after headers or partial deltas must remain a terminal stream failure; consumers must not concatenate partial text and label it a successful structured result. Nonstreaming failures must also be returned as errors rather than successful partial JSON. Cancellation may close the transport before an error can be delivered.

Literal reasoning/tool-marker text inside JSON string values must remain literal data, not be stripped by ordinary text parsers. Grammar EOS controls completion. Explicit stop-string behavior must follow the engine's schema request admission contract; do not use a JSON substring as a substitute for completed grammar state.

Existing `json_object` remains the previous behavior; this change does not upgrade it to schema enforcement. Use `json_schema` for the new constrained-decoding contract.

## Architect integration seam

An Architect `generate` or `decide` node can supply its output schema through either HTTP format above or the local `GenerationParameters.jsonSchema` field. The adapter forwards it to engine `GenerateParameters.jsonSchema`; the existing runtime owns token masking, sampling, completion and cache state. The node consumes only a successfully completed result.

This is the inference integration point. It does not implement a workflow graph, input-validator nodes, cloud-provider nodes, tool execution, planning or an agentic framework. Validation of arbitrary incoming workflow data is separate from constraining generated output.

## Provenance and remaining proof

The engine imports the grammar bridge from upstream `mlx-swift-lm` commit `22157fc397b59acfb03e91c370bcbf2cfb10970e`, embedding XGrammar v0.1.30 (`d476a48dcd8fa3b5afeddbe850e73bb3b1dcf505`) with retained licenses and documented compatibility changes. It does not import the upstream guided loop, completion reserve or output-bias helpers.

Engine CPU/source checks and app DTO/error tests are distinct from live proof. Before a release/readiness claim, record actual model output, natural completion, tokens/s, stream/nonstream errors, multi-turn changed-schema behavior, cache-hit/SSD evidence and ordinary unconstrained chat/tool regressions. Those live gates remain pending in this document until updated with receipts.

## Deterministic JSON formatting

Schema grammar compilation uses deterministic structural formatting: no indentation and explicit comma/colon separators, with `any_whitespace=false`. This removes unbounded structural whitespace choices that can otherwise consume the token budget. String spaces, escaped newlines/tabs, Unicode, enum/const values and property names retain their data semantics. This is a serialization grammar policy, not a whitespace logit bias or forced EOS. Generic unconstrained collection rules in the pinned donor retain a fixed comma-space separator; that bounded formatting does not introduce a whitespace loop. Natural grammar-authorized completion is still required; formatting alone is not a successful-generation proof.
