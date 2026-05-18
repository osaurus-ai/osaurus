# PR 1147 Keychain-Safe App Launch Note

Timestamp: 2026-05-18 14:13 PDT

Scope: Osaurus PR #1147 live app/API gate procedure.

## Problem

Do not launch the macOS app for live gates by directly executing the app binary
with a fake `HOME`, for example:

```sh
HOME=/tmp/osaurus-pr1147-home-http-probe \
  build/XcodeDerivedData-codex-live-pr1147/Build/Products/Debug/osaurus.app/Contents/MacOS/osaurus
```

That launch mode is not equivalent to a user app launch. Osaurus stores its
local database encryption key in macOS Keychain. A direct binary launch with a
temporary `HOME` can leave the app outside the normal user login-keychain
context, causing the UI error:

`Keychain cannot be found to store data encryption key`

The failed direct launch also did not bind `127.0.0.1:1337` during the attempted
HTTP route probe. The process was stopped. Process/listener cleanup after the
attempt showed no PR Osaurus listener and only the installed `vMLX.app`
listener on `127.0.0.1:8080`.

## Allowed Live-Gate Launch Modes

Use one of these modes instead:

1. Launch the debug app through normal LaunchServices with the real user
   keychain context. This is the required real user keychain context mode for
   app-level live gates. If environment variables are needed, set them with
   `launchctl setenv`, launch the app with `open -n`, then restore/unset the
   variables after the gate.
2. If a fully isolated app-home test is required, create and unlock an explicit
   temporary test keychain, add it to the keychain search list for the duration
   of the run, then restore the original keychain search list and default
   keychain. Do not leave the temporary keychain active.
3. Prefer non-app source/unit tests or route probes against an already-running
   trusted app instance when the row does not require UI or app persistence.

Helper:

```sh
scripts/pr1147_keychain_safe_app_launch.sh \
  --app build/XcodeDerivedData-codex-live-pr1147/Build/Products/Debug/osaurus.app \
  --models-dir /Users/eric/models
```

The helper launches the `.app` bundle through LaunchServices, refuses fake
`HOME`, exposes `OSU_MODELS_DIR` with `launchctl setenv`, waits briefly for the
LaunchServices request to be accepted, and restores the previous launchctl
environment. Use `--dry-run` to inspect the launch plan without changing
launchctl state.

## Gate Boundary

The HTTP route probe helper remains valid, but route artifacts are blocked
until the server is started with a Keychain-safe launch mode. A route probe
collected from a broken fake-HOME launch must not be counted as startup,
settings, cache, model, or UI proof.
