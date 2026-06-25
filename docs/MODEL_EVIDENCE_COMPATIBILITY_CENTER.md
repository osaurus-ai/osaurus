# Model Evidence and Compatibility Center

The model evidence projection separates file-level compatibility from support
claims. A model can pass compatibility preflight and still remain `unproven`
until live evidence rows are registered.

## Status contract

- `supported`: local/import state is available, compatibility is not blocked,
  and passing runtime, token/s, memory, cache, and benchmark or eval evidence is
  registered for the exact model row.
- `partial`: compatibility or proof evidence exists, but at least one required
  dimension is incomplete, blocked, unavailable, or only partially proven.
- `unsupported`: compatibility preflight blocks the model, or a registered proof
  row failed or errored.
- `unproven`: the model is catalog-only, externally discovered without proof, or
  locally loadable but has no live proof rows yet.

## Proof metadata

Generation proof rows (`runtime` and `benchmark`) must record positive
`tokens_per_second` metadata to be treated as passing evidence. Memory proof can
come from a `runtime` or `memory` proof row with one of:

- `physical_footprint_within_limit=true`
- `memory_within_limit=true`
- `ram_within_limit=true`
- `memory_proof=passed`
- `ram_proof=passed`

Cache proof is a separate `cache` row so import state and runtime cache behavior
do not get conflated. Benchmark and eval artifacts register as their own report
kinds; either a passing benchmark or a passing eval row can satisfy the
benchmark/eval requirement.

Missing artifacts, descriptor errors, missing token/s on passing generation
proof, and missing memory proof on passing memory rows are downgraded before the
row support state is computed.
