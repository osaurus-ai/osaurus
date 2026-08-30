# Qwen3.8 native-MTP fallback telemetry proof (2026-08-30)

PR: `#2554`  
Code head tested: `98b6945d428e66771cabff4d538ca334d9356e8a`  
Pinned vMLX: `bf8b31995195fffd833968658f14c707317eaa70`  
Release executable SHA-256: `965c6d0566932983dcfb62a9868155ad217b615f6dbe41cab30bf85139dd139b`

## Source contract

`MLXBatchAdapter.nativeMTPFallbackReason` now reports a fallback only when
native MTP was requested but the effective draft strategy did not run. The
load-time rejection reason is carried into the same runtime telemetry surface.
This PR does not change MTP activation, sampler values, generated tokens,
templates, or model-family policy.

The pinned vMLX runtime intentionally rejects workload-scoped tuning for Auto.
`NativeMTPTuning.usableBestDepth` requires a workload-general `prompt_class`.
The installed Flash-Next JANG_2L bundle declares
`prose_greedy_200tok_seed42`, so the exact app correctly stayed autoregressive
and reported the tuning rejection instead of claiming MTP was active.

## Exact Release-app rows

The app was launched keychain-free from the exact PR-head Release build. One
Osaurus process was present during each capture. The UI, not the HTTP surface,
was driven and inspected.

| Bundle / setting | Effective result | UI/runtime result |
| --- | --- | --- |
| Qwen3.8-27B-JANG_2D / Auto | AR fallback | `MTP off — Bundle does not have usable vmlx_mtp_tuning.json production tuning`; coherent eclipse answer; normal stop; TTFT 4.38 s; 40.0 tok/s; disk L2 2/13/7; SSM 2/0/0. |
| Qwen3.8-27B-JANG_4D / Auto | native MTP active d2 | Live Activity showed `Native MTP 1 active d2` and no false sampling fallback. The long-form row later repeated and was cancelled at 16.0 tok/s, so this is classification proof, not a model-quality or performance pass. |
| Qwen3.8-Flash-Next-JANG_2L / Auto | AR fallback | Live Activity showed `MTP off — Bundle does not have usable vmlx_mtp_tuning.json production tuning`; bundle sampler 0.2/0.95/20; coherent 527-token tide answer; exact marker present; normal stop; TTFT 11.02 s; 30.0 tok/s; disk L2 7/72/19; SSM 7/0/0. |

The JANG_4D matched MTP-Off control also repeated and was cancelled (18.0
tok/s). Therefore that repetition is not attributed to MTP by this evidence.

## Archived UI evidence

Local evidence root: `/private/tmp/osaurus-pr2554-ui-live/evidence`

| File | SHA-256 |
| --- | --- |
| `qwen27-fallback-chat.jpeg` | `2fda9a4868594f2ae8716c19abc91d25e00bd096d86627370f2d185b39372fad` |
| `qwen27-fallback-live-activity.jpeg` | `bdbb86b9168f687d04961785c613413e9d3fe8f1c28d5fe14f7d668384105bf8` |
| `qwen27-auto-mtp-live-activity.jpeg` | `eb5ccc3b930e4378f10c49832d852a80988878f2672f3948a9b04dd78cd1fa35` |
| `qwen27-auto-mtp-loop.jpeg` | `e8e6ae405f38aabc7e0f6470454b80523cde1f3264621963e49c474ae8da37fb` |
| `qwen27-ar-control.jpeg` | `c7ca74090e15b995e439fdfede8f65e2d32d45eb63340d7804f04571f3970470` |
| `flash2l-auto-chat.jpeg` | `cbe4046118ecdd366d22659a8d42ae38e17d84901fb5d9637d609bafbb806a17` |
| `flash2l-auto-live-activity.jpeg` | `44122c274f72338ca46961b644d1c0a41270979c139d4f5ea5c72eb7616b505e` |

## Scope verdict

The telemetry contradiction fixed by `#2554` is proven in the exact app.
Native-MTP performance, representative-workload tuning, and the current
greedy-while-MTP sampler policy remain separate behavior work and are not
claimed fixed by this PR.
