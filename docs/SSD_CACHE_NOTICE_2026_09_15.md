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

PARTIAL: isolated-source tests, fresh Release build and native Settings/chat
quota, clear, refill, dismissal, streaming and persistence checks are pending.
Earlier combined-branch receipts do not substitute for this source and engine.
The full combined agent sweep (50 pass / 32 fail / 4 skip) remains on PR #2774;
no agent/model behavior change or claim is included here.
