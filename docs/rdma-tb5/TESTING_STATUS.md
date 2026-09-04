# RDMA/TB5 Testing Status

Updated: 2026-06-10

## Summary

Current status is `PARTIAL / BLOCKED FOR REAL RDMA TP`.

The Osaurus scaffold is source-tested. The local vMLX probes are close enough
to smoke the readiness boundaries, but real Qwen tensor-parallel execution is
blocked because the current local vMLX build reports JACCL unavailable for this
package build. `MLX_IBV_DEVICES` JSON shape is now source/probe-validated, but
there is not yet a real multi-Mac RDMA device matrix for Qwen TP.

## Osaurus Checks

Passed:

```sh
scripts/live-proof/assert-rdma-tb5-distributed-scaffold.sh
```

Passed:

```sh
OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 \
OSAURUS_TEST_ROOT=/tmp/osaurus-rdma-tb5-test \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcrun swift test --package-path Packages/OsaurusCore \
  --filter DistributedRuntimeReadinessTests --jobs 1
```

Result:

- Built OsaurusCore.
- Ran 10 distributed readiness tests.
- Passed Tailscale rejection, size-1 fallback rejection, Thunderbolt address
  acceptance, and separate `librdma` / JACCL / IBV gates.
- Passed warning-only readiness behavior: unproven private/Wi-Fi-style
  addresses are `partial`, not runnable.
- Passed stable JSON encoding/decoding for `DistributedNodeDiscoveryRecord`.
- Passed wire-key assertions for `node_id`, `vmlx_pin`, `readiness_state`,
  `is_runnable`, and endpoint `address_class`.
- Passed `DistributedIBVDeviceMatrix` validation for `null` and empty-string
  self slots, world-size mismatch, non-square rows, non-empty self slots, and
  missing peer device names.

## vMLX Main Smoke Evidence

These checks were run from clean vMLX main checkout
`/tmp/vmlx-rdma-tb5-main`.

Current vMLX main smoke-tool SHA:

```text
fcb69484105683c5a5032b97420d00e75d3a914e
```

Passed:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter MLXDistributedCoreTests --jobs 1
```

Result:

- Built the local distributed core tests.
- Ran 8 selected tests.
- Passed Thunderbolt address acceptance, Tailscale rejection, private-address
  warning, and loopback-not-proof rules.
- Passed `IBVDeviceMatrix` validation for `null` and empty self slots, malformed
  matrix shapes, non-empty self slots, and missing peer devices.

Passed:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift build --product DistributedProbe
```

Passed:

```sh
TMP=$(mktemp /tmp/vmlx-ibv-valid.XXXXXX.json)
printf '[["","mlx0"],["mlx0",""]]\n' > "$TMP"
.build/debug/DistributedProbe --json \
  --modes tp \
  --world-size 2 \
  --ibv-devices-json "$TMP" \
  --data-plane-addresses 10.20.0.1:29500,10.20.0.2:29500 \
  --models qwen36-smoke
```

Observed:

- `mlxIBVDevicesSet`: `true`
- `mlxWorldSize`: `2`
- `ibv_matrix_valid`

Passed negative control:

```sh
TMP=$(mktemp /tmp/vmlx-ibv-invalid.XXXXXX.json)
printf '[[null,""],["mlx0",null]]\n' > "$TMP"
.build/debug/DistributedProbe --json \
  --modes tp \
  --world-size 2 \
  --ibv-devices-json "$TMP" \
  --data-plane-addresses 100.93.216.67:29500 \
  --models qwen36-smoke
```

Observed:

- `ibv_matrix_peer_device_missing`
- Tailscale `100.x` remains blocked as tensor data-plane.

Passed:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift build --product TPRankWorker
```

Passed:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift build --product DistributedPeerSmoke

.build/debug/DistributedPeerSmoke \
  --self-test \
  --modes replica,pp \
  --models qwen36-smoke
```

Result:

- loopback self-test handshake passed
- encrypted transport: `true`
- peer identity pinned: `true`
- advertised `dist.models`: `qwen36-smoke`
- advertised `dist.modes`: `pp,replica`
- `rdmaReady`: `false`
- `rdmaBlockedReason`: `JACCL backend is unavailable in this package build`

`TPRankWorker` currently reports an expected configuration error when launched
without a model:

```text
ERROR: TP_MODEL_PATH not set
```

That is a CLI/configuration gate, not a Qwen proof.

## Current Live Readiness Snapshot

Command:

```sh
.build/debug/DistributedProbe --json \
  --modes tp \
  --data-plane-addresses 10.20.0.1:29500,10.20.0.2:29500 \
  --models qwen36-smoke
```

Observed:

- `librdmaLoadable`: `true`
- `jacclAvailable`: `false`
- `anyDistributedBackendAvailable`: `false`
- `mlxIBVDevicesSet`: `false`
- Thunderbolt Bridge candidate exists as `bridge0`.
- `10.20.0.1` and `10.20.0.2` classify as accepted Thunderbolt loopback
  tensor data-plane candidates.
- TP TXT preview is not emitted because JACCL is unavailable and RDMA devices
  are not configured.

Blocked findings:

- `Requested tp/wired advertisement, but JACCL is unavailable.`
- `Requested tp/wired advertisement, but RDMA devices are not configured.`

Negative-control command:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift run DistributedProbe --json \
  --modes tp \
  --data-plane-addresses 10.20.0.1:29500,100.93.216.67:29500 \
  --models qwen36-smoke
```

Observed:

- `10.20.0.1` accepted as Thunderbolt data-plane candidate.
- `100.93.216.67` rejected as Tailscale/control-plane only.
- Wired TP remains blocked.

`DistributedModelInventory` also builds from vMLX main. A smoke invocation with
`--json` was rejected because the tool already emits JSON by default and does
not support that flag; that invocation is recorded as command misuse, not a
runtime pass.

## Qwen Status

`BLOCKED` for real RDMA tensor parallel proof.

Current validated Qwen-adjacent gates:

- Qwen smoke can be named in the probe model hash/id field.
- vMLX `TPRankWorker` builds, pulling in `MLXLLM`, tokenizers,
  `MLXDistributedTP`, and `MLXDistributedJACCL`.
- Osaurus/vMLX address policy blocks Tailscale and size-1 false positives.

Missing before any Qwen distributed-ready claim:

- real JACCL backend availability
- real multi-Mac `MLX_IBV_DEVICES`
- strict rank 0/rank 1 group init with size 2 or higher
- collective smoke
- Qwen sharding plan execution
- coherent multi-turn Qwen generation
- token/s and cache evidence
- architecture-specific cache proof for Qwen hybrid state where applicable
- Osaurus consumption of the vMLX probe/discovery JSON in live app state

## Next Tests

1. Add generated matrix diagnostics and RDMA device enumeration.
2. Add child-process strict JACCL init smoke so native backend failures do not
   crash Osaurus.
3. Run two-rank collective smoke over real Thunderbolt/RDMA.
4. Run a tiny synthetic TP linear parity test.
5. Run real Qwen TP proof only after the lower gates pass.
