#!/usr/bin/env bash
set -euo pipefail

# Normal serial eval invocations, using the app's discovery/capability inventory.
# No model download, name allowlist, sampler override, or RAM-safety bypass.
if [[ $# -ne 2 ]]; then
  echo "usage: $0 /path/to/osaurus-evals /path/to/new-output-directory" >&2
  exit 2
fi
eval_bin="$1"
proof_dir="$2"
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
if [[ -e "$proof_dir" ]]; then
  echo "output directory already exists; retain old attempts and choose a new directory" >&2
  exit 2
fi
mkdir -p "$proof_dir"
"$eval_bin" vision-inventory --out "$proof_dir/inventory.json" > "$proof_dir/inventory.log" 2>&1
python3 - "$proof_dir" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
rows = json.loads((root / 'inventory.json').read_text())
selected = [row for row in rows if row['supportsImage']]
rejected = [row for row in rows if row['declaresVision'] and not row['supportsImage']]
(root / 'unqualified-declarations.json').write_text(json.dumps(rejected, indent=2))
if not selected:
    raise SystemExit('No installed image-capable bundles discovered; this is not a passing matrix.')
for row in selected:
    if any(c in row['modelID'] for c in '\r\n\t'):
        raise SystemExit('Model identifier contains a control delimiter')
(root / 'models.tsv').write_text(''.join(f"{i:03d}\t{row['modelID']}\n" for i, row in enumerate(selected)))
PY
result=0
while IFS=$'\t' read -r row_id model_id; do
  echo "Vision qualification: $model_id"
  if ! "$eval_bin" run --suite "$repo_root/Packages/OsaurusEvals/Suites/Vision" \
    --model "$model_id" --no-plugin-bootstrap --transcripts \
    --out "$proof_dir/$row_id.json" > "$proof_dir/$row_id.log" 2>&1; then
    result=1
  fi
done < "$proof_dir/models.tsv"
python3 - "$proof_dir" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
rejected = json.loads((root / 'unqualified-declarations.json').read_text())
print(f'{len(rejected)} declared-vision bundles rejected by installed evidence; see unqualified-declarations.json.')
PY
# A fully qualified inventory cannot silently omit declared-but-broken bundles.
if ! python3 - "$proof_dir/unqualified-declarations.json" <<'PY'
import json, sys
raise SystemExit(1 if json.load(open(sys.argv[1])) else 0)
PY
then
  result=1
fi
exit "$result"
