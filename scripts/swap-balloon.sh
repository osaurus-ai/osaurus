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
set -euo pipefail
GB="${1:-16}"
if ! [[ "$GB" =~ ^[0-9]+$ ]] || [ "$GB" -lt 1 ] || [ "$GB" -gt 200 ]; then
  echo "usage: $0 <gigabytes 1-200>" >&2; exit 2
fi
echo "Ballooning ${GB} GB (touching every page so it cannot stay compressed-idle)."
echo "Ctrl-C releases everything instantly. Watch: sysctl vm.swapusage"
exec python3 - "$GB" << 'EOF'
import signal, sys, time
gb = int(sys.argv[1])
chunk = 512 * 1024 * 1024
blocks = []
signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
for i in range(gb * 2):
    # bytearray of non-zero pattern: forces real dirty pages.
    blocks.append(bytearray(b"\xA5" * chunk))
    print(f"  held {(i + 1) * 0.5:.1f} GB", flush=True)
print("Holding. Ctrl-C to release.")
while True:
    time.sleep(5)
    # Re-touch a stripe of each block so the pages stay hot and the pager
    # must keep them (or swap something else) — an idle balloon gets
    # compressed away and defeats the test.
    for b in blocks:
        b[0] = (b[0] + 1) % 256
        b[len(b) // 2] = (b[len(b) // 2] + 1) % 256
EOF
