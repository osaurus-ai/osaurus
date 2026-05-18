# PR 1147 App Startup Fix Gate

Date: 2026-05-18

Scope: Osaurus PR #1147 debug app built from `codex/vmlx-swift-package-switch`, launched with an isolated home and `OSU_MODELS_DIR=/Users/eric/models`.

## Findings

- Pre-fix LaunchServices app smoke did not bind `127.0.0.1:1337`.
- First root cause: fresh-install bootstrap wrote built-in theme JSON before storage migration, and `StorageMigrator.isPristineInstall()` treated that as real user data. The app showed the migration overlay and blocked server startup.
- Second root cause: memory/vector database initialization inherited startup sequencing and could block on storage keychain access before the HTTP server had a chance to bind.
- Third root cause: `ServerController.startServer()` ran a Network-framework port preflight before the authoritative NIO bind. In the live app smoke, startup reached scheduler/memory background work but never produced the bind; removing the preflight and relying on NIO bind resolved the app `/health` gate.

## Fixes

- `StorageMigrator.isPristineInstall()` now ignores bootstrap-only entries: dotfiles, empty directories, and `themes/` when it contains only built-in theme JSON.
- Memory/vector startup is now `Task.detached(priority: .utility)`.
- App startup now queues server bind before provider connection, scheduler DB polling, sandbox registration, and Parakeet/CoreML auto-load. Speech auto-load awaits the server startup task.
- `ServerController` no longer preflights the port with `NWConnection`; NIO bind remains the real collision check and the existing `EADDRINUSE` error message is preserved.

## Verification

- `swift test --package-path Packages/OsaurusCore --filter RuntimePolicySourceTests --jobs 2`: 28/28 passed.
- `swift test --package-path Packages/OsaurusCore --filter StorageMigrationGapTests --jobs 2`: 7/7 passed.
- `xcodebuild -workspace osaurus.xcworkspace -scheme osaurus -configuration Debug -derivedDataPath build/XcodeDerivedData-codex-live-pr1147 -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build`: succeeded.
- Isolated LaunchServices app smoke after port-probe fix:
  - process: `docs/internal/live-gates/20260518T_pr1147_app_open_after_port_probe_fix/processes.txt`
  - listener: `docs/internal/live-gates/20260518T_pr1147_app_open_after_port_probe_fix/listeners.txt`
  - health: `docs/internal/live-gates/20260518T_pr1147_app_open_after_port_probe_fix/health.json`
  - result: `127.0.0.1:1337` listening and `/health` returned `{"status":"healthy","loaded":[],"current_model":null}`.

## DSV4 Renderer Gate Added To Matrix

The PR live matrix and source policy tests now require the same DSV4 settings checks that were learned from the Python-side renderer:

- native DSV4 cache copy present;
- block size fixed/disabled at 256;
- generic KV q4/q8 controls disabled;
- pool quant visible;
- JIT disabled;
- generation defaults shown from `generation_config.json` / `jang_config.json`, including native `top_k`;
- CLI preview omits invalid flags: `--kv-cache-quantization`, `--enable-jit`, `--is-mllm`, and `--speculative-model`.
