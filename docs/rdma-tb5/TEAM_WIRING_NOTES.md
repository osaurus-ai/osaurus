# RDMA/TB5 Team Wiring Notes

Updated: 2026-06-10

## Discovery Record

Each running Osaurus node should eventually publish a local discovery record
with these fields:

- `node_id`
- `device_name`
- `osaurus_version`
- `osaurus_commit`
- `vmlx_pin`
- `distributed_capability_version`
- `roles`: `coordinator`, `rank_worker`, `local_only`
- `control_endpoints`
- `data_plane_candidates`
- `data_plane_verdicts`
- `librdma_loadable`
- `jaccl_available`
- `ibv_devices_configured`
- `collective_smoke`
- `model_shard_digests`
- `runtime_proof`

Candidate fields must not be treated as proof fields.

Current engine-side reference for this contract is vMLX main
`fcb69484105683c5a5032b97420d00e75d3a914e`, which exposes the distributed
probe, peer smoke, inventory, replica smoke, rank-worker products, and the
engine-side `IBVDeviceMatrix` validator used by `DistributedProbe --json`.

Current Osaurus-side source contract is `DistributedNodeDiscoveryRecord` and
`DistributedRuntimeReadinessReport`. The UI should treat `ready` as the only
state that can enable cluster start; `partial` means warnings exist and must be
shown as missing proof, not as usable runtime.

The JSON contract is snake_case for app and web consumers:

- `node_id`
- `device_name`
- `osaurus_version`
- `osaurus_commit`
- `vmlx_pin`
- `distributed_capability_version`
- `control_endpoints`
- `data_plane_candidates`
- `readiness.readiness_state`
- `readiness.is_runnable`
- `readiness.endpoints[].address_class`

For `MLX_IBV_DEVICES`, the first source contract is
`DistributedIBVDeviceMatrix`. It validates the JSON rank matrix shape before
runtime launch:

- row count must match `world_size`
- every row must be square
- diagonal self slots must be `null` or empty string
- off-diagonal peer slots must contain a device name

The matching vMLX probe fields are:

- `mlxIBVDevicesSet`
- `mlxIBVDevicesPath`
- `mlxWorldSize`
- `ibvDeviceMatrixFindings[].code`
- `ibvDeviceMatrixFindings[].message`

## Endpoint Rules

Allowed as tensor data-plane candidates:

- `10.20.0.x`: AdLab-style Thunderbolt loopback.
- `10.10.x.x`: direct Thunderbolt link.

Blocked as tensor data-plane:

- `100.x`: Tailscale/control plane.
- `127.x`, `localhost`, `::1`: local-only loopback.
- `169.254.x.x`: link-local candidate only, not accepted without interface and
  route proof.
- Wi-Fi and generic `192.168.x.x` / `172.16-31.x.x`: unproven until a future
  explicit fabric policy exists.

## UI State Machine

Use one state per node and one aggregate cluster state.

- `off`: user has not enabled discovery.
- `discovering`: scanning or receiving records.
- `candidate`: record exists, no trust/route proof yet.
- `partial`: lower gates pass but at least one required gate is missing.
- `blocked`: a hard safety gate failed.
- `ready`: all non-runtime gates pass for the selected mode.
- `running`: runtime proof is active or a distributed request is in progress.

`ready` must not be shown for tensor parallel mode until JACCL, IBV, collective,
and model proof gates are present. Private LAN, Wi-Fi, link-local, and loopback
addresses are at most `partial` unless a future explicit fabric policy proves
them.

## Controls

Future panel controls:

- Toggle: `Enable node discovery`.
- Toggle: `Allow this Mac to serve as a rank`.
- Button: `Scan`.
- Button: `Run checks`.
- Button: `Copy diagnostics`.
- Button: `Start cluster`.
- Button: `Stop cluster`.
- Manual endpoint entry with explicit `control` vs `data` selector.

`Start cluster` stays disabled unless the selected mode has every required gate.

## Animation Contract

Animations should only visualize proven state transitions:

- Scanning: candidate node pulse.
- Checking: step progress through the fallback ladder.
- Partial: amber edge at the failing gate.
- Blocked: red edge only on the failing route or peer.
- Ready: solid internal-fabric links.
- Running: compact throughput/rank-agreement pulse.

Do not animate unproven nodes as connected.

## Diagnostics Copy

Include:

- redacted node id and device name
- Osaurus version/commit
- vMLX pin
- candidate control addresses
- candidate data-plane addresses
- address classes
- interface names
- route result
- port result
- `librdma` status
- JACCL status
- IBV matrix summary, including world-size and self-slot validation
- collective smoke result
- model shard digest summary
- runtime proof summary when available
- vMLX distributed smoke-tool SHA when the report was generated

Do not include secrets, local full model paths, tokens, private keys, or full
hostnames unless a developer diagnostic bundle is explicitly exported.
