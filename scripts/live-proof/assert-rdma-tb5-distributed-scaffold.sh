#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail=0

pass() { echo "PASS $*"; }
fail_msg() { echo "FAIL $*" >&2; fail=1; }

require_text() {
  local file="$1" pattern="$2" label="$3"
  if rg -U -q "$pattern" "$file"; then
    pass "$label"
  else
    fail_msg "missing $label in ${file#$ROOT/}"
  fi
}

reject_text() {
  local file="$1" pattern="$2" label="$3"
  if rg -U -n "$pattern" "$file"; then
    fail_msg "forbidden $label in ${file#$ROOT/}"
  else
    pass "no $label"
  fi
}

SOURCE="$ROOT/Packages/OsaurusCore/Services/ModelRuntime/DistributedRuntimeReadiness.swift"
TESTS="$ROOT/Packages/OsaurusCore/Tests/Service/DistributedRuntimeReadinessTests.swift"
DOC="$ROOT/docs/RDMA_TB5_TENSOR_PARALLEL_OSAURUS_SCAFFOLD_2026_06_10.md"
SPEC="$ROOT/docs/RDMA_TB5_NODE_DISCOVERY_PRODUCT_SPEC_2026_06_10.md"
NOTES_README="$ROOT/docs/rdma-tb5/README.md"
NOTES_WIRING="$ROOT/docs/rdma-tb5/TEAM_WIRING_NOTES.md"
NOTES_JSON="$ROOT/docs/rdma-tb5/DISCOVERY_JSON_CONTRACT.md"
NOTES_TESTING="$ROOT/docs/rdma-tb5/TESTING_STATUS.md"

for file in "$SOURCE" "$TESTS" "$DOC" "$SPEC" "$NOTES_README" "$NOTES_WIRING" "$NOTES_JSON" "$NOTES_TESTING"; do
  [[ -f "$file" ]] || fail_msg "missing ${file#$ROOT/}"
done

require_text "$SOURCE" 'case thunderboltLoopback' "source classifies Thunderbolt loopbacks"
require_text "$SOURCE" 'case thunderboltDirect' "source classifies direct Thunderbolt links"
require_text "$SOURCE" 'case tailscaleControl' "source marks Tailscale separately"
require_text "$SOURCE" 'Tailscale/control-plane only' "source rejects Tailscale data-plane"
require_text "$SOURCE" 'single_rank_not_tp' "source rejects size-1 TP fallback"
require_text "$SOURCE" 'librdmaLoadable' "source tracks librdma separately"
require_text "$SOURCE" 'jacclAvailable' "source tracks JACCL separately"
require_text "$SOURCE" 'ibvDevicesConfigured' "source tracks IBV device config separately"
require_text "$SOURCE" 'enum DistributedRuntimeState' "source exposes runtime state enum"
require_text "$SOURCE" 'readinessState == \.ready' "source only treats ready state as runnable"
require_text "$SOURCE" 'struct DistributedNodeDiscoveryRecord' "source exposes discovery record contract"
require_text "$SOURCE" 'distributedCapabilityVersion' "source exposes capability version"
require_text "$SOURCE" 'readinessState = "readiness_state"' "source encodes readiness state"
require_text "$SOURCE" 'isRunnable = "is_runnable"' "source encodes runnable state"
require_text "$SOURCE" 'nodeID = "node_id"' "source encodes node id"
require_text "$SOURCE" 'dataPlaneCandidates = "data_plane_candidates"' "source encodes data-plane candidates"
require_text "$SOURCE" 'struct DistributedIBVDeviceMatrix' "source exposes IBV matrix validator"
require_text "$SOURCE" 'ibv_matrix_world_size_mismatch' "source validates IBV world size"
require_text "$SOURCE" 'ibv_matrix_not_square' "source validates IBV square shape"
require_text "$SOURCE" 'ibv_matrix_self_slot_not_empty' "source validates IBV self slot"
require_text "$SOURCE" 'ibv_matrix_peer_device_missing' "source validates IBV peer slots"

