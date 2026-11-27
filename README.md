# Modlight

**Open models for your coding agent: one address, one key, wherever the model runs, with costs under control. On your Mac, and on a server for when your Mac is off.**
Point OpenCode, Claude Code, Codex or any OpenAI-compatible client at Modlight once; it sends each
model's requests to where that model runs. Today that is your own GPU pod at RunPod (pick a model on
Hugging Face, Modlight suggests the card, shows what it will cost and stops the pod when the time is
up, nobody is asking, or your Mac sleeps) and ready models at [Venice.ai](https://venice.ai), billed
per token with nothing to start. More providers of open models are planned.

*Modlight was called Podlight until 0.12.*

> **Status: 0.13.0.** Local mode on the Mac, usable from other computers on your network, and server
> mode: a container that keeps models reachable while your Mac is off, controlled from the app. vLLM
> and llama.cpp (GGUF) on RunPod, and Venice's ready models per token; Claude Code and Codex as well
> as OpenAI-compatible agents. Built and tested on real RunPod hardware; Venice against its recorded
> catalog and a stand-in for its API. See [What has been tested](#what-has-been-tested) and [Known limits](#known-limits).

*Modlight is an independent project. It is not affiliated with or endorsed by RunPod or Venice.*

## Install

Download `Modlight-<version>.dmg` from [Releases](https://github.com/LOGIN-TB/modlight/releases),
open it and drag Modlight to Applications. It needs macOS 26 or later. Modlight updates itself
(Modlight → Check for Updates).

On first launch Modlight asks for your RunPod API key, your Venice API key, or both, and shows where
to create them. Then:

1. **Add a model**: search Hugging Face or paste a link. Safetensors, AWQ, GPTQ, FP8 and NVFP4 run
   on vLLM; GGUF runs on llama.cpp, with the quantisation of your choice. Choose where it may run
   and the context (up to the model's own limit); Modlight suggests the cards that hold it, also
   several in one pod, with price per hour, estimated speed and data center.
2. **Start** it and choose how long it runs. A new pod takes a few minutes up to 25 (the GPU host
   downloads the engine, 9 GB for vLLM or 4 GB for llama.cpp, then the model); resuming a stopped
   one with a kept disk takes about a minute.
   Or choose **Ready model at Venice**: search Venice's catalog (private models by default), see the
   price per million tokens, give it a name. It is ready at once and costs nothing until it is used.
3. **Connect your agent**: Modlight → Connection shows the address, the key and the model name to
   copy into any OpenAI-compatible agent. Ready-made configuration for OpenCode, pi, Claude Code and
   Codex is there for experts.

The overview, Modlight's first screen, shows what runs and costs and what to do next.

The built-in help (Help → Modlight Help) explains each step in German and English.

## Venice: ready models per token

[Venice.ai](https://venice.ai) serves open and third-party models through an OpenAI-compatible API.
An "Inference Only" key from venice.ai → Settings → API is enough. In Modlight:

- **Same way in.** A Venice model has a served name like any other; agents use the same address and
  key. Modlight sends the request on with Venice's model id and your Venice key, and turns Venice's own
  system prompt off (agents bring their own). Claude Code works too: Modlight translates the
  Anthropic Messages API to chat completions and back, streaming and tool calls included.
- **Live figures.** A Venice model's page shows requests in flight, tokens per minute (new, cached,
  output), time to first token and output speed against Venice's public median, its rate limits
  from Venice's response headers, cost per hour now and the balance's runway. Modlight sends a
  `prompt_cache_key` per agent and system prompt, so more of the resent conversation is billed at
  the cache rate.
- **Costs as they happen.** Each answer's usage (Venice's own `cost` where it gives one, else tokens ×
  the model's prices, cached tokens apart) is booked per model and day. The Venice balance (USD, DIEM,
  plan credits) is read every minute and after use. The daily and monthly limits count pods and
  Venice together; at a limit, requests to Venice models are refused.
- **Privacy tiers.** The catalog marks each model *Private* (no data kept) or *Anonymized* (a third
  party such as Anthropic, OpenAI or Google runs it; Venice strips who sent it). Only private ones are
  listed until you include the others.
- **On a server too.** A server keeps its own Venice key, encrypted, set from the app.

The built-in help (page "Venice") walks through account, credit, key and first model.

## How it keeps costs down

- **Every start has an end.** You choose "runs until"; Modlight shows the most it can cost.
- **Idle stop.** No requests for 30 minutes (adjustable, never off): the pod stops.
- **Safety stop inside the pod.** A watchdog in every pod stops it after 15 minutes without a
  heartbeat from Modlight: Mac asleep, app quit or crashed, network gone. It uses the key RunPod
  injects into each pod, which can see and stop only that pod
  ([measured](docs/measurements-2026-11-20-dead-man-switch.md)). Your API key never leaves your Mac.
- **Spending limits** per day and month, checked before a request may wake a pod.
- **Quitting asks first** when pods run; "Stop and Quit" is the default.
- **No disk unless you want one.** Without "Keep model on disk" the pod is deleted at its end and
  nothing is billed in between; with it, restarts take a minute and the disk is billed (0.20 USD/GB
  a month while stopped), shown wherever costs appear. Kept disks are deleted after three days unused.

## Two ways to use it

| | **This Mac** | **Server** (since 0.4) |
|---|---|---|
| Where the endpoint runs | inside Modlight, on `127.0.0.1:7635`, optionally for the local network | in a Docker or Coolify container, behind HTTPS |
| Who pays RunPod | the Mac's RunPod key | the server's own RunPod key |
| Agents use | the Mac's key | access keys created in the app, optionally limited to models |
| When the Mac is off | pods stop themselves after 15 minutes | models stay reachable; pods stop by the server's rules |
| Good for | trying a model, coding with agents on this Mac or your network | n8n, agents on other machines, a team |

Both run by the same rules (shared cases in [`spec/`](spec/README.md)) and can be used at the same
time; the app shows the Mac and every server side by side. Set up a server with
[`server/`](server/README.md): one command on the server, which then shows address and pairing
code, then **Add Server…** in the app.

**Hosting per model:** anywhere, EU only, or EU and EEA, optionally Secure Cloud only. RunPod treats
regions as a preference, so Modlight checks where each pod landed and deletes it if it is outside.

**APIs:** OpenAI chat completions, the OpenAI Responses API (Codex) and the Anthropic Messages API
(Claude Code), on both engines.

## What has been tested

- **Rules shared across implementations** ([`spec/`](spec/README.md)): 334 cases for scheduling,
  limits, VRAM/context arithmetic, GPU suggestion, the pod request, hosting, the gateway's rewrites
  and error codes, KV cache per token and GGUF quantisations. The Swift engine passes all of them; the
  server passes all but the 11 planning cases that only the app runs (KV and GGUF analysis).
- **Server** (`server/`, `npm test`): the spec cases plus end-to-end tests against a fake RunPod and a
  fake pod: pairing, keys that never stand in for each other, keys limited to models, the limit
  checked before a wake, card fallback, Messages API pass-through, "runs until" with the watchdog's
  deadline, region check, engine failure, and that pods it did not create are never touched. The
  Swift client of the app is tested against the real Node server.
- **Engine** (`apps/mac/ModlightEngine`, `swift test`): RunPod and Hugging Face clients against
  recorded responses, GPU suggestion, pod plan, and an end-to-end run of the gateway against a fake
  RunPod and a fake vLLM.
- **Watchdog** (`tools/test_watchdog.py`): stops without heartbeat, at its deadline, when the
  engine dies; ignores a stale deadline; rejects a heartbeat without the key; reports load with every
  heartbeat and keeps answering when `nvidia-smi`, cgroups or the engine's metrics are missing; parses
  `nvidia-smi` and engine metrics as in [`spec/cases/telemetry.json`](spec/cases/telemetry.json).
- **Real hardware**: [docs/measurements-2026-11-20-e2e.md](docs/measurements-2026-11-20-e2e.md) (0.1) and
  [docs/measurements-2026-11-21-0.2.md](docs/measurements-2026-11-21-0.2.md) (EU only, no disk; two cards in one pod
  not yet verified live, RunPod had no two-card capacity in the EU) and
  [docs/measurements-2026-11-21-0.3.md](docs/measurements-2026-11-21-0.3.md) (llama.cpp with GGUF, and
  chat, Responses and Anthropic Messages with tool calls on both engines; since 0.3.1 also a real Claude Code
  run with a tool call against a 27B GGUF model) and
  [docs/measurements-2026-11-21-m2.md](docs/measurements-2026-11-21-m2.md) (the server in a container: wake,
  chat with a tool call, Messages and Responses API, the safety stop after the container was stopped,
  resume and deletion, 0.03 USD) and
  [docs/measurements-2026-11-22-telemetry.md](docs/measurements-2026-11-22-telemetry.md) (pod load on
  vLLM and llama.cpp, from the Mac and through the server) and
  [docs/measurements-2026-11-23-takeover.md](docs/measurements-2026-11-23-takeover.md) (a model taken
  over by a second Mac while running, and taken back).

## Known limits

- MLX builds are recognised and declined: they run on Apple chips only.
- Venice has been tested against its recorded catalog and a stand-in for its API, not yet with a
  paid key in a full agent session. Whether a streamed answer carries Venice's `cost` is not
  documented; without it Modlight counts tokens × the stored prices, which can differ slightly from
  Venice's bill (discounts, DIEM). Legacy `/v1/completions` is not offered for Venice models.
- Several cards in one pod (vLLM tensor parallel, llama.cpp layer split) are covered by tests and have
  been used in practice since 0.3, but are not part of the documented measurements: RunPod had no
  two-card capacity during them.
- Claude Code with other models is not officially supported by Anthropic; it works through the
  Anthropic-compatible route, without web search. A full agent session against a large model is not
  part of the measurements yet.
- On the local network the connection is plain HTTP (key required); use it only in trusted networks.
- The Windows app is not part of 0.7.
- A model belongs to one Mac at a time. A second Mac with the same RunPod key sees and can take over
  all of them, running or stopped; both Macs need 0.7. For several computers using the same models
  at once, use a server.
- Pod load is measured by the pod itself. Pods created before 0.5, including ones resumed from a kept
  disk, report none until the model starts on a new pod. llama.cpp reports no KV cache figure, and
  load on pods with several cards has not been measured live.
- The app's server screens were checked as rendered screenshots and through the app's server client
  against a real server, not yet by clicking through them on a Mac connected to a remote server.
- A request that is not streamed and takes longer than 100 seconds can be cut off by RunPod's proxy
  (Cloudflare). Agents stream, so this concerns scripts that ask for one answer at once.
- The interface audit against Apple's HIG ([`docs/hig-audit.json`](docs/hig-audit.json)) is not
  complete: VoiceOver and keyboard-only runs of every journey are still open.

## Building

```bash
brew install xcodegen
cd apps/mac/ModlightEngine && swift test
cd .. && xcodegen generate && open Modlight.xcodeproj
```

The server: `cd server && npm ci && npm test`; the image: `docker build -f server/Dockerfile .` from
the repository root. CI publishes `ghcr.io/login-tb/modlight-server` from `main`.

Releases: `tools/mac-release.sh` archives, signs with Developer ID, notarises, builds the disk image
and writes the Sparkle appcast.

## Repository

| Path | What |
|---|---|
| `apps/mac/App` | The SwiftUI app |
| `apps/mac/ModlightEngine` | Rules, RunPod, Venice and Hugging Face clients, pod lifecycle, local gateway with the Messages bridge, the client for servers |
| [`server/`](server/README.md) | Server mode: gateway, control API and pod lifecycle as a container (Node 24, Fastify, SQLite) |
| [`spec/`](spec/README.md) | Language-neutral rules and cases, the pod's start script and watchdog, the server API, help texts |
| [`docs/`](docs/) | HIG plan and audit, measurements |
| `tools/` | Release, icon, translation and watchdog tooling |

---

## Deutsch

**Dein eigenes LLM auf RunPod oder ein fertiges bei Venice, für den Coding-Agenten auf deinem Mac.**
Modell auf Hugging Face auswählen (auch GGUF), Standort, Karte und Kosten vorschlagen lassen, für eine
feste Zeit starten und OpenCode, Claude Code, Codex oder einen anderen OpenAI-kompatiblen Client damit
verbinden. Ist die Zeit um oder fragt niemand mehr an, stoppt der Pod. Das gilt auch, wenn der Mac
schläft oder Modlight beendet ist. Oder du nimmst ein fertiges Modell aus dem Katalog von Venice.ai:
abgerechnet pro Token, ohne Start, erreichbar über dieselbe Adresse und denselben Key. Modlight zeigt
Token-Kosten und Guthaben, und die Ausgabenlimits gelten für beides.

Installation: DMG von [Releases](https://github.com/LOGIN-TB/modlight/releases) laden, Modlight in
den Programme-Ordner ziehen (macOS 26 oder neuer). Beim ersten Start fragt Modlight nach deinem
RunPod- oder Venice-API-Key (oder beiden) und zeigt, wo du sie anlegst. Die eingebaute Hilfe erklärt alle Schritte auf Deutsch.

Modlight ist ein unabhängiges Projekt und steht in keiner Verbindung zu RunPod oder Venice.

## License

MIT, see [LICENSE](LICENSE).
