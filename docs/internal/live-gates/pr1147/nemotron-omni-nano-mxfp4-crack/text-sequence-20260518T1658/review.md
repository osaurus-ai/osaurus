# Nemotron Omni Nano MXFP4 Text Live Sequence

Status: **TEXT ROW PASS / FAMILY PARTIAL**

Artifact folder:
`docs/internal/live-gates/pr1147/nemotron-omni-nano-mxfp4-crack/text-sequence-20260518T1658/`

The app was launched through the keychain-safe LaunchServices helper. For this
run only, `~/.osaurus/config/server.json` temporarily set
`modelIdleResidencyPolicy` to `after_seconds: 300` so loaded-model cache stats
would remain visible after the sequence. The prior immediate-unload config must
be restored after this row.

The request bodies intentionally omit sampler overrides. They set only
`model`, `stream=false`, `max_tokens` / `max_output_tokens`, and three text-only
turns through Chat Completions and Responses. This row must not be treated as
audio, video, image, Parakeet, or RADIO proof.

## Results

- Chat T1 math: HTTP 200, `2+2 equals 4.`, `finish_reason=stop`.
- Responses T1 math: HTTP 200, `2+2 equals 4.`, `status=completed`.
- Chat T2 follow-up: HTTP 200, `2+2 equals 4.`, `finish_reason=stop`.
- Responses T2 follow-up: HTTP 200, `2+2 equals 4.`, `status=completed`.
- Chat T3 UTF: HTTP 200, exact `café 東京 🚀`, `finish_reason=stop`.
- Responses T3 UTF: HTTP 200, exact `café 東京 🚀`, `status=completed`.

No BOS/EOS loop, reasoning leak, or visible tool/parser marker was observed in
this text-only row.

## Cache / Health

The after-sequence `/admin/cache-stats` snapshot includes:

- `prefix_hits=5`
- `prefix_misses=7`
- `disk_l2_hits=5`
- `disk_l2_stores=12`
- `disk_l2_misses=7`
- `ssm_companion_hits=5`
- `ssm_companion_misses=0`
- `ssm_companion_rederives=0`
- `paged_hits=0`
- model cache topology: `is_hybrid=true`,
  `is_paged_incompatible=true`, block-L2 enabled with
  `max_size_bytes=10737418240`

The after-sequence health snapshot shows the model loaded and resident with
5-minute idle residency. The memory snapshot captured RSS only and includes the
already-running installed `/Applications/vMLX.app` processes, so it is
diagnostic context rather than a production physical-footprint gate.

## Consequence

This closes only the lower-cost text route smoke for the Nemotron Omni MXFP4
bundle. The Omni family remains partial until audio input through Parakeet,
image/video/RADIO paths, streaming, sleep/wake, tok/s, and Activity Monitor
physical-footprint rows are attached.
