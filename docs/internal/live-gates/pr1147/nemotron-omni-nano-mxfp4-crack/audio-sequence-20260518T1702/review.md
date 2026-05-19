# Nemotron Omni Nano MXFP4 Audio Live Sequence

Status: **AUDIO SMOKE PASS / FAMILY PARTIAL**

Artifact folder:
`docs/internal/live-gates/pr1147/nemotron-omni-nano-mxfp4-crack/audio-sequence-20260518T1702/`

Fixture:
`parakeet_probe.wav` is a local 16 kHz mono PCM WAV generated from:
`hello osaurus, the test word is blue`.

The app was launched through the keychain-safe LaunchServices helper. For this
run only, `~/.osaurus/config/server.json` temporarily set
`modelIdleResidencyPolicy` to `after_seconds: 300`; the prior immediate-unload
config was restored afterward, the debug app was quit, and port `4242` was
closed.

The request bodies intentionally omit sampler overrides. This row uses Chat
Completions only; the current probe helper does not fabricate a Responses audio
schema.

## Results

- Text warmup: HTTP 200, output `Ready`, `finish_reason=stop`.
- Audio turn: HTTP 200, output `Hello Asaurus the test word is blue.`,
  `finish_reason=stop`.

The audio turn preserved the important probe word `blue` and produced a
plausible transcription of the generated speech. It heard `osaurus` as
`Asaurus`, so this is a smoke test for live audio routing rather than a
word-perfect ASR benchmark.

No BOS/EOS loop, reasoning leak, or visible tool/parser marker was observed in
this short audio row.

## Cache / Health

The after-sequence `/admin/cache-stats` snapshot includes:

- `prefix_hits=0`
- `prefix_misses=6`
- `disk_l2_hits=0`
- `disk_l2_stores=4`
- `disk_l2_misses=6`
- `ssm_companion_hits=0`
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

This proves the PR app can pass an audio payload through the live Chat
Completions path into Nemotron Omni and get a coherent transcription-like
answer. The Omni family remains partial until streaming audio, repeated-audio
cache behavior, image/video/RADIO, sleep/wake, tok/s, and Activity Monitor
physical-footprint rows are attached.
