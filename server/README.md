# Podlight server

The server mode of [Podlight](../README.md): the same gateway and pod lifecycle as the Mac app, as
one container. Agents keep a model endpoint while your Mac is off; the Podlight app on the Mac
controls the server (models, starts, limits, access keys) but does not have to be running.

- **Gateway** on `/v1` for agents: OpenAI chat completions, completions and embeddings, the
  OpenAI Responses API (Codex) and the Anthropic Messages API (Claude Code). The `model` field picks
  the model; a stopped model is woken when an agent asks for it, after the spending limits allow it.
- **Control API** on `/admin` for Podlight apps, described in [`spec/openapi.json`](../spec/openapi.json).
- **Same rules as the Mac** for when pods stop: "runs until", idle stop, runtime ceiling, daily and
  monthly limits, deletion of unused stopped pods. Both implementations pass the same cases in
  [`spec/cases`](../spec/README.md).
- **Safety stop in every pod**: the server sends a heartbeat every 10–20 seconds. A pod that hears
  nothing for the configured minutes (default 15) stops itself, also when the whole server is gone.
- **Only its own pods**: the server acts on pods whose id it stored itself. Other pods in the same
  RunPod account, including the ones your Mac runs, are never listed, stopped or deleted.

## Run it

```yaml
services:
  podlight:
    image: ghcr.io/login-tb/podlight-server:latest
    restart: unless-stopped
    volumes:
      - podlight-data:/data
    ports:
      - "8080:8080"
volumes:
  podlight-data:
```

```bash
docker compose up -d
docker compose logs podlight   # shows the pairing code
```

The pairing code works once and for 30 minutes, and survives a restart. In the Podlight app choose
**Add Server…**, enter the address and the code, then enter the server's RunPod API key under
**Server Settings**. The key is stored encrypted on the server (AES-256-GCM, master key in the data
volume) and never sent back to an app.

**Coolify:** add a Docker Compose resource with [`docker-compose.yml`](docker-compose.yml) and give
the service a domain; Coolify then serves it over HTTPS. `PAIRING_CODE` can be set from Coolify's
generated secrets instead of reading it from the log.

## HTTPS

The container speaks plain HTTP. Before it is reachable from the internet, put a reverse proxy with
a certificate in front of it (Coolify, Traefik, Caddy). The Podlight app connects only to `https://`
addresses, except `localhost` and private network addresses (10.x, 172.16–31.x, 192.168.x, `.local`),
where it warns that the connection is unencrypted. The server itself creates no certificate.

## Keys

| Key | Who holds it | Where it works |
|---|---|---|
| Device token (`pld-…`) | a paired Podlight app, in its keychain | `/admin` only |
| Access key (`pl-…`) | an agent or a machine, created in the app | `/v1` only, optionally limited to some models |
| RunPod API key | the server, encrypted | RunPod |
| Pod key | the server, encrypted, one per model | between the server and that model's pod |

Tokens are stored as SHA-256 hashes. A wrong key costs one second, so guessing is slow.

## Settings

| Variable | Default | |
|---|---|---|
| `PORT` | `8080` | |
| `DATA_DIR` | `/data` | database `podlight.db` and `keys/master.key` |
| `PAIRING_CODE` | generated | a fixed code for the first pairing |
| `TRUST_PROXY` | `true` | read the client address from `X-Forwarded-For` |
| `LOG_LEVEL` | `info` | |

Everything else (limits, safety stop, default location, time zone for the spend ledger) is set in
the app under **Server Settings**.

## Develop

```bash
cd server
npm ci
npm test          # spec/cases plus end-to-end tests against a fake RunPod and a fake pod
npx tsc --noEmit
npm run gen       # regenerates spec/schema/model.json and spec/openapi.json
npm start         # DATA_DIR=./data PORT=8080 for a local run
```

Node 24 runs the TypeScript directly (type stripping); there is no build step. The image is built
from the repository root: `docker build -f server/Dockerfile .`
