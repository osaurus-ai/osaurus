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

Saved RAM settings are named separately from observed process-wide limits
and occupancy. The snapshot is sampled after engine drain, with its own
timestamp. It includes actual allocator/memory ceilings, MLX active/cached
bytes, process physical footprint, RSS and current host memory pressure.
These are neither the failed operation's peak nor proof of OOM, and the
allocator ceiling is not presented as allocated memory. No policy, sampler,
retry or GPU-reset behavior changes.

Local validation: 44 focused tests across three suites pass, covering payload
classification/privacy, unavailable counts, distinct limits/occupancy/RSS/
physical-footprint fields, once-only reporting with original-error transport
and producer drain, plus existing crash-reporting lifecycle/consent behavior.
The tests do not start the real Sentry SDK or transmit fixture events.

Release app qualification remains pending. This is an observability repair,
not a reproduction or fix of the unknown user's GPU workload. Errors before
the mapped engine stream (for example, input preparation or model loading)
are outside this first reporting change.
