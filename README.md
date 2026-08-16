# docmost-mcp-gateway

Packages the **headless** build of [`@wisflux/docmost-local-mcp`](https://github.com/wisflux/docmost-local-mcp)
v0.9.2 behind [supergateway](https://github.com/supercorp-ai/supergateway), exposing the stdio MCP
server over streamable HTTP.

Image: `ghcr.io/ickybuck/docmost-mcp-gateway:latest` (~387MB)

## Endpoint

Port `8000`, streamable HTTP at **`/mcp`** (supergateway's default path).

Verified: `initialize` and `tools/list` respond with all 20 tools (server reports `rmcp 0.6.4`).

## Why not `npm install`

`npm install -g @wisflux/docmost-local-mcp` is the wrong way to build this image. Its
`postinstall.js` maps every Linux target to a single asset, `docmost-local-mcp-linux-x64` —
a Tauri build **hard-linked** against `libwebkit2gtk-4.1`, `libgtk-3` and `libsoup-3`. That:

- drags in 220 packages / 544MB of desktop stack just to satisfy the dynamic loader, and
- still cannot authenticate headlessly — it spawns a GTK sign-in window which exits
  immediately with `The Docmost sign-in window exited unexpectedly (code 101).`

The same v0.9.2 release also publishes **`docmost-local-mcp-linux-x64-headless`**, whose only
`NEEDED` libs are `libc`, `libm`, `libgcc_s`. It `dlopen`s the GUI toolkit lazily and falls back
to a local HTTP login server. This image downloads that asset directly, pinned by SHA256.

Both builds require `GLIBC_2.39`, so the base must be trixie (2.41) or newer:

| Base | Outcome |
| --- | --- |
| `supercorp/supergateway:latest` | ❌ Alpine 3.22 (musl) — cannot exec; musl reports it as a misleading `spawnSync ENOENT` |
| `node:20-slim` / TrueNAS host | ❌ Debian bookworm, glibc 2.36 — `GLIBC_2.39 not found` |
| `node:22-trixie-slim` | ✅ glibc 2.41 |

## Authentication

Session state lives in `$HOME/.config/docmost-local-mcp/` — `config.json`, `session.json`,
`credentials.enc.json`, and `credentials.key`. The key sits beside the encrypted file, so the
directory is portable between hosts. `HOME` is `/data` here, so mount a persistent volume there.

`DOCMOST_DISABLE_KEYRING=1` is set because a container has no OS keychain.

### Option A — copy an existing session

If another deployment is already authenticated against the same Docmost instance, copy its
store into the volume mounted at `/data`, so the files land at
`/data/.config/docmost-local-mcp/`.

> Copy rather than sharing a live directory — two processes rotating the same JWT can clobber
> each other.

### Option B — log in through the callback bridge

On the first unauthenticated tool call the binary starts a login server on a **dynamic port bound
to `127.0.0.1`** inside the container, and serves a Docmost sign-in form at `/login`. The tool
call itself returns `Failed to open fallback browser window` (there is no browser in the
container), but **the login server stays listening**, so the flow still completes:

```bash
# 1. trigger it (this call returns an error - that is expected)
curl -s -X POST http://localhost:8000/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_spaces","arguments":{}}}'

# 2. find the dynamic port
docker exec <container> ss -ltn | grep -v :8000

# 3. bridge it somewhere your browser can reach, then sign in at /login
# 4. re-issue the call from step 1 - it should now succeed
```

Because the server binds `127.0.0.1`, publishing a port is not enough; you need a bridge inside
the container's network namespace. The port is newly assigned each time — never hard-code it.

## Configuration

| Var | Default | Notes |
| --- | --- | --- |
| `DOCMOST_BASE_URL` | `http://docmost:3000` | Docmost instance to talk to |
| `DOCMOST_DISABLE_KEYRING` | `1` | No OS keychain in a container |
| `HOME` | `/data` | Session store parent |

## Run

```bash
docker run -d --name docmost-mcp \
  -p 8000:8000 \
  -v docmost-mcp-data:/data \
  -e DOCMOST_BASE_URL=http://docmost:3000 \
  ghcr.io/ickybuck/docmost-mcp-gateway:latest
```

## Build

```bash
docker build -t docmost-mcp-gateway .
```

`MCP_VERSION` and `MCP_SHA256` are build args; bump both together when upgrading.
