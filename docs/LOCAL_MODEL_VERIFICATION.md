# Local Model Verification

The Local Model Verification Workbench is an on-demand live proof surface in
the downloaded model detail view. Static compatibility metadata remains useful
for preflight diagnostics, but it does not establish that a model can complete
an Osaurus tool workflow.

## Evidence contract

Each run hashes every regular file in the selected bundle and binds the report
to that exact SHA-256 digest. Non-regular entries fail inspection. Hugging Face
snapshot symlinks are accepted only when their once-resolved target is a
regular file contained by the same repository; other symlinks fail. The report
also records:

- the bundle chat-template source and any runtime fallback;
- the declared tool parser or format;
- scalar values from `generation_config.json`;
- the linked vMLX revision when the runtime exposes authoritative provenance,
  otherwise an explicit `unverified` source rather than an asserted pin;
- per-probe stop reason, token count, and decode token/s when emitted.

Reports are stored as private, versioned JSON under
`~/.osaurus/config/model-verification/`, registered as `live_proof` evidence,
and projected into `model-ledger.json` with their exact bundle digest and a
configuration-relative artifact path. Loading a validated saved report
re-registers it after restart. The ledger projection does not change the
production-serving decision.

## Live probes

The workbench uses the normal Osaurus MLX chat/template/parser path. It does not
replace model-native generation defaults or repair model output. A complete run
checks:

1. visible generation;
2. a dedicated, closed reasoning channel when the bundle declares one;
3. production-default `auto` tool selection;
4. a schema-valid fixture tool call and arguments;
5. continuation grounded in the executed fixture result;
6. a second schema-valid tool call after tool history;
7. no visible reasoning, parser, or tool markers in visible or reasoning text;
8. a reported natural stop/EOS reason;
9. positive decode token/s;
10. stream termination within a bounded deadline after cancellation, with no
    post-cancel deltas.

Reasoning is `unsupported`, rather than failed, when the bundle declares no
reasoning mode. A missing chat template blocks tool-call proof even if a runtime
fallback happens to parse one run. The workbench recomputes the exact bundle
digest off the main actor before presenting saved evidence and again before
publishing a completed run. Any digest change makes the report visibly stale or
aborts publication and requires re-verification.

## Classifications

- `proven`: every required live probe passed for the exact digest.
- `partial`: some required evidence passed, but a probe is blocked or a
  declared optional capability failed.
- `unsupported`: the runtime contract explicitly does not support the tested
  capability.
- `failed`: a required live probe failed or errored.
- `unproven`: no sufficient live evidence exists.

Fixture-driven tests exercise the protocol deterministically. They are not a
substitute for the on-demand live row for a real local model.
