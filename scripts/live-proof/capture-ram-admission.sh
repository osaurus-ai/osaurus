#!/usr/bin/env bash
# Read-only evidence for a refusal in an already-installed Osaurus build.
set -euo pipefail
umask 077

usage() {
  cat <<'EOF'
Usage: capture-ram-admission.sh [--pid PID | --host-only]

Run immediately after a failed delegation, before restarting Osaurus.
With no arguments, selects the sole running process named osaurus.
Writes a private temporary directory; does not change settings, clear caches,
restart processes, run a model, or upload anything. Review files before sharing.
The existing spawn_agent error's memory_decision object is still needed when
macOS has not retained admission info logs.
EOF
}

capture_pid=''
host_only=false
case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --host-only) [[ $# == 1 ]] || { usage >&2; exit 64; }; host_only=true ;;
  --pid)
    [[ $# == 2 && "$2" =~ ^[1-9][0-9]*$ ]] || { usage >&2; exit 64; }
    capture_pid="$2"
    ;;
  '') ;;
  *) usage >&2; exit 64 ;;
esac

if [[ "$host_only" == false && -z "$capture_pid" ]]; then
  capture_pid="$(/usr/bin/pgrep -x osaurus || true)"
  if [[ ! "$capture_pid" =~ ^[1-9][0-9]*$ ]]; then
    echo 'Expected one Osaurus process. Select the test app with --pid PID, or use --host-only.' >&2
    exit 64
  fi
fi
if [[ -n "$capture_pid" ]] && ! /bin/ps -p "$capture_pid" -o pid= >/dev/null; then
  echo "Process $capture_pid is not running." >&2
  exit 66
fi

capture_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/osaurus-ram-capture.XXXXXX")"
capture() {
  local capture_name="$1"
  shift
  local capture_status=0
  {
    /bin/date -u '+started_utc=%Y-%m-%dT%H:%M:%SZ'
    "$@" || capture_status=$?
    printf '\ncommand_exit_status=%s\n' "$capture_status"
    /bin/date -u '+finished_utc=%Y-%m-%dT%H:%M:%SZ'
  } >"$capture_dir/$capture_name.txt" 2>&1
}

capture host /usr/sbin/sysctl hw.memsize hw.pagesize vm.swapusage
# Unlike memory_pressure, vm_stat includes Anonymous pages: the internal
# page count needed by ChatResidencyHandoff.reclaimableMemoryBytes.
capture vm-stat /usr/bin/vm_stat
capture memory-pressure /usr/bin/memory_pressure
if [[ -n "$capture_pid" ]]; then
  capture process /bin/ps -p "$capture_pid" -o pid=,lstart=,rss=,comm=
  # The physical-footprint line is the RAM measurement; RSS alone is not.
  capture physical-footprint /usr/bin/vmmap -summary "$capture_pid"
  capture admission-log /usr/bin/log show --last 30m --style compact --info \
    --predicate "processID == $capture_pid AND (category == \"SubagentAdmission\" OR eventMessage CONTAINS \"allocator trim reason=subagent-admission\")"
fi
cat >"$capture_dir/README.txt" <<EOF
Captured UTC: $(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')
PID: ${capture_pid:-none (host only)}
Read-only capture; no model run or memory recovery was initiated.

These host measurements occur AFTER the failure and are not an atomic snapshot.
Use the decision-time [admission] log or the error's memory_decision object for
the exact refusal arithmetic. An empty admission-log does not prove the
recovery path was skipped: macOS may not retain info-level messages.

Include the tested app version/build, whether this was the first child or a
later chat/child without restart, and the complete spawn_agent error JSON.
Preserve both successful and failed runs. Check command_exit_status in each
file; a failed vmmap/log command means that evidence is unavailable.
Review the local files before sharing; they may contain paths and model names.
EOF
printf 'Capture saved locally: %s\n' "$capture_dir"
