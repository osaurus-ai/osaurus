# Native-MTP allocator reuse ceiling evidence (2026-08-30)

## Status

`PASS` for the Qwen3.8 Flash-Next native-MTP regression that motivated this
policy. The direct one-request A/B proved that allocator reuse was the missing
speed input, while the first exact integrated Release app falsified the
original unbounded policy: physical footprint grew from about 51 GiB after the
sustained served row to 91 GiB after several Chat/tool iterations. The final
policy bounds active reuse by model weight size and physical RAM, drains freed
buffers at the final producer fence, and restores the user-visible persistent
cap between requests.

## Causal A/B

Both rows used the local
`JANGQ-AI/Qwen3.8-Flash-Next-JANG_2L` bundle, native MTP D3, greedy decoding,
the production 70% load budget, finite 65,536-token KV window, disk L2, and SSM
companion caching. The only changed value was MLX's persistent freed-buffer
reuse ceiling after load.

| Persistent reuse ceiling | Decode | Peak physical footprint | MTP result |
| --- | ---: | ---: | --- |
| 128 MiB | 51.5 tok/s | 50,017 MiB | D3, 173/173 D3 accepts, zero AR fallback |
| admitted 70% ceiling | 66.1 tok/s | 51,417 MiB | D3, 173/173 D3 accepts, zero AR fallback |

The admitted-ceiling row was 28% faster while its one-request peak physical
footprint was only 1,400 MiB higher. That result proves decode-time reuse, not
safe long-lived retention; the integrated 91 GiB reproduction above is why the
ceiling is now request-scoped. Both rows recorded disk-L2 and SSM companion hits. The
Flash-Next PLE reader remained SSD-backed through `pread` with `F_NOCACHE`.
Both full outputs were byte-identical with SHA-256
`d4bcb44843ae465851740a4d3aaa34d91d1012271de0f7f0ceb87a980910c655`.
The Release `RunBench` binary SHA-256 was
`6d54ee3fac9c0066a0893118d1e9c1a435b6000b1f4986f7d4a23a6422f8f596`
at vMLX head `fe95824d84e34e38090a3df5610aaa3850ec2902`.

Raw logs:

```text
/Users/eric/vmlx-private-evidence/qwen38-auto-d3-20260830/2L-pr368-final-persistent128m-count200-spaces.log
/Users/eric/vmlx-private-evidence/qwen38-auto-d3-20260830/2L-pr368-final-persistent-admitted-count200-spaces.log
```

## Source contract

The runtime decision is based on the resolved decode path, not a bundle or
model-name allowlist:

- ordinary autoregressive models keep the configured Safe Auto allocator cap;
- resolved native MTP uses a request-scoped ceiling bounded by one third of
  resident weight bytes and one eighth of physical RAM (with a 16 GiB cap),
  never above the already-admitted memory limit;
- plain affine DeepSeek-V4 uses the same bounded request-scoped ceiling;
- the final request fence clears freed MLX buffers and restores Safe Auto's
  persistent 128 MiB cap without touching weights, KV, disk-L2, or SSM state;
- no resident model still resolves the cache limit to zero.

## Exact integrated Release proof

The final bounded policy was integrated with vMLX
`e025cd77c4adf7f1813d157ea0fbb6514f4e86f4` at Osaurus source head
`221e4388bad325b4fd6491a48f649e4fa7900f00`. The no-sign Release executable
SHA-256 was
`9110b16eecc1c56812ad7d406441ad9c816732c4c63c548fc7b2197db82e6de1`.
Exactly one isolated proof app ran as PID 83832 with model ID
`qwen3.8-flash-next-jang_2l`.

The cold served count-to-200 row completed all 691 tokens at 65.2346 tok/s,
with normal `stop` and the exact output SHA-256
`d4bcb44843ae465851740a4d3aaa34d91d1012271de0f7f0ceb87a980910c655`.
Runtime telemetry reported native MTP D3, active depth 3, 173 verifier calls,
173 accepted D3 groups, 173 bonus tokens, zero rejected drafts, and zero AR
fallback tokens. Three subsequent warm rows produced the same exact output at
68.5602, 68.2243, and 67.2418 tok/s.

After all four requests, disk L2 reported 3 hits / 4 misses / 9 stores and the
SSM companion reported 3 hits / 0 misses / 0 re-derives. Paged RAM KV remained
disabled. The fresh process measured 52,801,721,024 bytes current physical
footprint and 55,193,392,144 bytes lifetime peak, versus the falsifying old
unbounded-policy peak of 97,691,704,256 bytes. The peak did not grow across the
three warm repetitions.

Computer Use opened the exact app and visibly inspected the persisted API chat:
the rendered assistant answer ended at `197 198 199 200`, with no terminal
spinner, protocol marker, or truncated suffix. An earlier integrated app using
the same vMLX and request-scoped lifecycle (before only the final bound formula
changed) also completed one approved `get_current_time` call, its tool-result
continuation, and a coherent follow-up turn. HTTP evidence is used here for the
served-MTP contract; the rendered app inspection is the user-facing check.

## Rejected QSA repin

The later experimental vMLX pin
`ca0195ba0f62f36a1d87c67258a59189f43e3e4a` is deliberately excluded from
this release lane. In the same isolated Release app, cache-disabled back-to-back
count-to-200 requests both used native MTP D3, accepted 173/173 draft groups,
and produced the exact 691-token output, but decode fell from 68.5819 tok/s to
27.9504 tok/s. Target-verifier time grew from 7.428 seconds to 22.039 seconds.
Enabling disk L2 and prefix restore did not remove the regression. The QSA
prefill work must recover sustained decode independently before it can replace
the proven pin.

A fresh build after restoring the proven `e025cd77` pin still measured
68.6783 tok/s followed immediately by 22.8996 tok/s; verifier time grew from
7.404 seconds to 27.296 seconds while D3 acceptance remained 173/173 with zero
AR fallback. Therefore the historical four-row table is not accepted as a
current back-to-back sustained-decode gate. This PR fixes default D3 activation
and terminal-drain ownership; sustained thermal/power-state decode remains a
separate blocked performance gate and is not claimed fixed here.
