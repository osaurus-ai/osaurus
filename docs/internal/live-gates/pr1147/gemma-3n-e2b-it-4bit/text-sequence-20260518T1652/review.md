# Gemma3n E2B 4bit Text Live Sequence

Status: **PARTIAL / red output behavior**

Artifact folder:
`docs/internal/live-gates/pr1147/gemma-3n-e2b-it-4bit/text-sequence-20260518T1652/`

The app was launched through the keychain-safe LaunchServices helper. For this
run only, `~/.osaurus/config/server.json` temporarily set
`modelIdleResidencyPolicy` to `after_seconds: 300` so loaded-model cache stats
would still be resident after the sequence. The prior immediate-unload config
was restored afterward, the debug app was quit, and port `4242` was closed.

The request bodies intentionally omit sampler overrides. They set only
`model`, `stream=false`, `max_tokens` / `max_output_tokens`, and the chat or
Responses message history. This row must not be repaired with hidden
temperature, top-k, repetition, EOS, or prompt guard behavior.

## Results

- Chat T1 math returned HTTP 200 and a coherent answer containing `4`, but it
  ignored the exact-output instruction and emitted a long explanation.
- Responses T1 math returned HTTP 200 and a coherent answer containing `4`,
  but also ignored the exact-output instruction.
- Chat T2 follow-up remembered `four`, but entered an odd word-puzzle framing
  and produced a long, low-value explanation instead of the requested one short
  sentence.
- Responses T2 follow-up produced the clearest answer:
  `4, because 2 + 2 = 4.`
- Chat T3 UTF included the exact `café 東京 🚀` string, but wrapped it in a
  verbose false "decode" explanation.
- Responses T3 UTF dropped `東京` and returned `café 🚀` inside a verbose
  explanation.

No BOS/EOS repetition loop was observed in this short row, but the row is not
production-clear. It shows instruction-following drift and UTF loss on the
Responses path under the live Osaurus request adapter.

## Cache / Health

The after-sequence `/admin/cache-stats` snapshot includes:

- `prefix_hits=5`
- `prefix_misses=14`
- `disk_l2_hits=5`
- `disk_l2_stores=9`
- `disk_l2_misses=14`
- `paged_hits=0`
- `paged_misses=0`
- `ssm_companion_hits=0`
- model cache topology: `is_hybrid=false`,
  `is_paged_incompatible=true`, block-L2 enabled with
  `max_size_bytes=10737418240`

The memory snapshot captured RSS only. It includes the PR debug Osaurus process
and the already-running installed `/Applications/vMLX.app` processes, so it is
diagnostic context rather than a production physical-footprint gate.

## Consequence

This artifact narrows the Gemma3n report to live request/template/decode
behavior rather than load failure or a missing cache route. The next fix should
root-cause the Gemma3n chat-template/request adapter and Responses UTF path
before changing any sampler or output-shaping policy.
