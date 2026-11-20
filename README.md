# Podlight

**Your own LLM on RunPod, for the coding agent on your Mac.**
Pick a model on Hugging Face, let Podlight suggest a GPU and show what it will cost, start it for
as long as you need, and point OpenCode (or any OpenAI-compatible client) at it. When the time is
up, or nobody is asking, the pod stops. It also stops when your Mac sleeps or the app is gone.

> **Status: planning and groundwork. There is no app to download yet.**
> What exists today: the design plan, the shared rule specification, and two measurements on real
> pods. Everything below describes the goal, not a finished product.

*Podlight is an independent project. It is not affiliated with or endorsed by RunPod.*

## Two ways to use it

| | **This Mac** | **Server** |
|---|---|---|
| Where the OpenAI-compatible endpoint runs | inside the Podlight app, on `127.0.0.1` | in a Docker or Coolify container |
| Good for | trying a model, coding with a local agent | agents that run while your computer is off |
| Planned in | milestone 1 | milestone 2 |

The Mac app can use both at the same time. A native Windows app follows later.

## What is here

| Path | What |
|---|---|
| [`docs/hig-plan.md`](docs/hig-plan.md) | Interface plan following Apple's Human Interface Guidelines, with 31 testable criteria |
| [`docs/hig-audit.json`](docs/hig-audit.json) | Acceptance checklist for those criteria; all still open |
| [`spec/`](spec/README.md) | Rules every implementation (Swift, Node, later C#) must pass, as language-neutral test cases |
| [`docs/measurements-2026-08-30.md`](docs/measurements-2026-08-30.md) | Model size, speed and capacity measured on real GPUs |
| [`docs/measurements-2026-11-20-dead-man-switch.md`](docs/measurements-2026-11-20-dead-man-switch.md) | Can a pod stop itself when the app disappears? Measured: yes |
| [`pod/`](pod/) | Container image that serves the model with vLLM |

## Roadmap

1. **Milestone 1: Podlight for Mac, local mode.** Setup wizard, model search, GPU suggestion,
   "run until", dead-man switch, menu bar status, signed and notarised.
2. **Milestone 2: Server mode.** The container from the predecessor project, adapted to the same rules.
3. **Milestone 3: Windows.**

Predecessor: [LOGIN-TB/runpod-launcher](https://github.com/LOGIN-TB/runpod-launcher).

---

## Deutsch

**Dein eigenes LLM auf RunPod, für den Coding-Agenten auf deinem Mac.** Modell auf Hugging Face
auswählen, GPU und Kosten vorschlagen lassen, für eine feste Zeit starten und OpenCode oder einen
anderen OpenAI-kompatiblen Client damit verbinden. Ist die Zeit um oder fragt niemand mehr an,
stoppt der Pod. Das gilt auch, wenn der Mac schläft oder die App fehlt.

> **Stand: Planung und Grundlagen. Eine App zum Herunterladen gibt es noch nicht.**

Podlight ist ein unabhängiges Projekt und steht in keiner Verbindung zu RunPod.

## License

MIT, see [LICENSE](LICENSE).
