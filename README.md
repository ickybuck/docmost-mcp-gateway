# docmost-mcp-gateway

Packages [`@wisflux/docmost-local-mcp`](https://www.npmjs.com/package/@wisflux/docmost-local-mcp) v0.9.2
behind [supergateway](https://github.com/supercorp-ai/supergateway), exposing the stdio MCP server
over streamable HTTP so other clients can reach Docmost over the network.

Image: `ghcr.io/ickybuck/docmost-mcp-gateway:latest`

## Endpoint

Port `8000`, streamable HTTP at **`/mcp`** (supergateway's default path).

Verified working headless: `initialize` and `tools/list` both respond (server reports
`rmcp 0.6.4`, 20 tools).

## Base image constraints

The base image is **not** arbitrary. `@wisflux/docmost-local-mcp` is not a pure Node package —
its postinstall downloads a Rust/Tauri binary (`docmost-local-mcp-linux-x64`, one artifact per
platform, no headless variant) that is dynamically linked against `libwebkit2gtk-4.1`,
`libgtk-3`, `libsoup-3` and needs `GLIBC_2.39`.

| Base | Outcome |
| --- | --- |
| `supercorp/supergateway:latest` | ❌ Alpine 3.22 (musl) — binary cannot exec; musl reports it as a misleading `spawnSync ENOENT` |
| `node:20-slim` | ❌ Debian bookworm, glibc 2.36 — `GLIBC_2.39 not found` |
| `ubuntu:24.04` + WebKitGTK | ✅ glibc 2.39 and the required GTK stack |

## Authentication

This container **cannot perform an interactive login.** A tool call without a session returns:

```
The Docmost sign-in window exited unexpectedly (code 101).
```

The binary spawns a GTK sign-in window; with no display it exits immediately, and no
fallback login server is left listening. Its only env vars are `DOCMOST_BASE_URL`,
`DOCMOST_DISABLE_KEYRING`, and `DOCMOST_MCP` — there is no email/password env var and no
headless auth flag.

### Supply a session instead

Session state lives in `$HOME/.config/docmost-local-mcp/`:

- `config.json`
- `session.json`
- `credentials.enc.json`
- `credentials.key` ← the decryption key sits beside the encrypted file, so the directory is
  portable between hosts (not machine-bound)

`HOME` is `/data` in this image, so the store belongs at
`/data/.config/docmost-local-mcp/`.

On the TrueNAS box, Hermes already keeps an authenticated store at
`/opt/data/mcp/docmost/home` (same binary version, same `http://docmost:3000`). Seed this
container from a **copy** of it:

```bash
cp -a /opt/data/mcp/docmost/home/.config/docmost-local-mcp \
      /mnt/<pool>/docmost-mcp-gateway/.config/
```

Then mount that directory as `/data`.

> Copy rather than bind-mounting Hermes's live directory — two processes refreshing the same
> JWT in one session store can clobber each other.

`DOCMOST_DISABLE_KEYRING=1` is set because there is no OS keychain in a container; without it
the credential store has nowhere to go.

### When the session expires

Docmost sessions expire and the copied one will too. Re-authenticate via the existing runbook
(*3.6 → Reauthenticate Docmost MCP (Hermes)*: SSH tunnel + file-driven bridge, with
`login-url.txt` as the only authoritative source for the dynamic callback port), then re-copy
the refreshed store.

## Configuration

| Var | Default | Notes |
| --- | --- | --- |
| `DOCMOST_BASE_URL` | `http://docmost:3000` | Docmost instance to talk to |
| `DOCMOST_DISABLE_KEYRING` | `1` | No OS keychain in a container; persist to `$HOME` |
| `HOME` | `/data` | Session store parent |

## Run

```bash
docker run -d --name docmost-mcp \
  -p 8000:8000 \
  -v /path/to/seeded/home:/data \
  -e DOCMOST_BASE_URL=http://docmost:3000 \
  ghcr.io/ickybuck/docmost-mcp-gateway:latest
```
