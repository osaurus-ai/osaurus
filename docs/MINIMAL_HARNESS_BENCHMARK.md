# Minimal Mac Harness Comparison

This lane compares harnesses, not models. Every column must use the same model
bundle/provider, generation defaults, task JSON, repeat count, and workspace
fixtures. Reports carry `environment.harness`, so `osaurus-evals matrix` keeps
same-model Osaurus and Pi results in separate columns.

## Task set

- substantial single-file app and direct workspace delivery
- surgical repository edit
- failing-command recovery
- long-horizon build and test
- trusted-workspace escape refusal
- cancellation and VM export (Osaurus safety/lifecycle rows; Pi is marked
  unsupported rather than credited)

The matrix publishes completion, loop-free rate, median model steps,
first-action latency plus action completion coverage, wall time, cumulative context, correct file delivery,
and lifecycle/discovery/replay friction calls. Security rows are deterministic:
an out-of-root host write or VM-to-host read is a failure even if the final
answer sounds correct.

## Run Osaurus

Use one process and the same repeat count for both suites. Run the host-folder
lanes first. Before the SandboxFrontier lane, quit every Osaurus app instance
and stop any other eval process. Sandbox startup now performs a cross-process
ownership preflight and reports the owning PID/process as
`vmnetOwnedByOtherProcess`; this blocker does not consume a startup attempt or
arm the 120-second failure cooldown.

```bash
cd Packages/OsaurusEvals
OSAURUS_EVALS_HARNESS=osaurus swift run osaurus-evals run \
  --suite Suites/AgentLoop \
  --filter 'substantial-single-file-app|edit-one-key-preserve-others|recover-from-failing-command|workspace-escape-refused|cancel-after-two-calls-no-zombie' \
  --model "$MODEL" --repeat 3 --out build/minimal-harness/osaurus-agent-loop.json

OSAURUS_EVALS_HARNESS=osaurus swift run osaurus-evals run \
  --suite Suites/AgentLoopFrontier \
  --filter 'long-horizon-project' \
  --model "$MODEL" --repeat 3 --out build/minimal-harness/osaurus-frontier.json

OSAURUS_EVALS_HARNESS=osaurus swift run osaurus-evals run \
  --suite Suites/SandboxFrontier \
  --filter 'vm-host-isolation|vm-file-export' \
  --model "$MODEL" --repeat 3 --out build/minimal-harness/osaurus-sandbox.json
```

Do not run the Release app, Pi/API phase, or a second eval CLI concurrently
with SandboxFrontier. After the signed sandbox lane exits, start the API for Pi,
run the Pi adapter, stop it, and only then launch the fresh Release app for UI
proof. This keeps vmnet ownership and local-model residency attributable to one
process at a time.

## Run Pi

Pi's JSON mode is adapted into the same `EvalReport` schema. The adapter
disables extensions, skills, prompt templates, context files, and sessions so
the measured surface is Pi's built-in harness. Pi tool names are normalized to
the five Osaurus workspace operations for friction accounting. For a same-local-
model run, `--osaurus-base-url` creates a temporary `PI_CODING_AGENT_DIR` with
an OpenAI-compatible provider and deletes it afterward; the user's Pi config is
never read or changed. An `agentLoop.maxTokens` fixture value overrides the
adapter default for that case in both harnesses, and `--timeout-seconds` records
a bounded errored row instead of allowing a wedged Pi process to stall the lane.
The report records the Pi CLI version, API model, context/output limits, CPU
model, architecture, RAM, core count, OS release, and each raw trial outcome.
Pi does not expose decode token/s, TTFT, per-run CPU, or peak process RAM in
this mode; the matrix leaves those cells empty and emits a comparability
warning instead of estimating them.

```bash
node scripts/evals/pi-harness-runner.mjs \
  --pi "$(command -v pi)" --model "$MODEL" --repeat 3 \
  --api-model bonsai-27b-1bit-jang \
  --osaurus-base-url http://127.0.0.1:1337/v1 \
  --context-window "$CONTEXT_WINDOW" --max-tokens "$MAX_TOKENS" --timeout-seconds 900 \
  --suite Packages/OsaurusEvals/Suites/AgentLoop \
  --filter 'substantial-single-file-app|edit-one-key-preserve-others|recover-from-failing-command|workspace-escape-refused|cancel-after-two-calls-no-zombie' \
  --out Packages/OsaurusEvals/build/minimal-harness/pi-agent-loop.json

node scripts/evals/pi-harness-runner.mjs \
  --pi "$(command -v pi)" --model "$MODEL" --repeat 3 \
  --api-model bonsai-27b-1bit-jang \
  --osaurus-base-url http://127.0.0.1:1337/v1 \
  --context-window "$CONTEXT_WINDOW" --max-tokens "$MAX_TOKENS" --timeout-seconds 900 \
  --suite Packages/OsaurusEvals/Suites/AgentLoopFrontier \
  --filter 'long-horizon-project' \
  --out Packages/OsaurusEvals/build/minimal-harness/pi-frontier.json

node scripts/evals/pi-harness-runner.mjs \
  --pi "$(command -v pi)" --model "$MODEL" --repeat 3 \
  --api-model bonsai-27b-1bit-jang \
  --osaurus-base-url http://127.0.0.1:1337/v1 \
  --context-window "$CONTEXT_WINDOW" --max-tokens "$MAX_TOKENS" --timeout-seconds 900 \
  --suite Packages/OsaurusEvals/Suites/SandboxFrontier \
  --filter 'vm-host-isolation|vm-file-export' \
  --out Packages/OsaurusEvals/build/minimal-harness/pi-sandbox.json
```

## Publish the matrix

```bash
cd Packages/OsaurusEvals
swift run osaurus-evals matrix build/minimal-harness \
  --out build/minimal-harness/matrix.json \
  --markdown build/minimal-harness/matrix.md
```

Promotion requires deterministic security parity, no material completion-rate
regression across broad models, and a Pareto improvement in at least one
friction metric. Missing Pi credentials/model support, live VM proof, or
Release-app proof must be reported as `BLOCKED` or `PARTIAL`, never as a win.
