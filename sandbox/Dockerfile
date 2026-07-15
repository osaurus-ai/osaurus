FROM alpine:latest

RUN mkdir -p /run /tmp

# The package set is deliberately split into a few balanced RUN layers
# instead of one ~190 MiB blob: Containerization's image puller downloads
# layers concurrently (`maxConcurrentDownloads`), so 3-4 mid-sized layers
# saturate a typical connection far better than one giant layer, and a
# package bump only invalidates the layer it lives in. Keep the split
# roughly balanced by compressed size when editing (the sandbox-image CI
# workflow prints per-layer sizes on every build).

# Layer 1: core shell + system tooling (small, most stable).
RUN apk add --no-cache \
    bash \
    git patch \
    curl wget openssh-client ca-certificates \
    jq tar gzip zip unzip findutils coreutils grep sed less vim \
    file tree ripgrep \
    sqlite sqlite-dev \
    tzdata

# Layer 2: Python runtime + headers.
RUN apk add --no-cache \
    python3 python3-dev py3-pip \
    libffi-dev openssl-dev

# Layer 3: Node runtime.
RUN apk add --no-cache \
    nodejs npm \
    libstdc++

# Layer 4: native build toolchain (largest, rarely changes).
RUN apk add --no-cache \
    build-base cmake

# Install Astral `uv` / `uvx` so stdio MCP servers shipped as
# `uvx some-server` work out of the box. The installer auto-picks the
# musl build for Alpine; `UV_INSTALL_DIR` lands the binaries on the
# default PATH for the sandboxed agent user.
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh
