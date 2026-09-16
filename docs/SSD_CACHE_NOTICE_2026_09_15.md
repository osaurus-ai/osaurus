# SSD quota notice and indexed clear

Isolated from the combined RAM/vision branch onto main `0b33e116e5f5c4f3d65e80f736eed3a89df604a9`.
Engine remains `5b0c8e6b8b29a7ead21fe785688bc0621580cc62`.

The composer polls active coordinator quota and eviction counters. A notice is
claimed once per directory/effective quota per app launch, only in an eligible
idle foreground chat. Poll identity includes the chat and presentation gate.
Main's existing RAM/swap notices retain priority. Clear targets the measured
root; Settings Clear covers active roots plus the saved root.

Deletion is serialized with runtime cache IO and SQLite writers. Only indexed
KV payloads and explicitly linked recurrent companions are removed. Unknown
files, model directories, symlinks, the index, weights and volatile caches are
preserved. Errors are shown to the user. Clearing can make the next reply slower
while its cache rebuilds; it is not a speed optimization.

## Acceptance evidence

PARTIAL: Release `a26300209a56a3f0bf5a10e84a9d23728d20f9c0` completed
native percentage/save, real quota eviction, popup and Settings Clear, refill,
streaming suppression and same-quota dismissal checks with the unchanged engine.
The resident clear reduced indexed bytes from 1,016,752,392 to zero while the
model remained resident; Settings Clear reduced 919,365,824 bytes to zero.
Clear preserved the unindexed sentinel; the engine later removed that invalid
safetensors sentinel on reload, a separate existing validation behavior.

That run exposed a stale notice after Disk Cache was disabled and saved. A
follow-up returned Blue at 20.1 tok/s with disk caching absent from the live
model, but the old 152 MB warning remained. The follow-up change invalidates
the notice on saved cache changes and accepts samples only from coordinators
built with the matching cache contract. Disabled caches cannot present notices.
It also discards a Clear result if its notice was invalidated while IO ran.
Fresh Release/UI, automated regression and full CacheProof evidence for this
follow-up remain pending, including disable, percentage restore and relaunch.

Private artifacts: `ssd-isolated-resident-clear-timeline.json`,
`ssd-isolated-after-settings-clear.json`, `ssd-isolated-cache-off-turn.ax.txt`,
`ssd-isolated-cache-off-turn-runtime.json` under the 2026-09-14 vision evidence
directory. Run 1 exited cleanly with no owned processes left, 26.42 GiB peak
tracked footprint and unchanged 5.59 GiB swap. This is not physical 16 GiB proof.
Earlier combined-branch receipts do not substitute for this source and engine.
The full combined agent sweep (50 pass / 32 fail / 4 skip) remains on PR #2774;
no agent/model behavior change or claim is included here.
