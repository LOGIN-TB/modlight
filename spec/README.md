# spec/: what every Podlight implementation must agree on

Podlight implements the same rules more than once: in Swift inside the Mac app (local mode), in
Node in the server container, and later in C# for Windows. This folder holds those rules in a
language-neutral form, so that every implementation can be checked against one source instead of
against each other.

| Path | Contents | Status |
|---|---|---|
| `cases/scheduler.json` | When a pod starts, stops or is left alone (window, idle, runtime ceiling, spend limits, pause, manual start). 49 cases. | Recorded from the RunPod Launcher tests; the Node service and the Swift engine pass them |
| `cases/scheduler-podlight.json` | New rules: "Läuft bis" (`run-until`), wake refused at a spend limit (`admitWake`). 7 cases. | Swift engine passes them; Node service not yet (milestone 2) |
| `cases/capacity*.json`, `cases/gpu-suggest*.json` | VRAM need, context and GPU suggestion | to do |
| `data/gpus.json` | GPU table incl. memory bandwidth for the speed estimate | to do |
| `openapi.yaml` | Control API and `/v1` gateway | to do |
| `strings/` | All user-facing text, de and en | to do |
| `help/` | Help pages as Markdown | to do |

## Rules for cases

- One case = `{id, title, function, input, expected}`. An optional `status` lists the implementations
  that already pass a new rule (e.g. `"swift"`). Every test runner runs every case anyway.
- Run the Swift side with `swift test` in `apps/mac/PodlightEngine`.
- Times are ISO 8601 in UTC. Weekdays are 0 = Sunday … 6 = Saturday. Money is USD as a number.
- Never edit an `expected` value to make an implementation pass. If a rule changes, the change
  goes here first, with the reason in `title`, and every implementation follows.
- `title` explains *why* the rule exists. Several come from incidents observed on real pods.

## Open questions

- A pod stuck in `STARTING`/`PROVISIONING` is only ever stopped by a spend limit; neither the
  runtime ceiling nor "Läuft bis" applies to it (inherited from RunPod Launcher). A boot that never
  finishes can therefore bill until the limit. Needs a rule and cases before milestone 1 ships.
