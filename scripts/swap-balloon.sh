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
exec python3 - "$GB" swap-balloon-marker << 'EOF'
import signal, sys, time
gb = int(sys.argv[1])
chunk = 512 * 1024 * 1024
blocks = []
signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
# INCOMPRESSIBLE fill: a constant pattern compresses to almost nothing,
# so on a large-RAM Mac the compressor absorbs the whole balloon and swap
# never grows (measured: an 85 GB 0xA5 balloon left vm.swapusage flat).
# Random bytes defeat per-page WKdm compression, so the balloon exerts its
# full nominal size. One 512 MiB urandom template is copied per block —
# copies are separate dirty pages, and per-page content is still random.
import os
template = os.urandom(chunk)
for i in range(gb * 2):
    blocks.append(bytearray(template))
    print(f"  held {(i + 1) * 0.5:.1f} GB", flush=True)
del template
print("Holding. Ctrl-C to release.")
page = 16384  # Apple Silicon page size
while True:
    # Touch EVERY page of every block each cycle so the pager cannot leave
    # the balloon compressed/idle — an untouched balloon gets compressed
    # away and defeats the test. One byte per 16 KiB page ≈ 64k writes/GB,
    # cheap on CPU but keeps all pages dirty-resident.
    for b in blocks:
        for offset in range(0, len(b), page):
            b[offset] = (b[offset] + 1) % 256
    time.sleep(2)
EOF
