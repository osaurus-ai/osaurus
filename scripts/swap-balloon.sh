#!/bin/bash
#
# swap-balloon.sh — push macOS into REAL swap for end-to-end testing of the
# osaurus swap-pressure banner.
#
#   ./scripts/swap-balloon.sh 30        # allocate+touch ~30 GB, hold until Ctrl-C
#
# For the deterministic DESIGN/QA loop (no actual thrashing), use the
# emulation switch instead — the banner shows "(simulated)":
#   launch env:  OSAURUS_SWAP_EMULATE=elevated  (or critical)
#   or live:     echo critical > ~/.osaurus/debug/swap-emulate
#                rm ~/.osaurus/debug/swap-emulate   # end simulation
#   (dev/test roots: use $OSAURUS_TEST_ROOT/debug/swap-emulate)
#
# Watch the real numbers while ballooning:  sysctl vm.swapusage
#
# LIFECYCLE CONTRACT (a proof run once inherited ~68 GB of orphaned balloons
# that every naive pgrep missed, silently contaminating everything measured
# in that window — hence the belt-and-suspenders below):
#   - refuses to start while ANY prior balloon is alive (marker pgrep OR a
#     stale pidfile pointing at a live process);
#   - records the child PID in /tmp/osaurus-swap-balloon.pids/<pid>;
#   - traps EXIT/INT/TERM/HUP: kills the child, sweeps every marker process,
#     verifies ZERO remain, prints a post-cleanup capture, and exits nonzero
#     if the sweep failed — treat that as a failed proof run;
#   - the child self-terminates if this wrapper dies uncleanly (SIGKILL,
#     kernel jetsam): it polls getppid() and exits when reparented, so a
#     dead wrapper can never leave a resident orphan;
#   - captures ps/footprint/memory-pressure/swap baselines before and after.
#
set -euo pipefail
GB="${1:-16}"
if ! [[ "$GB" =~ ^[0-9]+$ ]] || [ "$GB" -lt 1 ] || [ "$GB" -gt 200 ]; then
  echo "usage: $0 <gigabytes 1-200>" >&2; exit 2
fi

MARKER="swap-balloon-marker"
PIDDIR="/tmp/osaurus-swap-balloon.pids"
mkdir -p "$PIDDIR"

capture() {
  echo "--- $1 capture $(date '+%H:%M:%S') ---"
  sysctl vm.swapusage
  memory_pressure -Q 2>/dev/null | grep -i percentage || true
  # Balloons run as Python with the marker in argv — match the MARKER, not
  # "python3" and not this script's name; both miss the real process.
  ps axo pid,rss,command | awk -v m="$MARKER" '$0 ~ m && !/awk/ {printf "  balloon pid=%s rss=%.1fGB\n", $1, $2/1048576}'
}

# Refuse to start dirty: live marker processes or stale pidfiles that still
# point at running processes mean the previous run's cleanup never finished.
live=$(pgrep -f "$MARKER" || true)
if [ -n "$live" ]; then
  echo "REFUSING to start: prior balloon process(es) alive: $live" >&2
  echo "Kill them (pkill -f $MARKER), verify with 'pgrep -f $MARKER', retry." >&2
  exit 3
fi
for f in "$PIDDIR"/*; do
  [ -e "$f" ] || continue
  if kill -0 "$(basename "$f")" 2>/dev/null; then
    echo "REFUSING to start: stale pidfile $f points at a live process" >&2
    exit 3
  fi
  rm -f "$f"
done

capture "pre-run"

CHILD=""
cleanup() {
  code=$?
  trap - EXIT INT TERM HUP
  [ -n "$CHILD" ] && kill "$CHILD" 2>/dev/null || true
  pkill -f "$MARKER" 2>/dev/null || true
  sleep 1
  rm -f "$PIDDIR/${CHILD:-none}"
  remaining=$(pgrep -f "$MARKER" || true)
  capture "post-cleanup"
  if [ -n "$remaining" ]; then
    echo "CLEANUP FAILED: balloon process(es) still alive: $remaining" >&2
    echo "Any proof measured after this point is contaminated." >&2
    exit 4
  fi
  echo "cleanup complete: zero balloon processes remain."
  exit "$code"
}
trap cleanup EXIT INT TERM HUP

echo "Ballooning ${GB} GB (incompressible; touching every page each cycle)."
echo "Ctrl-C releases everything instantly. Watch: sysctl vm.swapusage"
python3 - "$GB" "$MARKER" << 'EOF' &
import os, signal, sys, time
gb = int(sys.argv[1])
chunk = 512 * 1024 * 1024
blocks = []
signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
parent = os.getppid()
# INCOMPRESSIBLE fill: a constant pattern compresses to almost nothing,
# so on a large-RAM Mac the compressor absorbs the whole balloon and swap
# never grows (measured: an 85 GB 0xA5 balloon left vm.swapusage flat).
# Random bytes defeat per-page WKdm compression, so the balloon exerts its
# full nominal size. One 512 MiB urandom template is copied per block —
# copies are separate dirty pages, and per-page content is still random.
template = os.urandom(chunk)
for i in range(gb * 2):
    if os.getppid() != parent:
        sys.exit(0)  # wrapper died mid-fill: never orphan
    blocks.append(bytearray(template))
    print(f"  held {(i + 1) * 0.5:.1f} GB", flush=True)
del template
print("Holding. Ctrl-C to release.")
page = 16384  # Apple Silicon page size
while True:
    # Touch EVERY page of every block each cycle so the pager cannot leave
    # the balloon compressed/idle. One byte per 16 KiB page ≈ 64k writes/GB,
    # cheap on CPU but keeps all pages dirty-resident.
    for b in blocks:
        for offset in range(0, len(b), page):
            b[offset] = (b[offset] + 1) % 256
    # Orphan guard: if the bash wrapper is gone (killed -9, jetsam), our
    # parent becomes launchd; exit instead of holding memory forever.
    if os.getppid() != parent:
        sys.exit(0)
    time.sleep(2)
EOF
CHILD=$!
echo "$CHILD" > "$PIDDIR/$CHILD"
wait "$CHILD"
