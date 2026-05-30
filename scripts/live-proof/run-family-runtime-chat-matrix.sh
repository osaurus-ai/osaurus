#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST="$ROOT/scripts/live-proof/family-runtime-chat-matrix.json"
HARNESS="$ROOT/scripts/live-proof/run-local-family-multiturn-tool-cache-proof.py"

BASE_URL="${OSAURUS_BASE_URL:-http://127.0.0.1:1337}"
ARTIFACT_ROOT="${ARTIFACT_ROOT:-/tmp/osaurus-family-runtime-chat-matrix-$(date +%Y%m%d-%H%M%S)}"
FAMILY_FILTER="${FAMILY_FILTER:-}"
MODEL_FILTER="${MODEL_FILTER:-}"
MAX_TOKENS="${MAX_TOKENS:-384}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-1200}"
SETTLE_SECONDS="${SETTLE_SECONDS:-2}"
DRY_RUN="${DRY_RUN:-0}"

for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN=1
      ;;
    --help|-h)
      cat <<'EOF'
usage: run-family-runtime-chat-matrix.sh [--dry-run] [KEY=value ...]

Environment/KEY options:
  OSAURUS_BASE_URL=http://127.0.0.1:1337
  ARTIFACT_ROOT=/tmp/osaurus-family-runtime-chat-matrix-...
  FAMILY_FILTER=zaya|ling|nemotron-omni|dsv4|qwen|gemma|hy3
  MODEL_FILTER=<model id or row id>
  MAX_TOKENS=384
  TIMEOUT_SECONDS=1200
  SETTLE_SECONDS=2
  DRY_RUN=1
EOF
      exit 0
      ;;
    OSAURUS_BASE_URL=*)
      BASE_URL="${arg#*=}"
      ;;
    ARTIFACT_ROOT=*)
      ARTIFACT_ROOT="${arg#*=}"
      ;;
    FAMILY_FILTER=*)
      FAMILY_FILTER="${arg#*=}"
      ;;
    MODEL_FILTER=*)
      MODEL_FILTER="${arg#*=}"
      ;;
    MAX_TOKENS=*)
      MAX_TOKENS="${arg#*=}"
      ;;
    TIMEOUT_SECONDS=*)
      TIMEOUT_SECONDS="${arg#*=}"
      ;;
    SETTLE_SECONDS=*)
      SETTLE_SECONDS="${arg#*=}"
      ;;
    DRY_RUN=*)
      DRY_RUN="${arg#*=}"
      ;;
    *)
      echo "unknown argument: $arg" >&2
      echo "use --help for usage" >&2
      exit 64
      ;;
  esac
done

if [[ ! -f "$MANIFEST" ]]; then
  echo "missing manifest: $MANIFEST" >&2
  exit 66
fi

if [[ ! -x "$HARNESS" ]]; then
  echo "missing executable harness: $HARNESS" >&2
  exit 66
fi

mkdir -p "$ARTIFACT_ROOT"

python3 - "$MANIFEST" "$FAMILY_FILTER" "$MODEL_FILTER" >"$ARTIFACT_ROOT/selected.tsv" <<'PY'
import json
import sys

manifest_path, family_filter, model_filter = sys.argv[1:4]
rows = json.load(open(manifest_path, encoding="utf-8"))
for row in rows:
    if family_filter and row.get("family") != family_filter:
        continue
    if model_filter and row.get("model") != model_filter and row.get("id") != model_filter:
        continue
    print("\t".join([
        row.get("id", ""),
        row.get("model", ""),
        row.get("family", ""),
        row.get("topology", ""),
        row.get("priority", ""),
        ",".join(row.get("required_cache_evidence") or []),
    ]))
PY

if [[ ! -s "$ARTIFACT_ROOT/selected.tsv" ]]; then
  echo "no rows selected; FAMILY_FILTER=$FAMILY_FILTER MODEL_FILTER=$MODEL_FILTER" >&2
  exit 64
fi

echo "base_url=$BASE_URL"
echo "artifact_root=$ARTIFACT_ROOT"
echo "selected_rows:"
cat "$ARTIFACT_ROOT/selected.tsv"

if [[ "$DRY_RUN" == "1" ]]; then
  exit 0
fi

curl -fsS --max-time 10 "$BASE_URL/health" >"$ARTIFACT_ROOT/health-before.json"
curl -fsS --max-time 20 "$BASE_URL/admin/cache-stats" >"$ARTIFACT_ROOT/cache-before.json" || true

fail=0
while IFS=$'\t' read -r row_id model family topology priority required_cache_evidence; do
  row_root="$ARTIFACT_ROOT/$row_id"
  mkdir -p "$row_root"
  {
    echo "row_id=$row_id"
    echo "model=$model"
    echo "family=$family"
    echo "topology=$topology"
    echo "priority=$priority"
    echo "required_cache_evidence=$required_cache_evidence"
  } >"$row_root/row.txt"

  echo "--- running $row_id ($model) ---"
  cache_args=()
  IFS=',' read -r -a cache_items <<<"$required_cache_evidence"
  for item in "${cache_items[@]}"; do
    if [[ -n "$item" ]]; then
      cache_args+=(--required-cache-evidence "$item")
    fi
  done
  if "$HARNESS" \
    --base-url "$BASE_URL" \
    --artifact-root "$row_root" \
    --model "$model" \
    --max-tokens "$MAX_TOKENS" \
    --timeout "$TIMEOUT_SECONDS" \
    --settle-seconds "$SETTLE_SECONDS" \
    "${cache_args[@]}"; then
    echo "PASS $row_id" | tee "$row_root/status.txt"
  else
    echo "FAIL $row_id" | tee "$row_root/status.txt"
    fail=1
  fi
done <"$ARTIFACT_ROOT/selected.tsv"

curl -fsS --max-time 10 "$BASE_URL/health" >"$ARTIFACT_ROOT/health-after.json" || true
curl -fsS --max-time 20 "$BASE_URL/admin/cache-stats" >"$ARTIFACT_ROOT/cache-after.json" || true

python3 - "$ARTIFACT_ROOT" >"$ARTIFACT_ROOT/SUMMARY.json" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
rows = []
for row_dir in sorted(p for p in root.iterdir() if p.is_dir()):
    status = row_dir.joinpath("status.txt").read_text(encoding="utf-8").strip() if row_dir.joinpath("status.txt").exists() else "UNKNOWN"
    summaries = sorted(row_dir.glob("*_summary.json"))
    row = {"id": row_dir.name, "status": status, "summary_files": [str(p) for p in summaries]}
    if summaries:
        try:
            payload = json.loads(summaries[0].read_text(encoding="utf-8"))
            row["passed"] = payload.get("passed")
            row["failed_checks"] = payload.get("failed_checks", [])
            row["cache_delta"] = payload.get("cache_delta", {})
            row["turns"] = payload.get("turns", {})
        except Exception as exc:
            row["parse_error"] = repr(exc)
    rows.append(row)
print(json.dumps({"artifact_root": str(root), "passed": all(r.get("passed") is True for r in rows), "rows": rows}, indent=2, sort_keys=True))
PY

cat "$ARTIFACT_ROOT/SUMMARY.json"
exit "$fail"
