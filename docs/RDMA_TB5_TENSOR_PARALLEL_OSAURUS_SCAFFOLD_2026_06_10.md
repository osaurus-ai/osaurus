# RDMA/TB5 Tensor Parallel Osaurus Scaffold

Updated: 2026-06-10

## Purpose

This PR starts the Osaurus side of RDMA/TB5 tensor-parallel integration without
turning on cluster execution or adding UI. The immediate scope is host policy,
readiness vocabulary, and proof gates that can later consume vMLX distributed
probe output.

## Boundary

- Osaurus owns opt-in policy, readiness reporting, host identity, future UI, and
  API health surfaces.
- vMLX owns distributed group initialization, JACCL/RDMA collectives, tensor
  sharding plans, model execution, token authority, cache topology, and live
  generation proof.
- AdLab Python/Qwen/MiMo work is provenance. The product path is Swift engine
  code and Swift proof artifacts.

## Current Source Scaffold

- `DistributedRuntimeReadiness` classifies tensor data-plane endpoints and
  records readiness findings.
- `DistributedRuntimeState` separates `blocked`, `partial`, and `ready`; only
  `ready` is runnable.
- `DistributedNodeDiscoveryRecord` provides the first Codable handoff shape for
  future node discovery and panel wiring, encoded as stable snake_case JSON.
- `10.20.0.x` Thunderbolt loopbacks and `10.10.x.x` direct Thunderbolt links are
  accepted as tensor data-plane addresses.
- `100.x` Tailscale addresses are rejected for tensor data-plane use.
  Tailscale remains control-plane/SSH only.
- Size-1 distributed fallback is explicitly rejected as tensor-parallel proof.
- `librdma`, JACCL availability, and `MLX_IBV_DEVICES` configuration are tracked
  as separate gates.
- `DistributedIBVDeviceMatrix` validates `MLX_IBV_DEVICES` JSON shape before a
  future launch path can treat IBV as configured.
- Team-facing implementation notes live in `docs/rdma-tb5/`.

## Not Included Yet

- No UI or Settings panel changes.
- No automatic peer discovery or background cluster joining.
- No Osaurus runtime switch to distributed execution.
- No Osaurus runtime vMLX pin bump in this PR.
- No claim that Qwen, MiMo, JANG, MXFP, VL, audio, or video rows have live
  readiness proof.
- No node-discovery UI yet. See
  `docs/RDMA_TB5_NODE_DISCOVERY_PRODUCT_SPEC_2026_06_10.md` for the team-facing
  discovery, menu, button, animation, and fallback-check spec.

## Next Steps

1. Consume vMLX `DistributedProbe --json` from vMLX main
   `fcb69484105683c5a5032b97420d00e75d3a914e` once the runtime lane is ready
   to pin and ingest distributed probe output.
2. Add route-table evidence and real RDMA device enumeration.
3. Add package-owned proof ingestion for worker liveness, rank agreement,
   decode token/s, token authority, and architecture-specific cache evidence.
4. Add UI only after the non-UI readiness state is backed by live proof.
