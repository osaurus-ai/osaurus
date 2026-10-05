# Privacy classifier error boundary

The classifier head previously composed projection, bias, dtype conversion, evaluation and host conversion without checking recoverable MLX errors. With a returning error handler, a failed operation can leave an invalid array. A deliberate CPU projection shape error reproduced recursive host conversion and stack overflow; this establishes a failure mechanism, not the originating cause of any production crash report.

The forward pass now owns one scoped error collector. Embedding, transformer-block and final-normalization boundaries check it; the classification helper uses that same collector so a pending graph error cannot disappear into a new scope. Each head operation is checked before its result is consumed. Successful logits retain the same float32 host representation. A logits shape inconsistent with the configured token/label counts throws a manifest error before materialization, and the host count check throws instead of terminating the process.

Focused regressions exercise normal values, malformed rank, incompatible projection dimensions, incompatible bias, an extra broadcast dimension, wrong label count and prior-error precedence. These tests use CPU arrays and require no model weights. Their scope is the actual classification helper. They do not prove every intermediate operation in attention/MoE, asynchronous device faults, weight loading, full-model inference or live app behavior.

The existing throwing model/kit APIs propagate these failures; no fallback output, automatic retry or model-output modification is introduced. Scoped handler restoration is owned by MLX TaskLocal.withValue. This synchronous change adds no cancellation suspension or mid-forward cancellation behavior.
