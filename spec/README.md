# spec/: what every Podlight implementation must agree on

Podlight implements the same rules more than once: in Swift inside the Mac app (local mode), in
Node in the server container, and later in C# for Windows. This folder holds those rules in a
language-neutral form, so that every implementation can be checked against one source instead of
against each other.

| Path | Contents | Status |
|---|---|---|
| `cases/scheduler.json` | When a pod starts, stops or is left alone (window, idle, runtime ceiling, spend limits, pause, manual start). 49 cases. | Recorded from the RunPod Launcher tests; the Node service passes them |
| `cases/scheduler-podlight.json` | New rules: "Läuft bis" (`run-until`), wake refused at a spend limit (`admitWake`). | **proposed**, no implementation yet |
| `cases/capacity*.json`, `cases/gpu-suggest*.json` | VRAM need, context and GPU suggestion | to do |
| `data/gpus.json` | GPU table incl. memory bandwidth for the speed estimate | to do |
| `openapi.yaml` | Control API and `/v1` gateway | to do |
| `strings/` | All user-facing text, de and en | to do |
| `help/` | Help pages as Markdown | to do |

## Rules for cases

- One case = `{id, title, function, input, expected}`; `status: "proposed"` marks rules that are
  agreed but not yet built. A test runner must run proposed cases too and report them separately.
- Times are ISO 8601 in UTC. Weekdays are 0 = Sunday … 6 = Saturday. Money is USD as a number.
- Never edit an `expected` value to make an implementation pass. If a rule changes, the change
  goes here first, with the reason in `title`, and every implementation follows.
- `title` explains *why* the rule exists. Several come from incidents observed on real pods.
