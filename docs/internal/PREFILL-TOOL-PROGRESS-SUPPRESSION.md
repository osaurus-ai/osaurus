# Preserve foreground prefill during suppressed tool progress

A background generation with `suppressProgressUI` could clear foreground prefill
when its first output was a tool-call envelope fragment. That branch directly
finished the global progress manager, bypassing the helper that already routes
suppressed output to the warmup side channel.

The branch now uses the existing suppression-aware helper, matching text and
reasoning output. An internal mapper parameter defaults to the shared manager
and lets regression tests use isolated progress state. Existing callers retain
the same default behavior; no public API is added.

The baseline was reproduced against the compiled application core with unchanged
mapper and manager source: the suppressed test failed its inverted clear-event
expectation and two foreground-state assertions; the unsuppressed control passed.
The isolated candidate tests additionally hold the upstream stream open while
checking first output, ensuring the positive control cannot pass solely because
stream-drain cleanup eventually clears progress.

Candidate typechecking/execution and a full application build remain pending.
This fixes one suppression bypass; it does not solve broader request/session
ownership of the global progress manager, media-encoding progress, or final GPU
completion timing. It makes no Sentry crash or live GUI occurrence claim.
