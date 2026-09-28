# Restore-only handoffs and protected child residency

When smart swapping is enabled and the invoking local parent is not resident, delegation schedules a restore-only lease. If the different child model is already resident under unrelated API, plugin, or scheduled ownership, warm reuse does not grant the handoff ownership of those weights. Under strict single-model policy, subsequent parent restoration correctly refuses to evict the protected child.

The planner now rejects this combination before child execution, using the same protected-target policy as a resident-parent swap. It preserves swapping-OFF coexistence, restoration after an unprotected child, and protected-target reuse when there is no local parent to restore. The comparison is case-insensitive.

## Regression and proof boundary

`RestoreOnlyProtectedTargetTests` uses the real pure planner with no runtime doubles or model loads. The original three-test baseline executed against the unchanged compiled integration core: the protected-target refusal failed, while swapping-OFF and unprotected-child controls passed. The candidate adds a fourth control for a missing local parent.

The exact candidate planner function, renamed only for a private test module and linked to real compiled-core types, passed 30 methods / 33 invocation rows: four focused controls plus the existing planner suite. A rebuilt candidate core, complete adjacent suites, and application residency/continuation proof remain pending. This change does not establish model-load, cache-restoration, cancellation, or performance claims and does not weaken ownership checks during cleanup.
