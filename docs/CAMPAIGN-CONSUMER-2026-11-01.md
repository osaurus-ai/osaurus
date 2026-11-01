# Runtime campaign consumer integration

This branch joins the MiniMax-M3.1 consumer support and historical final-pin PR ancestry onto current main, preserving later agent settings, cache/error handling, request-sized SSM replay, export integrity and independent token provenance. All four dependency surfaces and both pin tripwires point to runtime94dd017c, the current-main integration projection.

The original consumer conflicts were old runtime revisions and their assertions. Those old pins are retained in history, not restored as the final dependency. No sampler or thinking-mode masking is added. Bundled DSpark detection, adaptive per-request selection, retained target weights during eligible toggles, reasoning/image support and conversation residency come from the incoming changes. Existing agent editor and main picker resolve the same capability and per-agent preference path; final saved-setting/relaunch and runtime usage checks are still pending.

Qualification is in progress on the local Max2 only. Historical speed and cache measurements remain bound to their original binary, workload and hardware. The combined source needs affected tests, actual isolated Release UI, model multi-turn/cache/tool waits and source-to-merge identity before acceptance. The separate M2 core candidate is not consumed. No release.
