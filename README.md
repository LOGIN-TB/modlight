# Podlight

**Your own LLM on RunPod, for the coding agent on your Mac.**
Pick a model on Hugging Face, let Podlight suggest a GPU and show what it will cost, start it for
as long as you need, and point OpenCode, Claude Code, Codex or any OpenAI-compatible client at it. When the time is
up, or nobody is asking, the pod stops. It also stops when your Mac sleeps or the app is gone.

> **Status: 0.3.2.** Local mode on the Mac, usable from other computers on your network, with vLLM
> and llama.cpp (GGUF), and for Claude Code and Codex as well as OpenAI-compatible agents. Built and
> tested on real RunPod hardware. See [What has been tested](#what-has-been-tested) and
> [Known limits](#known-limits).

*Podlight is an independent project. It is not affiliated with or endorsed by RunPod.*

## Install

Download `Podlight-<version>.dmg` from [Releases](https://github.com/LOGIN-TB/podlight/releases),
open it and drag Podlight to Applications. It needs macOS 26 or later. Podlight updates itself
(Podlight → Check for Updates).

On first launch Podlight asks for your RunPod API key and shows where to create one. Then:

1. **Add a model**: search Hugging Face or paste a link. Safetensors, AWQ, GPTQ, FP8 and NVFP4 run
   on vLLM; GGUF runs on llama.cpp, with the quantisation of your choice. Choose where it may run
   and the context (up to the model's own limit); Podlight suggests the cards that hold it, also
   several in one pod, with price per hour, estimated speed and data center.
2. **Start** it and choose how long it runs. A new pod takes a few minutes up to 25 (the GPU host
   downloads the engine, 9 GB for vLLM or 4 GB for llama.cpp, then the model); resuming a stopped
   one with a kept disk takes about a minute.
3. **Connect your agent**: Podlight → Connection shows the address, the key and the model name to
   copy into any OpenAI-compatible agent. Ready-made configuration for OpenCode, pi, Claude Code and
   Codex is there for experts.

The overview, Podlight's first screen, shows what runs and costs and what to do next.

The built-in help (Help → Podlight Help) explains each step in German and English.

## How it keeps costs down

- **Every start has an end.** You choose "runs until"; Podlight shows the most it can cost.
- **Idle stop.** No requests for 30 minutes (adjustable, never off): the pod stops.
- **Safety stop inside the pod.** A watchdog in every pod stops it after 15 minutes without a
  heartbeat from Podlight: Mac asleep, app quit or crashed, network gone. It uses the key RunPod
  injects into each pod, which can see and stop only that pod
  ([measured](docs/measurements-2026-11-20-dead-man-switch.md)). Your API key never leaves your Mac.
- **Spending limits** per day and month, checked before a request may wake a pod.
- **Quitting asks first** when pods run; "Stop and Quit" is the default.
- **No disk unless you want one.** Without "Keep model on disk" the pod is deleted at its end and
  nothing is billed in between; with it, restarts take a minute and the disk is billed (0.20 USD/GB
  a month while stopped), shown wherever costs appear. Kept disks are deleted after three days unused.

## Two ways to use it

| | **This Mac** (0.3) | **Server** (planned) |
|---|---|---|
| Where the OpenAI-compatible endpoint runs | inside Podlight, on `127.0.0.1:7635`, optionally for the local network | in a Docker or Coolify container |
| Good for | trying a model, coding with agents on this Mac or your network | agents that run while your computer is off |

**Hosting per model:** anywhere, EU only, or EU and EEA, optionally Secure Cloud only. RunPod treats
regions as a preference, so Podlight checks where each pod landed and deletes it if it is outside.

**APIs:** OpenAI chat completions, the OpenAI Responses API (Codex) and the Anthropic Messages API
(Claude Code), on both engines.

Until server mode lands, the container of the predecessor
[LOGIN-TB/runpod-launcher](https://github.com/LOGIN-TB/runpod-launcher) covers that case.

## What has been tested

- **Rules shared across implementations** ([`spec/`](spec/README.md)): 158 cases for scheduling,
  limits, VRAM/context arithmetic, KV cache per token and GGUF quantisations, 140 of them recorded from the
  predecessor's tested code. The Swift engine passes all of them.
- **Engine** (`apps/mac/PodlightEngine`, `swift test`): RunPod and Hugging Face clients against
  recorded responses, GPU suggestion, pod plan, and an end-to-end run of the gateway against a fake
  RunPod and a fake vLLM.
- **Watchdog** (`tools/test_watchdog.py`): stops without heartbeat, at its deadline, when the
  engine dies; ignores a stale deadline; rejects a heartbeat without the key.
- **Real hardware**: [docs/measurements-2026-11-20-e2e.md](docs/measurements-2026-11-20-e2e.md) (0.1) and
  [docs/measurements-2026-11-21-0.2.md](docs/measurements-2026-11-21-0.2.md) (EU only, no disk; two cards in one pod
  not yet verified live, RunPod had no two-card capacity in the EU) and
  [docs/measurements-2026-11-21-0.3.md](docs/measurements-2026-11-21-0.3.md) (llama.cpp with GGUF, and
  chat, Responses and Anthropic Messages with tool calls on both engines; since 0.3.1 also a real Claude Code
  run with a tool call against a 27B GGUF model).

## Known limits

- MLX builds are recognised and declined: they run on Apple chips only.
- Several cards in one pod (vLLM tensor parallel, llama.cpp layer split) are covered by tests but not
  yet verified on real hardware: RunPod had no two-card capacity during the measurements.
- Claude Code with other models is not officially supported by Anthropic; it works through the
  Anthropic-compatible route, without web search. A full agent session against a large model is not
  part of the measurements yet.
- On the local network the connection is plain HTTP (key required); use it only in trusted networks.
- Server mode and the Windows app are not part of 0.3.
- The interface audit against Apple's HIG ([`docs/hig-audit.json`](docs/hig-audit.json)) is not
  complete: VoiceOver and keyboard-only runs of every journey are still open.

## Building

```bash
brew install xcodegen
cd apps/mac/PodlightEngine && swift test
cd .. && xcodegen generate && open Podlight.xcodeproj
```

Releases: `tools/mac-release.sh` archives, signs with Developer ID, notarises, builds the disk image
and writes the Sparkle appcast.

## Repository

| Path | What |
|---|---|
| `apps/mac/App` | The SwiftUI app |
| `apps/mac/PodlightEngine` | Rules, RunPod and Hugging Face clients, pod lifecycle, local gateway, the pod's start script and watchdog |
| [`spec/`](spec/README.md) | Language-neutral rules, GPU table and help texts, shared with the planned Windows app |
| [`docs/`](docs/) | HIG plan and audit, measurements |
| `tools/` | Release, icon, translation and watchdog tooling |

---

## Deutsch

**Dein eigenes LLM auf RunPod, für den Coding-Agenten auf deinem Mac.** Modell auf Hugging Face
auswählen (auch GGUF), Standort, Karte und Kosten vorschlagen lassen, für eine feste Zeit starten
und OpenCode, Claude Code, Codex oder einen anderen OpenAI-kompatiblen Client damit verbinden. Ist die Zeit um oder fragt niemand mehr an,
stoppt der Pod. Das gilt auch, wenn der Mac schläft oder Podlight beendet ist.

Installation: DMG von [Releases](https://github.com/LOGIN-TB/podlight/releases) laden, Podlight in
den Programme-Ordner ziehen (macOS 26 oder neuer). Beim ersten Start fragt Podlight nach deinem
RunPod-API-Key und zeigt, wo du ihn anlegst. Die eingebaute Hilfe erklärt alle Schritte auf Deutsch.

Podlight ist ein unabhängiges Projekt und steht in keiner Verbindung zu RunPod.

## License

MIT, see [LICENSE](LICENSE).
