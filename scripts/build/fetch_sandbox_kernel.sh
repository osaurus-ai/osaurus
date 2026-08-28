#!/usr/bin/env bash
set -euo pipefail

# Stage the sandbox guest kernel into the app bundle so first-run users
# don't download the ~665 MiB Kata distribution just to keep an ~18 MiB
# vmlinux. The extracted kernel is verified against a pinned SHA-256 and
# shipped with a provenance sidecar (upstream release, source URL,
# license/source-offer) — the kernel is GPL-2.0, so the sidecar records
# where the corresponding source lives.
#
# The four pins below MUST match `SandboxRuntimeAssets` in
# Packages/OsaurusCore/Services/Sandbox/SandboxRuntimeAssets.swift.
# `SandboxManager.ensureKernel` verifies KERNEL_SHA256 again at install
# time and falls back to the digest-verified tarball download if the
# bundled copy is missing or fails verification, so a stale pin here
# degrades to the old behavior rather than a broken sandbox.
#
# Usage: fetch_sandbox_kernel.sh <output-dir>
#   <output-dir> receives `vmlinux` and `vmlinux.provenance.json`
#   (typically <App>.app/Contents/Resources/SandboxRuntime).

KERNEL_VERSION="6.18.35-197"
KERNEL_SHA256="f437320bab94f19105d12b932aa29735f0d54d2588218872254367f312c1027c"
KERNEL_ARCHIVE_PATH="opt/kata/share/kata-containers/vmlinux-6.18.35-197"
TARBALL_URL="https://github.com/kata-containers/kata-containers/releases/download/3.32.0/kata-static-3.32.0-arm64.tar.zst"
TARBALL_SHA256="8736c054d9223974735394f822000823baef509e1c33405ec798240fa9b6e4b5"
UPSTREAM_RELEASE="kata-containers 3.32.0"
KERNEL_SOURCE_OFFER="https://github.com/kata-containers/kata-containers/tree/3.32.0/tools/packaging/kernel"

OUT_DIR="${1:?output directory required (e.g. Osaurus.app/Contents/Resources/SandboxRuntime)}"
CACHE_DIR="${SANDBOX_KERNEL_CACHE_DIR:-${HOME}/.cache/osaurus-sandbox-kernel}"
CACHED_KERNEL="${CACHE_DIR}/vmlinux-${KERNEL_VERSION}"

sha256_of() {
  shasum -a 256 "$1" | awk '{print $1}'
}

mkdir -p "$OUT_DIR" "$CACHE_DIR"

if [[ ! -f "$CACHED_KERNEL" || "$(sha256_of "$CACHED_KERNEL")" != "$KERNEL_SHA256" ]]; then
  echo "Fetching Kata tarball to extract sandbox kernel ${KERNEL_VERSION}..."
  WORK_DIR="$(mktemp -d)"
  trap 'rm -rf "$WORK_DIR"' EXIT

  curl -fL --retry 3 -o "$WORK_DIR/kata.tar.zst" "$TARBALL_URL"
  ACTUAL_TARBALL_SHA="$(sha256_of "$WORK_DIR/kata.tar.zst")"
  if [[ "$ACTUAL_TARBALL_SHA" != "$TARBALL_SHA256" ]]; then
    echo "ERROR: Kata tarball SHA-256 mismatch (expected $TARBALL_SHA256, got $ACTUAL_TARBALL_SHA)" >&2
    exit 1
  fi

  tar -xf "$WORK_DIR/kata.tar.zst" -C "$WORK_DIR" \
    "./${KERNEL_ARCHIVE_PATH}"
  EXTRACTED="$WORK_DIR/${KERNEL_ARCHIVE_PATH}"
  ACTUAL_KERNEL_SHA="$(sha256_of "$EXTRACTED")"
  if [[ "$ACTUAL_KERNEL_SHA" != "$KERNEL_SHA256" ]]; then
    echo "ERROR: extracted kernel SHA-256 mismatch (expected $KERNEL_SHA256, got $ACTUAL_KERNEL_SHA)" >&2
    exit 1
  fi
  cp "$EXTRACTED" "$CACHED_KERNEL"
fi

cp "$CACHED_KERNEL" "$OUT_DIR/vmlinux"

cat > "$OUT_DIR/vmlinux.provenance.json" <<EOF
{
  "artifact": "vmlinux",
  "kernelVersion": "${KERNEL_VERSION}",
  "sha256": "${KERNEL_SHA256}",
  "upstreamRelease": "${UPSTREAM_RELEASE}",
  "sourceTarball": "${TARBALL_URL}",
  "sourceTarballSHA256": "${TARBALL_SHA256}",
  "license": "GPL-2.0-only",
  "sourceOffer": "${KERNEL_SOURCE_OFFER}"
}
EOF

echo "Sandbox kernel ${KERNEL_VERSION} staged at ${OUT_DIR}/vmlinux"
