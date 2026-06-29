# SandboxFrontier suite

End-to-end agentic evals that run the canonical `AgentToolLoop` against the
**live Linux-VM sandbox** (Apple Containerization). Cases cover code
execution, combined host-folder mode, plugin creation, secrets,
background processes, networking, and artifact delivery — the full
autonomous-execution surface.

## Requirements & gating

- A working sandbox on the host: `SandboxManager.checkAvailability()` must
  pass and Sandbox setup must be complete (`setupComplete: true`). Cases are
  **SKIPPED (not failed)** otherwise — same semantics as `requirePlugins`.
- Off-CI: token cost, VM boot (~minutes on first case), real network for
  `sandbox.install-and-use` and `sandbox.live-fetch`.
- The container is **kept alive across cases** (boot is the expensive part);
  only per-agent state is provisioned/torn down per case.

## Running (entitlement signing required)

Booting the VM in-process requires the `com.apple.security.virtualization`
entitlement, which SwiftPM's ad-hoc signing does not carry — an unsigned
CLI fails every sandbox case with a vmnet "Container networking failed"
error. Build, re-sign, then invoke the binary **directly** (a `swift run`
after source changes would relink and drop the signature):

```bash
swift build --package-path Packages/OsaurusEvals --product osaurus-evals
codesign --force --sign - \
  --entitlements Packages/OsaurusEvals/osaurus-evals.entitlements \
  Packages/OsaurusEvals/.build/debug/osaurus-evals

ANTHROPIC_API_KEY=... JUDGE_MODEL=xai/grok-4.3 XAI_API_KEY=... \
Packages/OsaurusEvals/.build/debug/osaurus-evals run \
  --suite Packages/OsaurusEvals/Suites/SandboxFrontier \
  --model anthropic/claude-fable-5 \
  --out build/evals/sandbox-claude.json
```

Two operational notes:

- The freshly signed binary triggers a one-time macOS Keychain prompt
  ("osaurus-evals wants to use your confidential information") for the
  Osaurus storage key — approve with **Always Allow**. Every re-sign
  re-prompts.
- Don't run sandbox evals while another process (the Osaurus app, a second
  eval run) holds the container — VM networking and the bridge socket are
  exclusive. The runner stops the container gracefully at the end of the
  suite; a hard-killed run can leave a dirty `rootfs.ext4` whose warm
  restart corrupts the guest (`chown: invalid group` during provisioning).
  Recovery: `rm -rf ~/.osaurus/container/containers/osaurus-sandbox` to
  force a cold re-unpack.

## How sandbox cases work

`fixtures.sandbox` (presence = sandbox mode) maps onto the temporary eval
agent's `AutonomousExecConfig`:

| fixture field              | AutonomousExecConfig         | default |
|----------------------------|------------------------------|---------|
| `pluginCreate`             | `pluginCreate`               | `true`  |
| `backgroundProcessEnabled` | `backgroundProcessEnabled`   | `false` |
| `networkEnabled`           | `sandboxNetworkEnabled`      | `true`¹ |
| `allowHostSecretReads`     | `allowHostSecretReads`       | `false` |
| `maxCommandsPerTurn`       | `maxCommandsPerTurn`         | `10`    |

¹ honored at VM boot — flipping it per-case does not restart a running
container.

- `hostFolder: true` → **combined mode**: the case temp workspace (with
  `workspaceFiles`) becomes the read-only host context
  (`ExecutionMode.sandbox(hostRead: ctx)`); `file_read` / `file_search` stay
  host-side. Omitted/false → pure sandbox mode.
- `seedFiles` are written into the eval agent's VM home **before** the run
  via guest-side exec (ownership matches the agent user).
- `seedSecrets` are pre-seeded into `AgentSecretsKeychain` for the eval agent
  and deleted after the case.
- `expect.agentLoop.sandboxFiles` asserts on files in the agent's VM home,
  read from the host through the VirtioFS mount
  (`~/.osaurus/container/workspace/agents/<agent>/`). All other assertions
  (`toolUsageAudit`, `rubric`, `artifactShared`, `mustCallToolsInOrder`, …)
  work unchanged.

## Headless constraints (case-authoring rules)

The eval CLI has no app bundle and no UI run loop:

- **`sandbox_secret_set` must always be called with `value`** (or the case
  must use `seedSecrets`). The no-value flow returns a `secret_prompt`
  marker that only ChatView can answer — headless runs would dead-end.
- User notifications no-op headlessly (`NotificationService` guards on
  `Bundle.main.bundleIdentifier`); the plugin-registration toast is
  state-only and safe.
- `.ask`-gated tools are auto-approved by the harness (isolated eval agent,
  isolated VM home), mirroring the other agent-loop suites.

## Post-case cleanup

The runner tears down per-case: eval agent record (+ DB/scheduler rows),
keychain secrets, any plugin the case registered (library entry, install
state, registry tools), and the agent's VM user + home dir
(`SandboxAgentProvisioner.unprovision`). The container stays running.

## Failure attribution

Keep the harness honest: a failure here is either a **harness defect**
(boot/provision errors surface as `errored` rows with the registrar's
reason) or a **model-discipline finding** (wrong tool surface, fabricated
outputs, refusal despite capability). Record findings in
`docs/HARNESS_COMPATIBILITY.md` per its attribution convention rather than
softening cases to chase green.

Known provider-side behavior: Anthropic's real-time **cyber safeguard** can
block secret-flavored prompts at the API level (`stop_reason: "refusal"`,
zero content blocks) before the model sees them. The remote-provider stream
surfaces this as an explicit `Anthropic refused this request` error, so
affected cases show up as `errored` rows with the provider's explanation —
attribute these to the provider, not the harness.

Harness defects this lane has already caught (fixed, lane re-run before
publishing): `background-process` once looped models forever because the
job wrapper lingered as an unreaped zombie and every liveness probe was a
bare `kill -0` (which counts zombies as alive), and killing the wrapper pid
orphaned the actual workload. Background jobs now launch under `setsid`,
kills signal the whole process group, and liveness probes are zombie-aware
(`/proc/<pid>/status`).
