# ZAYA1 8B MXFP4 Text Live Sequence

Status: **PARTIAL / red UTF behavior**

Artifact folder:
`docs/internal/live-gates/pr1147/zaya1-8b-mxfp4/text-sequence-20260518T1705/`

The app was launched through the keychain-safe LaunchServices helper. For this
run only, `~/.osaurus/config/server.json` temporarily set
`modelIdleResidencyPolicy` to `after_seconds: 300`; the prior immediate-unload
config was restored afterward, the debug app was quit, and port `4242` was
closed.

The request bodies intentionally omit sampler overrides. They set only
`model`, `stream=false`, `max_tokens` / `max_output_tokens`, and three text-only
turns through Chat Completions and Responses. This row must not be repaired by
hidden temperature, top-k, repetition, EOS, prompt, or output-shaping guards.

## Results

- Chat T1 math: HTTP 200, `2+2 equals 4.`, `finish_reason=stop`.
- Responses T1 math: HTTP 200, `2+2 equals 4.`, `status=completed`.
- Chat T2 follow-up: HTTP 200, `2+2 is 4.`, `finish_reason=stop`.
- Responses T2 follow-up: HTTP 200, `2+2 is 4.`, `status=completed`.
- Chat T3 UTF: HTTP 200 and included `café 東京 🚀`, but added extra text.
- Responses T3 UTF: HTTP 200 but output wrong characters:
  `《咖蓝》》📅`; this fails the literal UTF row.

No BOS/EOS repetition loop was observed in this short row, but the UTF behavior
keeps the model family red/partial until the real request-template, tokenizer,
decode, or route-adapter cause is found.

## Cache / Health

The after-sequence `/admin/cache-stats` snapshot includes:

- `prefix_hits=5`
- `prefix_misses=6`
- `disk_l2_hits=5`
- `disk_l2_stores=12`
- `disk_l2_misses=6`
- `ssm_companion_hits=5`
- `ssm_companion_rederives=0`
- `paged_hits=0`
- model cache topology: `is_hybrid=true`,
  `is_paged_incompatible=true`, block-L2 enabled with
  `max_size_bytes=10737418240`

The memory snapshot captured RSS only and includes the already-running
installed `/Applications/vMLX.app` processes, so it is diagnostic context
rather than a production physical-footprint gate.

## Consequence

This artifact proves ZAYA1 8B MXFP4 can answer short math coherently through
both routes and can move prefix/block-L2/SSM companion counters. It does not
make ZAYA text production-clear because Responses corrupts the literal UTF row
and Chat does not obey exact-output constraints.
