# Podlight

**Your own LLM on RunPod, for the coding agent on your Mac.**
Pick a model on Hugging Face, let Podlight suggest a GPU and show what it will cost, start it for
as long as you need, and point OpenCode (or any OpenAI-compatible client) at it. When the time is
up, or nobody is asking, the pod stops. It also stops when your Mac sleeps or the app is gone.

> **Status: 0.1.0, first version.** Local mode on the Mac is built and tested, including a full run
> on real RunPod hardware. See [What has been tested](#what-has-been-tested) for exactly what, and
> [Known limits](#known-limits) for what 0.1 does not do yet.

*Podlight is an independent project. It is not affiliated with or endorsed by RunPod.*

## Install

Download `Podlight-<version>.dmg` from [Releases](https://github.com/LOGIN-TB/podlight/releases),
open it and drag Podlight to Applications. It needs macOS 26 or later. Podlight updates itself
(Podlight → Check for Updates).

On first launch Podlight asks for your RunPod API key and shows where to create one. Then:

1. **Add a model**: search Hugging Face or paste a link. Podlight checks it and suggests a GPU,
   with price per hour and an estimated speed.
2. **Start** it and choose how long it runs. The first start downloads the model (3–10 minutes).
3. **Connect OpenCode**: Podlight → Connection → *Copy OpenCode Configuration*, paste it into
   `~/.config/opencode/opencode.json`, pick `podlight/<name>` with `/models`.

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
- Stopped pods keep their disk for a fast restart and are deleted after three days unused.

## Two ways to use it

| | **This Mac** (0.1) | **Server** (planned) |
|---|---|---|
| Where the OpenAI-compatible endpoint runs | inside Podlight, on `127.0.0.1:7635` | in a Docker or Coolify container |
| Good for | trying a model, coding with a local agent | agents that run while your computer is off |

Until server mode lands, the container of the predecessor
[LOGIN-TB/runpod-launcher](https://github.com/LOGIN-TB/runpod-launcher) covers that case.

## What has been tested

- **Rules shared across implementations** ([`spec/`](spec/README.md)): 147 cases for scheduling,
  limits and VRAM/context arithmetic, 140 of them recorded from the predecessor's tested code. The
  Swift engine passes all of them.
- **Engine** (`apps/mac/PodlightEngine`, `swift test`): RunPod and Hugging Face clients against
  recorded responses, GPU suggestion, pod plan, and an end-to-end run of the gateway against a fake
  RunPod and a fake vLLM.
- **Watchdog** (`tools/test_watchdog.py`): stops without heartbeat, at its deadline, when the
  engine dies; ignores a stale deadline; rejects a heartbeat without the key.
- **Real hardware**: see [docs/measurements-2026-11-20-e2e.md](docs/measurements-2026-11-20-e2e.md).

## Known limits

- vLLM only: GGUF (llama.cpp) and MLX builds are recognised and declined.
- No notifications yet when a run is about to end; the menu bar shows the time left.
- Server mode and the Windows app are not part of 0.1.
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
auswählen, Karte und Kosten vorschlagen lassen, für eine feste Zeit starten und OpenCode oder einen
anderen OpenAI-kompatiblen Client damit verbinden. Ist die Zeit um oder fragt niemand mehr an,
stoppt der Pod. Das gilt auch, wenn der Mac schläft oder Podlight beendet ist.

Installation: DMG von [Releases](https://github.com/LOGIN-TB/podlight/releases) laden, Podlight in
den Programme-Ordner ziehen (macOS 26 oder neuer). Beim ersten Start fragt Podlight nach deinem
RunPod-API-Key und zeigt, wo du ihn anlegst. Die eingebaute Hilfe erklärt alle Schritte auf Deutsch.

Podlight ist ein unabhängiges Projekt und steht in keiner Verbindung zu RunPod.

## License

MIT, see [LICENSE](LICENSE).
