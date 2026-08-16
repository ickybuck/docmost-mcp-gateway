# Base must be glibc >= 2.39 AND carry the GTK3/WebKitGTK stack.
#
# @wisflux/docmost-local-mcp is not a pure Node package: its postinstall
# downloads a Rust/Tauri binary that is dynamically linked against
# libwebkit2gtk-4.1, libgtk-3, libsoup-3 and requires GLIBC_2.39.
#
#   - supercorp/supergateway:latest is Alpine 3.22 (musl) -> the binary cannot
#     exec at all; musl reports it as a misleading spawnSync ENOENT.
#   - node:20-slim is Debian bookworm (glibc 2.36) -> GLIBC_2.39 not found.
#
# Ubuntu 24.04 provides glibc 2.39 and the WebKitGTK 4.1 packages.
FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg xz-utils \
      libwebkit2gtk-4.1-0 libgtk-3-0t64 libsoup-3.0-0 \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @wisflux/docmost-local-mcp@0.9.2 supergateway@latest

ENV HOME=/data
ENV DOCMOST_BASE_URL=http://docmost:3000
# No OS keychain in a container; persist the session to $HOME (/data) instead.
ENV DOCMOST_DISABLE_KEYRING=1

WORKDIR /data
VOLUME ["/data"]

EXPOSE 8000

ENTRYPOINT ["supergateway", \
  "--stdio", "docmost-local-mcp", \
  "--outputTransport", "streamableHttp", \
  "--port", "8000"]
