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
- **Only its own pods**: the server acts on pods whose id it stored itself, and on a Mac's pod only
  when that Mac hands the model over. Other pods in the same RunPod account are never stopped or
  deleted; the server lists the account's pods only to notice when one of its own is gone.

## Run it

On a machine with Docker, one command installs the server and shows how to connect:

```bash
curl -fsSL https://raw.githubusercontent.com/LOGIN-TB/podlight/main/server/install.sh | sh
```

[`install.sh`](install.sh) uses the current folder when its compose file already runs the Podlight
server, otherwise `./podlight` with this repository's [`docker-compose.yml`](docker-compose.yml). It
pulls the current image, starts the server, waits until it answers and prints the box with address
and pairing code. It writes the machine's private network address to `.env` as `HOST_IP`, so the box
shows the LAN address. Run it again to update. `PODLIGHT_LANG=de` before `sh` prints the box in
German; `PODLIGHT_DIR` picks another folder.

By hand:

```yaml
services:
  podlight:
    image: ghcr.io/login-tb/podlight-server:latest
    pull_policy: always
    restart: unless-stopped
    volumes:
      - podlight-data:/data
    ports:
      - "8080:8080"
volumes:
  podlight-data:
```

```bash
docker compose up -d                          # starts in the background and shows none of the server's output
docker compose exec podlight podlight-info   # the box: address and pairing code
docker compose logs podlight                 # the same box in the log; its code may have expired since
```

After the start the log shows a box with everything the app needs: the address (the Coolify
domain, `PUBLIC_URL`, the LAN address from `HOST_IP`, or how to find it), the server's public IP
with a hint on putting a domain and a reverse proxy in front of it, and the pairing code.

The pairing code works once and for 30 minutes, and survives a restart. A new one, for another Mac
or after it expired, without a paired app:

```bash
docker exec <container> podlight-code   # a new code, printed in the same box
docker exec <container> podlight-info   # the box again; while nothing is paired, with a valid code
```

In the Podlight app choose **Add Server…** and enter the address and the code. Podlight then offers
to bring the Mac's setup along: the RunPod API key and Hugging Face token, the limits and rules,
and models with their pods (renamed to server pods, disk and all, so nothing is downloaded again).
The RunPod key is stored encrypted on the server (AES-256-GCM, master key in the data volume) and
never sent back to an app.

**Coolify:** add a Docker Compose resource with [`docker-compose.yml`](docker-compose.yml) and give
the service a domain; Coolify then serves it over HTTPS and the box shows that domain.
`PAIRING_CODE` can be set from Coolify's generated secrets instead of reading it from the log. A
new code: `podlight-code` in the container's terminal.

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
| `HOST` | `0.0.0.0` | the address to listen on |
| `DATA_DIR` | `/data` | database `podlight.db` and `keys/master.key` |
| `DATABASE_PATH`, `MASTER_KEY_PATH` | in `DATA_DIR` | |
| `PAIRING_CODE` | generated | a fixed code for the first pairing |
| `PUBLIC_URL` | | the https address behind your own reverse proxy, for the connection box |
| `SERVICE_URL_*`, `SERVICE_FQDN_*` | set by Coolify | the service's domain, for the connection box |
| `HOST_IP`, `HOST_PORT` | | the machine's LAN address and published port, for the connection box |
| `PUBLIC_IP_LOOKUP` | `true` | `false`: do not ask api.ipify.org for the public IP at start |
| `PODLIGHT_LANG` | `en` | `de`: the connection box in German |
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
