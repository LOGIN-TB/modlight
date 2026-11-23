# spec/: what every Podlight implementation must agree on

Podlight implements the same rules more than once: in Swift inside the Mac app (local mode), in
Node in the server container, and later in C# for Windows. This folder holds those rules in a
language-neutral form, so that every implementation can be checked against one source instead of
against each other.

| Path | Contents | Status |
|---|---|---|
| `cases/scheduler.json` | When a pod starts, stops or is left alone (window, idle, runtime ceiling, spend limits, pause, manual start). 49 cases. | Recorded from the RunPod Launcher tests; Swift and the server pass them |
| `cases/scheduler-podlight.json` | "Läuft bis" (`run-until`), wake refused at a spend limit (`admitWake`). 7 cases. | Swift and the server |
| `cases/capacity.json` | VRAM need, context and concurrency per card, card support for FP8/NVFP4. 91 cases. | Swift and the server |
| `cases/gpu-suggest.json` | Which cards are offered for a model, best first per goal, under each hosting policy. | Recorded from Swift (0.3.2); Swift and the server |
| `cases/pod-plan.json` | The pod request (image, env, disks, command) and the order of cards tried. | Recorded from Swift; Swift and the server |
| `cases/hosting.json` | Regions, Secure Cloud, placement check, data centers to request, storage prices. | Recorded from Swift; Swift and the server |
| `cases/gateway.json` | System entries rewritten for the Messages API, error status and codes, the served-name rule, the engine-log summary. | Recorded from Swift; Swift and the server |
| `cases/kv-profile.json`, `cases/gguf.json` | KV cache per token from `config.json` or a GGUF header; GGUF quantisations. | Planning, done in the app only (`status: swift`) |
| `cases/telemetry.json` | What the pod's watchdog reads from `nvidia-smi` and the engine's `/metrics` (requests, KV cache, token rates). | Parsed in the pod only (`status: pod`), run by `tools/test_watchdog.py`; the app and the server store and show the result |
| `fixtures/catalog.json` | A RunPod GPU catalog the card cases are computed against. | |
| `data/gpus.json` | Memory bandwidth per card for the speed estimate. | Swift bundles a byte-identical copy (tested) |
| `data/regions.json` | Region prefixes and RunPod storage prices. | The server reads it; Swift's constants are tested against it |
| `pod/boot.sh`, `pod/watchdog.py` | The pod's start script and dead-man switch. | The server sends these; Swift bundles byte-identical copies (tested) |
| `schema/model.json` | The model both sides store (JSON Schema). | Generated from `server/src/model.ts` |
| `openapi.json` | The server's gateway and control API. | Generated from the server; CI fails when stale |
| `help/` | Help pages as Markdown, de and en, with screenshots. | Bundled into the Mac app |

## Rules for cases

- One case = `{id, title, function, input, expected}`. An optional `status` lists the implementations
  that already pass a new rule (e.g. `"swift"`). Every test runner runs every case anyway.
- Run the Swift side with `swift test` in `apps/mac/PodlightEngine`, the server with `npm test` in
  `server/`. Cases recorded from Swift come from `SpecRecorder.swift` (`PODLIGHT_RECORD_SPEC=1`), run
  once per rule; after that the expected values are the contract.
- Times are ISO 8601 in UTC. Weekdays are 0 = Sunday … 6 = Saturday. Money is USD as a number.
- Never edit an `expected` value to make an implementation pass. If a rule changes, the change
  goes here first, with the reason in `title`, and every implementation follows.
- `title` explains *why* the rule exists. Several come from incidents observed on real pods.

## Open questions

- A pod stuck in `STARTING`/`PROVISIONING` is only ever stopped by a spend limit; neither the
  runtime ceiling nor "Läuft bis" applies to it (inherited from RunPod Launcher). A boot that never
  finishes can therefore bill until the limit. Needs a rule and cases before milestone 1 ships.
