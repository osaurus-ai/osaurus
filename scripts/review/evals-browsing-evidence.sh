#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

usage() {
  cat <<'EOF'
Run focused browsing eval evidence with explicit native plugin bootstrap.

Usage:
  scripts/review/evals-browsing-evidence.sh

Environment:
  OUT_DIR=path                       Evidence output directory.
                                     Default: build/evals/pr-evidence/<UTC timestamp>
  MODEL=id                           Model id passed to osaurus-evals. Default: auto.
  OSAURUS_TOOLS_SOURCE=path          Optional osaurus-tools checkout to record as plugin source provenance.
  OSAURUS_BROWSER_PLUGIN_DYLIB=path  Optional browser plugin dylib path to hash in the manifest.
  OSAURUS_BROWSER_PLUGIN_ROOT=path   Optional installed plugin root. Default: ~/.osaurus/Tools/osaurus.browser
  OSAURUS_EVALS_BROWSER_FIXTURE_URL  Optional fixture base URL. If unset, this script starts a local fixture server.
  REQUIRE_BROWSING_PASS=0            Do not fail when all browsing cases skip/fail. Default: 1.
  STRICT=0                           Always exit 0 after writing artifacts. Default exits nonzero on required failures.
  PYTHON_BIN=python3                 Python interpreter used for fixture server and manifest generation.

The script does not install plugins. It only loads already-installed native
plugins through osaurus-evals --bootstrap-plugins and records the source/artifact
identity used for the run.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

cd "$REPO_ROOT"

timestamp="$(date -u +"%Y%m%d-%H%M%S")"
OUT_DIR="${OUT_DIR:-build/evals/pr-evidence/${timestamp}}"
LOG_DIR="${OUT_DIR}/logs"
RESULTS_TSV="${OUT_DIR}/command-results.tsv"
REPORT_PATH="${OUT_DIR}/browsing-report.json"
MODEL="${MODEL:-auto}"
STRICT="${STRICT:-1}"
REQUIRE_BROWSING_PASS="${REQUIRE_BROWSING_PASS:-1}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
BROWSER_PLUGIN_ROOT="${OSAURUS_BROWSER_PLUGIN_ROOT:-${HOME}/.osaurus/Tools/osaurus.browser}"

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  echo "error: ${PYTHON_BIN} is required to run browsing evidence." >&2
  exit 1
fi

if [[ -z "${OSAURUS_TOOLS_SOURCE:-}" ]]; then
  candidate_tools_source="$(cd "${REPO_ROOT}/../.." && pwd)/osaurus-tools"
  if [[ -d "${candidate_tools_source}/.git" ]]; then
    OSAURUS_TOOLS_SOURCE="${candidate_tools_source}"
  fi
fi

mkdir -p "$LOG_DIR"
printf "name\tcommand\tlog\texit_code\tduration_ms\n" > "$RESULTS_TSV"

fail=0
fixture_server_pid=""

cleanup() {
  if [[ -n "$fixture_server_pid" ]] && kill -0 "$fixture_server_pid" >/dev/null 2>&1; then
    kill "$fixture_server_pid" >/dev/null 2>&1 || true
    wait "$fixture_server_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

quote_cmd() {
  local out=""
  local arg
  for arg in "$@"; do
    printf -v out '%s%q ' "$out" "$arg"
  done
  printf '%s' "${out% }"
}

now_ms() {
  "$PYTHON_BIN" -c 'import time; print(int(time.time() * 1000))'
}

run_step() {
  local name="$1"
  shift
  local log="${LOG_DIR}/${name}.log"
  local rel_log="logs/${name}.log"
  local cmd_display
  cmd_display="$(quote_cmd "$@")"
  local start end duration rc
  start="$(now_ms)"
  echo "==> ${name}: ${cmd_display}"
  set +e
  "$@" >"$log" 2>&1
  rc=$?
  set -e
  end="$(now_ms)"
  duration=$((end - start))
  printf "%s\t%s\t%s\t%d\t%d\n" "$name" "$cmd_display" "$rel_log" "$rc" "$duration" >> "$RESULTS_TSV"
  if [[ "$rc" -eq 0 ]]; then
    echo "PASS ${name} (${duration}ms)"
  else
    echo "FAIL ${name} (${duration}ms); see ${log}" >&2
    fail=1
  fi
}

start_fixture_server_if_needed() {
  if [[ -n "${OSAURUS_EVALS_BROWSER_FIXTURE_URL:-}" ]]; then
    echo "Using caller-provided fixture URL: ${OSAURUS_EVALS_BROWSER_FIXTURE_URL}"
    return
  fi

  local fixture_dir="${OUT_DIR}/fixtures/browser-site"
  local port_file="${OUT_DIR}/fixture-port.txt"
  mkdir -p "$fixture_dir"
  cat > "${fixture_dir}/inspect.html" <<'HTML'
<!doctype html>
<meta charset="utf-8">
<title>Browsing Eval Inspect</title>
<main>
  <h1>Osaurus Browse Eval</h1>
  <p id="fact">Cobalt delta 47</p>
  <p id="owner">Owner Mira</p>
  <p id="status">Status ready</p>
</main>
HTML
  cat > "${fixture_dir}/form.html" <<'HTML'
<!doctype html>
<meta charset="utf-8">
<title>Browsing Eval Form</title>
<form id="form">
  <label>Codename <input id="code" name="code" autocomplete="off"></label>
  <button id="submit" type="submit">Submit</button>
</form>
<output id="result"></output>
<script>
document.getElementById("form").addEventListener("submit", function(event) {
  event.preventDefault();
  document.getElementById("result").textContent =
    "Submitted: " + document.getElementById("code").value;
});
</script>
HTML
  cat > "${fixture_dir}/dialog.html" <<'HTML'
<!doctype html>
<meta charset="utf-8">
<title>Browsing Eval Dialog</title>
<button id="go">Trigger dialog</button>
<p id="result">Pending</p>
<script>
document.getElementById("go").addEventListener("click", function() {
  alert("Dialog code larch-19");
  document.getElementById("result").textContent = "Dialog accepted larch-19";
});
</script>
HTML

  "$PYTHON_BIN" - "$fixture_dir" "$port_file" <<'PY' &
import functools
import http.server
import pathlib
import socketserver
import sys

directory = pathlib.Path(sys.argv[1]).resolve()
port_file = pathlib.Path(sys.argv[2])

class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        return

handler = functools.partial(QuietHandler, directory=str(directory))
with socketserver.ThreadingTCPServer(("127.0.0.1", 0), handler) as httpd:
    port = httpd.server_address[1]
    port_file.write_text(str(port), encoding="utf-8")
    httpd.serve_forever()
PY
  fixture_server_pid=$!

  for _ in {1..100}; do
    if [[ -s "$port_file" ]]; then
      break
    fi
    if ! kill -0 "$fixture_server_pid" >/dev/null 2>&1; then
      echo "error: fixture server exited before writing ${port_file}" >&2
      exit 1
    fi
    sleep 0.1
  done
  if [[ ! -s "$port_file" ]]; then
    echo "error: fixture server did not start within timeout" >&2
    exit 1
  fi

  export OSAURUS_EVALS_BROWSER_FIXTURE_URL="http://127.0.0.1:$(cat "$port_file")"
  echo "Started fixture server: ${OSAURUS_EVALS_BROWSER_FIXTURE_URL}"
}

start_fixture_server_if_needed

run_step evals-browsing \
  env OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1 \
    OSAURUS_EVALS_BROWSER_FIXTURE_URL="${OSAURUS_EVALS_BROWSER_FIXTURE_URL}" \
    swift run --package-path Packages/OsaurusEvals osaurus-evals run \
      --suite Packages/OsaurusEvals/Suites/Browsing \
      --model "$MODEL" \
      --bootstrap-plugins \
      --transcripts \
      --out "$REPORT_PATH"

set +e
"$PYTHON_BIN" - "$OUT_DIR" "$RESULTS_TSV" "$fail" "$MODEL" \
  "${OSAURUS_EVALS_BROWSER_FIXTURE_URL}" "${OSAURUS_TOOLS_SOURCE:-}" \
  "${OSAURUS_BROWSER_PLUGIN_DYLIB:-}" "$BROWSER_PLUGIN_ROOT" "$REPORT_PATH" \
  "$REQUIRE_BROWSING_PASS" <<'PY'
import csv
import hashlib
import json
import pathlib
import subprocess
import sys
from datetime import datetime, timezone

out_dir = pathlib.Path(sys.argv[1])
tsv = pathlib.Path(sys.argv[2])
failed = sys.argv[3] != "0"
model = sys.argv[4]
fixture_url = sys.argv[5]
tools_source = sys.argv[6]
explicit_dylib = sys.argv[7]
plugin_root = pathlib.Path(sys.argv[8]).expanduser()
report_path = pathlib.Path(sys.argv[9])
require_passed = sys.argv[10] != "0"

steps = []
with tsv.open(newline="", encoding="utf-8") as f:
    for row in csv.DictReader(f, delimiter="\t"):
        steps.append(
            {
                "name": row["name"],
                "command": row["command"],
                "log": row["log"],
                "exit_code": int(row["exit_code"]),
                "duration_ms": int(row["duration_ms"]),
            }
        )

def git_info(path):
    root = pathlib.Path(path)
    if not root.exists():
        return {"path": str(root), "exists": False}

    def git(args):
        try:
            return subprocess.check_output(
                ["git", "-C", str(root), *args],
                text=True,
                stderr=subprocess.DEVNULL,
            ).strip()
        except Exception:
            return ""

    return {
        "path": str(root),
        "exists": True,
        "branch": git(["rev-parse", "--abbrev-ref", "HEAD"]),
        "head": git(["rev-parse", "HEAD"]),
        "dirty_status_lines": git(["status", "--short"]).splitlines(),
    }

def sha256(path):
    h = hashlib.sha256()
    with pathlib.Path(path).open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

def dylib_record(path):
    p = pathlib.Path(path).expanduser()
    record = {"path": str(p), "exists": p.exists()}
    if p.exists() and p.is_file():
        record["sha256"] = sha256(p)
        record["size_bytes"] = p.stat().st_size
    return record

dylibs = []
if explicit_dylib:
    dylibs.append(dylib_record(explicit_dylib))
if plugin_root.exists():
    for p in sorted(plugin_root.rglob("*.dylib")):
        text = str(p)
        if explicit_dylib and pathlib.Path(explicit_dylib).expanduser() == p:
            continue
        dylibs.append(dylib_record(text))

report = None
cases = []
if report_path.exists():
    try:
        report = json.loads(report_path.read_text(encoding="utf-8"))
        cases = report.get("cases", [])
    except Exception as exc:
        cases = [{"id": "(report decode)", "outcome": "errored", "notes": [str(exc)]}]

case_outcomes = {}
for case in cases:
    outcome = case.get("outcome", "unknown")
    case_outcomes[outcome] = case_outcomes.get(outcome, 0) + 1
passed = case_outcomes.get("passed", 0)
if require_passed and passed == 0:
    failed = True

proof_status = "passed" if passed > 0 else "no_passed_cases"
if case_outcomes.get("failed", 0) or case_outcomes.get("errored", 0):
    proof_status = "failed_or_errored"
elif case_outcomes.get("skipped", 0) and passed == 0:
    proof_status = "skipped"

app_info = git_info(pathlib.Path.cwd())
tools_info = git_info(tools_source) if tools_source else {"path": "", "exists": False}

try:
    report_ref = str(report_path.relative_to(out_dir))
except ValueError:
    report_ref = str(report_path)

manifest = {
    "schema": 1,
    "kind": "browsing_eval_pr_evidence",
    "created_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "result": "failed" if failed else "passed",
    "proof_status": proof_status,
    "model": model,
    "fixture_url": fixture_url,
    "app": app_info,
    "osaurus_tools_source": tools_info,
    "browser_plugin": {
        "plugin_id": "osaurus.browser",
        "installed_root": str(plugin_root),
        "explicit_dylib": explicit_dylib,
        "dylibs": dylibs,
    },
    "commands": steps,
    "report": report_ref if report_path.exists() else str(report_path),
    "case_outcomes": case_outcomes,
    "cases": [
        {
            "id": case.get("id"),
            "outcome": case.get("outcome"),
            "notes": case.get("notes", []),
            "tool_usage": case.get("toolUsage"),
        }
        for case in cases
    ],
    "required": {
        "native_plugin_bootstrap": "--bootstrap-plugins",
        "source_or_artifact_provenance": bool(
            tools_info.get("head") or any(d.get("sha256") for d in dylibs)
        ),
        "require_passed_case": require_passed,
    },
    "artifacts": {
        "summary": "summary.md",
        "command_results": "command-results.tsv",
        "logs": "logs/",
    },
}

(out_dir / "manifest.json").write_text(
    json.dumps(manifest, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)

lines = [
    "# Browsing Eval Evidence",
    "",
    f"- Result: **{manifest['result']}**",
    f"- Proof status: `{proof_status}`",
    f"- Model: `{model}`",
    f"- App head: `{app_info.get('head', '')}`",
    f"- Tools source head: `{tools_info.get('head', '')}`",
    f"- Fixture URL: `{fixture_url}`",
    f"- Browser dylibs hashed: `{sum(1 for d in dylibs if d.get('sha256'))}`",
    "",
    "| Step | Exit | Duration | Log |",
    "| --- | ---: | ---: | --- |",
]
for step in steps:
    seconds = step["duration_ms"] / 1000.0
    lines.append(
        f"| `{step['name']}` | {step['exit_code']} | {seconds:.2f}s | `{step['log']}` |"
    )
lines.extend(["", "## Cases", ""])
if cases:
    lines.extend(["| Case | Outcome | Notes |", "| --- | --- | --- |"])
    for case in cases:
        notes = "; ".join(str(n).replace("\n", " ") for n in case.get("notes", []))
        lines.append(f"| `{case.get('id')}` | `{case.get('outcome')}` | {notes} |")
else:
    lines.append("No case report was written.")
lines.extend(
    [
        "",
        "Current-behavior scope: this evidence does not assert unsafe URL blocking, redirect/private-target blocking, redaction, or prompt-injection resistance.",
        "Generated artifacts live under `build/` and are intentionally ignored by git.",
        "",
    ]
)
(out_dir / "summary.md").write_text("\n".join(lines), encoding="utf-8")

sys.exit(1 if failed else 0)
PY
post_rc=$?
set -e
if [[ "$post_rc" -ne 0 ]]; then
  fail=1
fi

echo "Evidence artifacts: ${OUT_DIR}"

if [[ "$fail" -ne 0 && "$STRICT" != "0" ]]; then
  exit 1
fi
exit 0
