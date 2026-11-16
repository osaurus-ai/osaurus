# Pinned by index digest so a rebuild only changes when this line does.
FROM alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a

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
# `uvx some-server` work out of the box. A pinned release tarball,
# checked against the release's published SHA-256 (the image is
# linux/arm64 only), lands the binaries on the default PATH for the
# sandboxed agent user.
ARG UV_VERSION=0.13.6
ARG UV_SHA256=819692e404d23e5aae6bc44c0e260f1f5492fd1910ab4693b2c650f926dbe800
RUN set -eu; \
    curl -fsSLo /tmp/uv.tar.gz "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-aarch64-unknown-linux-musl.tar.gz"; \
    echo "${UV_SHA256}  /tmp/uv.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/uv.tar.gz -C /usr/local/bin --strip-components=1 uv-aarch64-unknown-linux-musl/uv uv-aarch64-unknown-linux-musl/uvx; \
    rm /tmp/uv.tar.gz; \
    uv --version