require_text "$TESTS" 'tailscale_data_plane_forbidden' "tests cover Tailscale rejection"
require_text "$TESTS" 'single_rank_not_tp' "tests cover size-1 fallback rejection"
require_text "$TESTS" 'jaccl_unavailable' "tests cover JACCL gate"
require_text "$TESTS" 'ibv_devices_missing' "tests cover IBV gate"
require_text "$TESTS" 'readinessState == \.partial' "tests keep unproven addresses partial"
require_text "$TESTS" 'Discovery record is stable JSON' "tests cover discovery record JSON"
require_text "$TESTS" 'node_id' "tests cover snake-case node id"
require_text "$TESTS" 'readiness_state' "tests cover snake-case readiness state"
require_text "$TESTS" 'is_runnable' "tests cover snake-case runnable flag"
require_text "$TESTS" 'IBV matrix accepts null and empty self slots' "tests cover IBV valid shapes"
require_text "$TESTS" 'ibv_matrix_peer_device_missing' "tests cover IBV peer slot failure"

require_text "$DOC" 'No UI or Settings panel changes' "doc keeps UI out of this scaffold"
require_text "$DOC" 'No Osaurus runtime vMLX pin bump in this PR' "doc records no Osaurus runtime vMLX pin bump"
require_text "$DOC" 'Tailscale remains control-plane/SSH only' "doc records Tailscale boundary"
require_text "$DOC" 'docs/rdma-tb5/' "doc links dedicated notes folder"
reject_text "$DOC" 'live-ready' "doc avoids live-ready claim"

require_text "$SPEC" 'Enable node discovery' "spec includes node discovery toggle"
require_text "$SPEC" 'Distributed Inference' "spec includes distributed inference menu"
require_text "$SPEC" 'Scan' "spec includes scan button"
require_text "$SPEC" 'Run checks' "spec includes check button"
require_text "$SPEC" 'Start cluster' "spec includes start button"
require_text "$SPEC" 'Animations should reflect state transitions' "spec covers animations"
require_text "$SPEC" 'Tailscale `100.x`' "spec forbids Tailscale data-plane"
require_text "$SPEC" 'Route check' "spec includes route fallback check"
require_text "$SPEC" 'IBV matrix check' "spec includes IBV fallback check"
require_text "$SPEC" 'Collective smoke' "spec includes collective fallback check"
require_text "$SPEC" 'Runtime proof' "spec includes runtime proof fallback check"
require_text "$SPEC" 'A size-1 fallback never appears as distributed-ready' "spec blocks size-1 false ready"

require_text "$NOTES_README" 'PARTIAL' "notes README records partial status"
require_text "$NOTES_README" 'No Qwen model is distributed-ready' "notes README avoids Qwen ready claim"
require_text "$NOTES_README" 'DISCOVERY_JSON_CONTRACT.md' "notes README links JSON contract"
require_text "$NOTES_WIRING" 'Candidate fields must not be treated as proof fields' "wiring notes separate candidates from proof"
require_text "$NOTES_WIRING" 'DistributedNodeDiscoveryRecord' "wiring notes name source discovery record"
require_text "$NOTES_WIRING" 'readiness\.readiness_state' "wiring notes document JSON state"
require_text "$NOTES_WIRING" 'DistributedIBVDeviceMatrix' "wiring notes document IBV validator"
require_text "$NOTES_WIRING" 'Tailscale/control plane' "wiring notes block Tailscale data-plane"
require_text "$NOTES_JSON" '"node_id"' "JSON contract documents node id"
require_text "$NOTES_JSON" '"readiness_state": "blocked"' "JSON contract documents blocked state"
require_text "$NOTES_JSON" '"readiness_state": "partial"' "JSON contract documents partial state"
require_text "$NOTES_JSON" '"readiness_state": "ready"' "JSON contract documents ready state"
require_text "$NOTES_JSON" 'Tailscale `100.x` is always control-plane only' "JSON contract documents Tailscale boundary"
require_text "$NOTES_TESTING" 'Qwen Status' "testing notes include Qwen status"
require_text "$NOTES_TESTING" 'BLOCKED' "testing notes record blocked Qwen RDMA TP status"
require_text "$NOTES_TESTING" 'jacclAvailable.*false' "testing notes record JACCL unavailable"
require_text "$NOTES_TESTING" 'MLX_IBV_DEVICES' "testing notes record IBV device blocker"

if [[ "$fail" -ne 0 ]]; then
  echo "RDMA/TB5 distributed scaffold guard failed." >&2
  exit 1
fi

echo "RDMA/TB5 distributed scaffold guard passed."
