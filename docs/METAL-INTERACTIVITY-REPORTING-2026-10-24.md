# Handled Metal interactivity reporting

The generation mapper already preserves terminal runtime failures for the
requesting UI/API. Those handled failures do not create a fatal Sentry event;
generation begin/submit breadcrumbs alone cannot identify their cause.

This change reports only the native Metal command-buffer interactivity
signature through the existing crash-reporting consent gate. It retains the
original caller error and continues draining the upstream producer. One
mapped stream reports at most once, including a duplicate terminal event.
Other errors are not reclassified as interactivity failures.

The new payload contains the stage, authoritative available token counts and
model reference. Canonical publisher--repository identifiers are retained;
other local names/paths are hashed. Raw error text, prompts, generated output,
and file paths are not copied into the report.

All explicit saved RAM overrides (physical fraction, allocator cap, KV cap,
concurrency and fail-closed choice) are retained; absent overrides are not
invented as limits. Saved settings are named separately from observed process-wide limits
and occupancy. The snapshot is sampled at terminal completion info, before
the adapter finishes draining its producer, with its own timestamp. It includes actual allocator/memory ceilings, MLX active/cached
bytes, process physical footprint, RSS, actual raw Metal architecture and
current host memory pressure. The read-only memory-status API exposes the
same architecture identifier so local diagnostics can verify it.
These are neither the failed operation's peak nor proof of OOM, and the
allocator ceiling is not presented as allocated memory. No policy, sampler,
retry or GPU-reset behavior changes.

Local validation: 46 focused tests across three suites pass, covering payload
classification/privacy, unavailable counts, distinct limits/occupancy/RSS/
physical-footprint fields, once-only reporting with original-error transport
and producer drain, plus existing crash-reporting lifecycle/consent behavior.
The tests do not start the real Sentry SDK or transmit fixture events.

Release app qualification remains pending. This is an observability repair,
not a reproduction or fix of the unknown user's GPU workload. Errors before
the mapped engine stream (for example, input preparation or model loading)
are outside this first reporting change.

Source review caught and corrected an earlier after-drain label: native `.info`
is deliberately emitted before GPU/cache cleanup finishes. Reporting remains
at that existing terminal-info boundary and does not delay the caller error.
