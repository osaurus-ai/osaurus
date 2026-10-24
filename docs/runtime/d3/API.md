# D3 decision requests

D3, D3 Flash and D3 Turbo are decision backbones, not text generators. Install the complete bundle, including `decision/decision_config.json` and `decision/readout.safetensors`, and use the normal model settings to control API catalog visibility. Hidden models can still be requested explicitly, matching the existing server setting; authentication and memory admission still apply. Installed decision bundles have a D3 badge and are excluded from chat, agent and worker pickers.

Use the normal Osaurus API authentication with `POST /v1/systemone`:

```json
{
  "model": "OsaurusAI/d3-flash-JANG_4M",
  "state": "Write a Python function that reverses a string.",
  "questions": {
    "kind": {
      "type": "choice",
      "instructions": "What kind of work is this?",
      "criteria": {"code": "Writing code", "math": "Mathematics", "chat": "Anything else"}
    },
    "reasoning": {"type": "noul", "instructions": "Does this require multi-step reasoning?"},
    "difficulty": {"type": "score", "criteria": ["easy", "medium", "hard"]}
  },
  "images": [],
  "videos": []
}
```

`GET /v1/systemone/models` lists exposed installed decision bundles. Each answer has the question's type and its typed result. Invalid questions produce per-question error objects while other questions continue. Input option order is preserved. `usage.output_tokens` is zero; prompt throughput describes a forward pass, not generated tokens per second.

Images and videos accept base64 data URLs in their respective arrays, applying to every question. The endpoint never reads caller-supplied filesystem paths or fetches arbitrary URLs. Turbo additionally supports image questions such as `{"type":"box","instructions":"Find the red ball"}`, returning normalized top/bottom/left/right edges and confidence.

This first endpoint does not implement the vendor's asset-reference composition, video-at boxes or video tracking. Unsupported fields/types return errors instead of being ignored. StateOnce is also not implemented: each question executes a complete, cache-free forward. This changes performance relative to the vendor's StateOnce optimization, not the trained attention contract.

Decision requests use the existing compatibility/version checks, shard validation, memory safety plan, deletion protection, auxiliary-work residency policy and exclusive GPU gate. An unrelated API request cannot evict an existing chat model without ownership. Each request loads its own weights, answers its questions, then unloads and drains before releasing the gate. No autoregressive cache, SSD prompt checkpoint, sampler, reasoning effort or speculative decoding setting applies to these models. Normal chat models retain their existing runtime paths.
