# RDMA/TB5 Node Discovery Product Spec

Updated: 2026-06-10

## Goal

Make multi-Mac RDMA/TB5 tensor-parallel discovery easy when Osaurus is running
on each Mac, while preventing accidental VPN/Tailscale data-plane use.

The user-facing flow should make the right path obvious:

1. Turn on RDMA/TB5 cluster mode on each Mac.
2. See nearby eligible Osaurus nodes.
3. Run automatic checks.
4. Confirm a rank/port plan.
5. Start only when every node has a proven internal RDMA/Thunderbolt data-plane
   route and a compatible vMLX runtime.

## Non-Goals For The First PR

- No automatic cluster join.
- No background model sharing.
- No silent use of Tailscale, VPN, Wi-Fi, or random LAN routes for tensor data.
- No claim that a model family is distributed-ready from discovery alone.
- No UI implementation in the initial scaffold PR.

## Network Rules

### Control Plane

Control-plane discovery may use:

- Bonjour/mDNS service advertisement on the local network.
- Explicit manual host entry.
- A user-approved pairing code or local trust token.

Control-plane discovery must not imply model execution readiness.

### Data Plane

Tensor-parallel data must use a real internal high-speed path:

- Preferred AdLab-style Thunderbolt loopbacks: `10.20.0.x`.
- Direct Thunderbolt links: `10.10.x.x`.
- Future user-defined RDMA/private fabric ranges only after route and interface
  checks prove the traffic does not leave the intended internal fabric.

Forbidden for tensor data:

- Tailscale `100.x`.
- Other VPN interfaces.
- Wi-Fi unless explicitly marked diagnostic-only.
- Localhost/loopback as multi-node proof.
- Any address where the interface cannot be identified.

Tailscale can remain useful for SSH/control diagnostics, but it must never be
selected as the tensor data-plane path.

## Discovery Architecture

Each running Osaurus node should advertise a local discovery record with:

- Node id.
- User-visible device name.
- Osaurus version.
- vMLX pin/version.
- Distributed runtime capability version.
- Candidate control endpoints.
- Candidate data-plane endpoints.
- JACCL availability.
- `librdma` load status.
- `MLX_IBV_DEVICES` matrix readiness.
- Available model shard roots, only as redacted/digest metadata.
- Supported roles: coordinator, rank worker, local-only.

The discovery record must separate candidates from proof. A candidate address is
not usable until the verifier marks it as a passing data-plane route.

The source contract for the first non-UI scaffold is
`DistributedNodeDiscoveryRecord` with a nested `DistributedRuntimeReadinessReport`.
It encodes as stable snake_case JSON so the future SwiftUI panel, API surface,
and web/debug tooling can consume the same fields without local key mapping.
The report state maps to the UI state as:

- `blocked`: one or more hard errors.
- `partial`: no hard errors, but one or more warnings or missing proof gates.
- `ready`: all current checks are info-only and the selected mode can be
  considered runnable by policy.

Only `ready` may enable `Start cluster`.

## Fallback Check Ladder

The UI and runtime should run checks in this order and label each level:

1. **Presence**: another Osaurus node advertises itself.
2. **Trust**: the node is paired or approved by the user.
3. **Version**: Osaurus and vMLX distributed capability versions are compatible.
4. **Address classification**: candidate data-plane addresses are not VPN,
   Tailscale, localhost, or unknown.
5. **Route check**: each data-plane address resolves to the intended internal
   interface.
6. **Port check**: the coordinator and rank worker ports are reachable on the
   internal address, not via VPN.
7. **RDMA check**: `librdma` is loadable and RDMA is enabled.
8. **JACCL check**: JACCL backend is available.
9. **IBV matrix check**: every rank has the expected peer device entries,
   square matrix shape, matching world size, and `null` or empty self slot.
10. **Collective smoke**: ring smoke first where useful, then JACCL multi-rank
    all-sum/all-gather proof.
11. **Model shard check**: every rank has the expected shard/digest for the
    selected model.
12. **Runtime proof**: worker liveness, rank agreement, token authority,
    token/s, and architecture-specific cache evidence.

If a lower check passes and a higher check fails, the UI must show `PARTIAL` and
the exact blocker. It must not collapse that into a generic ready state. Warning
states such as private LAN, Wi-Fi, link-local, or localhost addresses are not
runtime proof.

## UI Surface

### Menu Entry

Add a future menu item:

- Label: `Distributed Inference`
- Default state: disabled/off unless the user enables the feature.
- Secondary status text: `Off`, `Discovering`, `Partial`, `Ready`, `Blocked`,
  or `Running`.

### Node Discovery Panel

Expected controls:

- Toggle: `Enable node discovery`.
- Toggle: `Allow this Mac to serve as a rank`.
- Button: `Scan`.
- Button: `Run checks`.
- Button: `Copy diagnostics`.
- Button: `Start cluster` only when all required gates pass.
- Button: `Stop cluster` when running.
- Manual entry: host/IP and port, with a clear `control` vs `data` selector.

Expected node cards:

- Device name.
- Role: coordinator/rank/local-only.
- Rank assignment.
- Control endpoint.
- Data-plane endpoint.
- Interface label.
- RDMA/JACCL/IBV status.
- Model shard status.
- Last check time.

### Animation / State Language

Animations should reflect state transitions, not decorate the panel:

- Scanning: subtle pulsing ring around candidate nodes.
- Checking: per-node progress sweep through the fallback ladder.
- Partial: amber interrupted path between nodes, with the failing gate selected.
- Ready: solid internal-fabric links between all selected ranks.
- Blocked: red link only on the failing edge, not the whole graph if only one
  peer is blocked.
- Running: compact live throughput/rank-agreement pulse, only after runtime
  proof starts.

Do not animate unknown or unproven nodes as connected.

## Required Diagnostics Copy

`Copy diagnostics` should include:

- Osaurus version and commit.
- vMLX pin.
- Node id and redacted hostname.
- Candidate control addresses.
- Candidate data-plane addresses.
- Address classifications.
- Interface names.
- Route result.
- Port result.
- `librdma` load status.
- JACCL status.
- IBV matrix summary.
- Collective smoke result.
- Model shard digest status.
- Runtime proof summary if a model ran.

Do not include local model paths, secrets, full hostnames, tokens, or private
keys unless the user explicitly exports a developer diagnostic bundle.

## Acceptance Criteria

- A user with Osaurus open on every Mac can discover nodes without copying shell
  commands.
- The panel never chooses Tailscale `100.x` or VPN routes for tensor data.
- Every node shows the exact failing gate when not ready.
- A size-1 fallback never appears as distributed-ready.
- A route pass never appears as model-ready.
- Starting distributed execution is impossible until data-plane, RDMA/JACCL,
  IBV, collective, shard, and runtime gates required for the selected mode pass.
