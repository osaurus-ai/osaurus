# RDMA/TB5 Distributed Inference Notes

Updated: 2026-06-10

This folder is the team-facing planning and proof surface for RDMA/TB5
distributed inference in Osaurus.

## Current Status

`PARTIAL`: Osaurus now has a readiness vocabulary, product spec, and vMLX
smoke-tool reference for RDMA/TB5 discovery, but distributed execution is not
enabled.

What this PR provides:

- Endpoint classification for tensor data-plane addresses.
- Hard rejection of Tailscale `100.x` as tensor data-plane.
- Size-1 fallback rejection as tensor-parallel proof.
- Separate readiness gates for `librdma`, JACCL, and `MLX_IBV_DEVICES`.
- Product spec for node discovery, fallback checks, menu/buttons, animations,
  diagnostics copy, and acceptance criteria.
- Current vMLX smoke-tool SHA: `fcb69484105683c5a5032b97420d00e75d3a914e`.

What is not claimed:

- No Qwen model is distributed-ready from this PR.
- No RDMA collective has passed from Osaurus.
- No Osaurus runtime vMLX pin is changed by this scaffold PR.
- No UI is added yet.
- No automatic peer discovery is enabled yet.

## Documents

- `TEAM_WIRING_NOTES.md`: fields, state machine, endpoints, UI data contract,
  and fallback check ladder the app team should wire against.
- `DISCOVERY_JSON_CONTRACT.md`: concrete blocked, partial, and ready JSON
  examples for panel/API wiring.
- `TESTING_STATUS.md`: current smoke/proof matrix and blockers.
- `../RDMA_TB5_NODE_DISCOVERY_PRODUCT_SPEC_2026_06_10.md`: product behavior
  and UX spec.
- `../RDMA_TB5_TENSOR_PARALLEL_OSAURUS_SCAFFOLD_2026_06_10.md`: source
  scaffold boundary.

## Release Rule

Do not expose a user-facing "Ready" distributed state until the selected model
has all required gates:

1. internal Thunderbolt/RDMA data-plane route
2. trusted peer identity
3. compatible Osaurus and vMLX distributed capability version
4. JACCL available
5. valid `MLX_IBV_DEVICES`
6. collective smoke pass
7. model shard/hash agreement
8. model-family runtime proof with token/s and cache evidence

Until then, show `PARTIAL` or `BLOCKED` with the exact failing gate.
