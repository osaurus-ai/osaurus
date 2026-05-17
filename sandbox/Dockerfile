FROM alpine:latest

RUN mkdir -p /run /tmp

RUN apk add --no-cache \
    bash \
    python3 python3-dev py3-pip \
    nodejs npm \
    build-base cmake \
    git patch \
    curl wget openssh-client ca-certificates \
    jq tar gzip zip unzip findutils coreutils grep sed less vim \
    file tree ripgrep \
    sqlite sqlite-dev \
    libstdc++ libffi-dev openssl-dev \
    tzdata

# Install Astral `uv` / `uvx` so stdio MCP servers shipped as
# `uvx some-server` work out of the box. The installer auto-picks the
# musl build for Alpine; `UV_INSTALL_DIR` lands the binaries on the
# default PATH for the sandboxed agent user.
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh
