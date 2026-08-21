# docmost-mcp-gateway

Packages the **headless** build of [`@wisflux/docmost-local-mcp`](https://github.com/wisflux/docmost-local-mcp)
v0.9.2 behind [supergateway](https://github.com/supercorp-ai/supergateway), exposing the stdio MCP
server over streamable HTTP.

Image: `ghcr.io/ickybuck/docmost-mcp-gateway:latest` (~387MB)

## Scope

General-purpose. This gateway is not tied to any particular content migration — deploy an
instance wherever an agent needs authenticated Docmost access over HTTP, and run as many as
you have Docmost identities for.

**Know the write limit before choosing what to point it at.** Docmost stores page bodies as
ProseMirror JSON, and its REST `/pages/update` handles metadata only — content changes route
through the Yjs/Hocuspocus collaboration gateway. There is no block-level or append endpoint,
so every content write replaces the **entire** document.

Cost therefore scales with page size, not edit size: a one-line change to a 10,000-word page
makes the agent re-emit all ~13,000 tokens. Keep agent-written pages small, or split them into
child pages (`create_page` with `parent_page_id`, `list_child_pages` to navigate). This is an
API-shape constraint, not a tuning problem — server-side writes are milliseconds.

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

Session state lives in **`$HOME/.docmost-local-mcp/`** (a dotdir directly under `$HOME` — *not*
under `.config/`), holding `config.json`, `session.json`, `credentials.enc.json`, and
`credentials.key`. The key sits beside the encrypted file, so the directory is portable between
hosts. `HOME` is `/data` here, so mount a persistent volume there and the store lands at
`/data/.docmost-local-mcp/`.

`DOCMOST_DISABLE_KEYRING=1` is set because a container has no OS keychain.

### The session is bound to its base URL

`config.json` records the `baseUrl` the login was performed against:

```json
{
  "baseUrl": "https://docs.example.com",
  "email": "you@example.com",
  "lastAuthenticatedAt": "..."
}
```

**`DOCMOST_BASE_URL` at runtime must match the URL the session was created with.** Verified: a
store authenticated against one URL, then run with a different `DOCMOST_BASE_URL`, does not
reuse the session — it attempts a fresh login and fails with `Failed to call the Docmost login
endpoint`. Authenticate against whichever URL the deployed container will actually use.

Verified working: a brand-new container on a previously authenticated volume, with a matching
`DOCMOST_BASE_URL`, serves `list_spaces` and `get_current_user` without any re-login.

### Option A — copy an existing session

If another deployment is already authenticated against the same Docmost instance *at the same
base URL*, copy its store into the volume mounted at `/data`, so the files land at
`/data/.docmost-local-mcp/`.

> Copy rather than sharing a live directory — two processes rotating the same JWT can clobber
> each other.

### Option B — log in through the callback bridge

On the first unauthenticated tool call the binary starts a login server on a **dynamic port bound
to `127.0.0.1`** inside the container, and serves a Docmost sign-in form at `/login`. The tool
call itself returns `Failed to open fallback browser window` (there is no browser in the
container), but **the login server stays listening**, so the flow still completes:

Because the server binds `127.0.0.1`, publishing a port is not enough — you need a bridge inside
the container's own network namespace. Start the container with a spare published port (`9000`
below) to bridge onto, since the login port is only known later and is newly assigned every
time. **Never hard-code it.**

```bash
docker run -d --name docmost-mcp -p 8000:8000 -p 9000:9000 \
  -v docmost-mcp-data:/data -e DOCMOST_BASE_URL=https://docs.example.com \
  ghcr.io/ickybuck/docmost-mcp-gateway:latest
```

```bash
docker exec docmost-mcp sh -c 'apt-get -qq update && apt-get -qq install -y socat iproute2 curl'
```

Trigger the login server — this call returns `Failed to open fallback browser window`, which is
expected and harmless; the server it started keeps listening:

```bash
docker exec -d docmost-mcp curl -s -X POST http://localhost:8000/mcp -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_spaces","arguments":{}}}'
```

Find the dynamic port and bridge it to the published one:

```bash
docker exec docmost-mcp sh -c "socat TCP-LISTEN:9000,fork,reuseaddr TCP:127.0.0.1:$(docker exec docmost-mcp sh -c "ss -ltn | grep -v ':8000' | grep -v ':9000' | grep -oE '127.0.0.1:[0-9]+'" | cut -d: -f2 | head -1)" &
```

Open `http://localhost:9000/login`, sign in, then re-issue the call — it now succeeds. The
sign-in server shuts down on success and the store is written to `/data/.docmost-local-mcp/`.
Remove the `9000` publish and the socat bridge afterwards; they are only needed for login.

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
