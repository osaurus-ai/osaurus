# SSD L2 new-chat partial-restore gate — 2026-07-21

## Status

`VERIFIED-LIVE — EMERGENCY N-1 FIX; BROADER CACHE MATRIX PARTIAL`

This gate covers the report that a model becomes responsive in one chat but a
new chat appears to prefill from zero while paged RAM cache is Off and Disk L2
is On. Aggregate counters are supporting evidence only. A row is credited only
when a request trace identifies the tier, matched boundary, remaining suffix,
companion-state behavior, TTFT, token/s, and a coherent visible answer.

## Root cause and scoped change

Qwen 3.5-family templates such as Bonsai and Ornith can require a user message
before they render. vMLX derives their stable system/tool prefix by intersecting
two divergent synthetic user renders with the real request; synthetic content
is never sent to the model or admitted to the stored stable prefix.

Path-dependent hybrid restores deliberately reject an exact disk boundary.
The GDN/Mamba/CCA state must be restored at N-1 and the final token re-fed.
The previous stable-prefix writer stored N, so the first brand-new chat missed,
did a cold prefill, and only then created a usable shorter snapshot for later
chats. vMLX `feb35555900398dc638c82a3e13e98f8b1adbf41` stores the
processor-proven stable checkpoint at N-1 for disk-backed hybrid topologies and
keeps that safe seed in the preferred lookup set even after the bounded disk
index contains more than 128 larger historical entries.

Dense/full-KV and rotating-SWA topologies retain their existing boundary
policy. ZAYA CCA remains explicit: its typed v2 payload owns CCA state and does
not require a separate recurrent sidecar.

Osaurus also labels runtime cache lookup/restore stages separately from actual
transformer prefill. An initial cache lookup event is no longer displayed as a
cold `Prefill 0/N`.

## Source/test evidence

- vMLX PR #173, head `feb35555`.
- `HybridStripBoundaryPrefillTests`: 8/8, including first-new-chat N-1 restore.
- canonical/coordinator matrix: 19/19.
- topology and growing-chat source suites: 59/59.
- updated BatchEngine growing-chat source suite: 17/17.
- Osaurus consumes the same revision in all four package-pin surfaces.

These checks are not live app proof.

## Current `feb35555` Release-app proof

The freshly built app at
`/private/tmp/osaurus-ssd-warm-prefill-release-derived-20260721/Build/Products/Release/osaurus.app`
was ad-hoc signed as `com.dinoki.osaurus.ssdwarmfeb355proof20260721`.
Its executable SHA-256 was
`488b2ce7106cb8e85bb3f27e69d4db7941abb6f977bc3174e09131169d22a3ea`,
and the resolved vMLX checkout was exactly
`feb35555900398dc638c82a3e13e98f8b1adbf41`.

Computer Use visibly confirmed Prefix On, GPU/paged cache Off, Disk Cache On,
codec `Engine Selected`, SSM re-derive On, and Thinking Off. Disk Cache was
turned Off and saved for the negative control, then restored On and saved
before the Gemma/Bonsai rows.

| Model / scenario | Cache trace | Visible UI result |
| --- | --- | --- |
| Qwen AgentWorld 35B A3B MXFP8, first new chat | disk boundary 2,992; one token remaining; 60 recurrent states | warm-up first delta 0.36 s; `Au`, TTFT 0.51 s, 49.0 tok/s |
| Same Qwen bundle after quit/relaunch | disk boundary 2,992; one token remaining; 60 recurrent states | warm-up first delta 0.21 s; `Au`, TTFT 0.49 s, 47.8 tok/s |
| Same Qwen request, Disk Cache Off | `MISS all tiers`; true UI prefill visibly reached `1024/3010` | `Au`, TTFT 1.89 s, 47.9 tok/s |
| Gemma 4 12B QAT JANG_4M, later new chat | disk boundary 1,629; four tokens remaining; `ssm=-1` | warm-up 0.28 s; `Au`, TTFT 0.41 s, 35.3 tok/s |
| Bonsai 27B Ternary JANG, later new chat | disk boundary 2,922; one token remaining; 96 recurrent states | warm-up 0.20 s; prior `Au`, TTFT 0.50 s, 30.7 tok/s |

The emergency first-new-chat/restart defect is verified on current source.
Intervening quota pressure, paged-hot-to-SSD fallback, TurboQuant opt-in,
media salts, and the remaining model-family matrix stay explicitly partial.

## Prior live diagnostic evidence

An isolated Release app at the earlier `c21cf7b0` pin was operated through the
UI with Bonsai Ternary JANG, Thinking Off, Prefix On, paged RAM Off, Disk L2 On,
and TurboQuant not enabled. A disk hit restored boundary 3,808 with seven
tokens remaining and produced `Au` at TTFT 0.37 s and 30.6 tok/s. Turning Disk
L2 Off in Settings and saving caused the same prompt to miss all tiers and take
TTFT 5.23 s at 30.3 tok/s. This proves SSD-only restore materially affects
latency, but it does not prove the new N-1 first-new-chat change.

## Current-source acceptance matrix

The original acceptance checklist now stands as follows:

1. **PASS:** settings visibly saved with Prefix On, paged RAM Off, Disk L2 On,
   default non-forced codec, and SSM re-derive On.
2. **PASS:** Qwen 3.5 MXFP8 cold store, first-new-chat N-1 restore, coherent
   answer, and quit/relaunch persistence.
3. **PARTIAL:** Gemma 4 QAT JANG_4M rotating-SWA/full-attention restore is
   proven across a new chat without false SSM/TurboQuant claims; its separate
   app-restart row remains open.
4. **PASS:** Bonsai Ternary JANG disk-only partial hit, coherent answer, TTFT,
   token/s, and recurrent companion restore.
5. **PASS:** Disk L2 Off produced request-local misses and slower true prefill;
   Disk L2 was restored On and saved afterward.
6. **PARTIAL:** the miss visibly showed runtime `Prefill 1024/3010`, and source
   tests distinguish `Checking cache` and `Restored`; the sub-second hit stages
   were too brief to capture as separate live frames.
7. **PARTIAL:** quit/relaunch persistence is proven for Qwen; broader
   intervening-pressure and non-adjacent eviction rows remain open.
8. **PARTIAL:** earlier diagnostic telemetry showed quota eviction, but this
   current Release run did not force a fresh quota eviction.

For every model row capture the full visible response, TTFT, token/s, matched
and total tokens, suffix size, disk hit/miss/store deltas, effective cache
topology, and companion restore/re-derive counters. Any stale text, reasoning
drift, loop, protocol marker leak, hidden-only answer, or length-cap stop fails
the row even if the cache counter increments.

TurboQuant-KV On is a separate opt-in matrix. JANGTQ weights are not
TurboQuant KV encoding. This emergency merge keeps the default policy unchanged
and does not claim TurboQuant coverage.
