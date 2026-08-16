# Uses the *headless* release asset, not the one `npm install` fetches.
#
# @wisflux/docmost-local-mcp's postinstall only knows about
# docmost-local-mcp-linux-x64 — a Tauri build hard-linked against
# libwebkit2gtk-4.1/libgtk-3/libsoup-3, which drags in a 544MB desktop stack and
# still cannot authenticate headlessly (it spawns a GTK sign-in window that exits
# with code 101 when there is no display).
#
# The same v0.9.2 release also ships docmost-local-mcp-linux-x64-headless, whose
# only NEEDED libs are libc/libm/libgcc_s. It dlopens the GUI toolkit lazily and
# falls back to a local login callback server, which is what makes the
# login-url.txt reauthentication flow possible.
#
# Both builds still require GLIBC_2.39, so the base must be trixie (2.41) or
# newer -- bookworm (2.36) is too old.

FROM debian:trixie-slim AS fetch

ARG MCP_VERSION=0.9.2
ARG MCP_SHA256=e71cdcd8239ab1e4e33de55968d4460ce795711294d4a753132832fa8e9f7ad2

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL -o /tmp/docmost-local-mcp \
         "https://github.com/wisflux/docmost-local-mcp/releases/download/v${MCP_VERSION}/docmost-local-mcp-linux-x64-headless" \
    && echo "${MCP_SHA256}  /tmp/docmost-local-mcp" | sha256sum -c - \
    && chmod 0755 /tmp/docmost-local-mcp


FROM node:22-trixie-slim

RUN npm install -g supergateway@latest && npm cache clean --force

COPY --from=fetch /tmp/docmost-local-mcp /usr/local/bin/docmost-local-mcp

ENV HOME=/data
ENV DOCMOST_BASE_URL=http://docmost:3000
# No OS keychain in a container; persist credentials under $HOME instead.
ENV DOCMOST_DISABLE_KEYRING=1

WORKDIR /data
VOLUME ["/data"]

EXPOSE 8000

ENTRYPOINT ["supergateway", \
  "--stdio", "docmost-local-mcp", \
  "--outputTransport", "streamableHttp", \
  "--port", "8000"]
