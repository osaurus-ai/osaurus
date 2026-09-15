#!/usr/bin/env bash
set -euo pipefail

# Normal serial eval invocations, using the app's discovery/capability inventory.
# No model download, name allowlist, sampler override, or RAM-safety bypass.
if [[ $# -lt 2 || $# -gt 3 || ( $# -eq 3 && "$3" != "--representatives" ) ]]; then
  echo "usage: $0 /path/to/osaurus-evals /path/to/new-output-directory [--representatives]" >&2
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
if [[ $# -eq 3 ]]; then
  python3 "$repo_root/scripts/evals/plan-installed-vision.py" "$proof_dir/inventory.json" \
    --out "$proof_dir/coverage-plan.json" --representatives
else
  python3 "$repo_root/scripts/evals/plan-installed-vision.py" "$proof_dir/inventory.json" \
    --out "$proof_dir/coverage-plan.json"
fi
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
PY
result=0
while IFS=$'\t' read -r row_id model_id; do
  echo "Vision qualification: $model_id"
  if ! "$eval_bin" run --suite "$repo_root/Packages/OsaurusEvals/Suites/Vision" \
    --model "$model_id" --no-plugin-bootstrap --transcripts \
    --out "$proof_dir/$row_id.json" > "$proof_dir/$row_id.log" 2>&1; then
    result=1
  fi
  # A CLI exit alone cannot certify a case: an output-write failure or empty
  # suite must not turn this matrix into a false pass.
  if ! python3 - "$proof_dir/$row_id.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
if not path.exists():
    raise SystemExit('Missing runtime report: ' + str(path))
cases = json.loads(path.read_text()).get('cases', [])
if len(cases) != 1 or cases[0].get('id') != 'vision.image-runtime-history' or cases[0].get('outcome') != 'passed':
    raise SystemExit('Runtime image qualification did not pass: ' + str(path))
PY
  then
    result=1
  fi
done < "$proof_dir/coverage-plan.tsv"
python3 - "$proof_dir" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
plan = json.loads((root / 'coverage-plan.json').read_text())
by_model = {row['modelID']: row for row in plan['bundles']}
for line in (root / 'coverage-plan.tsv').read_text().splitlines():
    ordinal, model = line.split('\t', 1)
    path = root / f'{ordinal}.json'
    cases = json.loads(path.read_text()).get('cases', []) if path.exists() else []
    by_model[model]['runtime_status'] = cases[0].get('outcome', 'missing_report') if len(cases) == 1 else 'missing_report'
    by_model[model]['runtime_report'] = str(path)
(root / 'coverage-results.json').write_text(json.dumps(plan, indent=2) + '\n')
PY
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
