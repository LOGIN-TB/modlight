# Server

A Podlight server keeps your models reachable for agents while this Mac is off: for n8n, an agent on another computer, or a team. It runs as one container on a VPS, a NAS or with Coolify. Podlight on the Mac controls it: adding models, starting them, setting limits, handing out access keys. The app does not have to be running for that.

![A server on the overview](screenshots/en/overview-server.png)

## Set up a server

Under "Add Server…" → "How do I set up a server?" there is a ready `docker-compose.yml`. Start it with `docker compose up -d`. On its first start the server writes a pairing code to its log (`docker compose logs`). The code works once and for 30 minutes, also across a restart.

Before the server is reachable from the internet it needs an https address. In Coolify, give the service a domain; elsewhere, put a reverse proxy such as Caddy in front of it. Podlight connects only to https addresses. The exceptions are this Mac and your local network, where Podlight warns that the connection is unencrypted.

## Pair

In the sidebar under "Podlight" → "Add Server…", enter the address and the pairing code. The server then appears as its own section in the sidebar.

Under "Server Settings", enter the server's RunPod API key. The server pays for its pods with it. The key is stored encrypted on the server; Podlight on the Mac never reads it back. This is also where you set the daily and monthly limits, the safety stop and the default location.

![Server settings](screenshots/en/server-settings.png)

## Models on the server

"Add Model…" in the server's section goes through the same steps as on the Mac; the GPU list comes from the server. Start, Stop and Extend work as usual. The model shows "Runs on" with the server's name.

## Connect agents

Agents talk to the server with an access key of their own, not this Mac's key. Under "Connection" in the server's section, create one with "New Access Key…", ideally one per agent or computer. A key can be limited to some models. It is shown only right after it is created; copy it then, because the server keeps only a fingerprint.

With the new key, the files under "Configuration files for experts" contain everything needed. The shell functions are named after the server, for a server named "Office" `claude-podlight-office`, so they sit beside the ones for this Mac.

![Connection to a server](screenshots/en/server-connection.png)

## While the Mac is off

The server stops pods by the same rules as the Mac: at the end of "runs until", after idling, at the spending limits. A stopped model starts by itself when an agent asks for it, as long as the limits allow it.

If the server goes down, each of its pods stops itself after the configured time (15 minutes by default). The server only acts on pods it created itself. This Mac's pods and other pods in your RunPod account are left alone.

When you quit Podlight on the Mac, the models on the server keep running. "Remove Server…" in the server settings makes Podlight forget the server; the models there keep running under the server's rules.
