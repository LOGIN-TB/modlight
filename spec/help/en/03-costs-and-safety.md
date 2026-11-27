# Costs and Safety

A rented pod costs money while it runs, whether anyone uses it or not. Modlight stops it in several ways.

## Every start has an end

When you start, you choose "Runs until", two hours for example, or a time of day. Modlight shows the most it can cost. You can extend it while it runs, in the model or with "Model → Extend by One Hour".

![A running model](screenshots/en/models.png)

## Idle stop

When no request comes in for a while, the pod stops, after 30 minutes by default. It cannot be switched off, only shortened or lengthened.

## Safety stop inside the pod

Every pod runs a small watchdog. If it hears nothing from Modlight for 15 minutes, it stops the pod itself. That covers a sleeping Mac, a crashed Modlight or a lost network. It uses a key RunPod puts into every pod that can control only that pod. Your own API key never leaves your Mac.

## Spending limits

Under Settings → General you set how much Modlight may spend per day and per month. At a limit, Modlight stops the pods and does not start them again until the next day or month, not even when an agent asks.

Models at Venice count too: Modlight adds their per-token costs to the same limits and sends no more requests to Venice once a limit is reached. More under "Venice".

![The Costs view](screenshots/en/costs.png)

"Costs" opens with tiles for what is spent today and this month, what is billed per hour right now, and how long your RunPod and Venice credit lasts. The limits and the chart of the last 30 days are split into pods (green) and Venice (blue). Below are the Venice models by this month's cost and the pods with what they cost while running.

The figures are Modlight's own count: price per hour times running time for pods, each answer's cost for Venice. RunPod's and Venice's billing is authoritative. RunPod credit covers the whole account, other pods included; under a day of runway its tile turns orange.

The refresh button in the toolbar (⌘R) asks RunPod and every server at once. A pod you deleted in RunPod's console disappears from Modlight within seconds anyway.

## Quitting Modlight

With pods still running, Modlight asks before quitting. "Stop and Quit" is the default. If you keep them running, your agent can no longer reach them, and the safety stop ends them after the set time.

Closing the window does not quit Modlight. It keeps running in the menu bar, and your agent stays connected.

## Keep model on disk

For each model you decide whether it stays on a disk at RunPod between runs:

- **Off (default):** at the end of a run Modlight deletes the pod. Nothing is billed until the next start. Each start downloads the model again, which takes 10 to 25 minutes.
- **On:** the pod is only stopped and keeps its disk. The next start takes about a minute. RunPod charges 0.20 USD per GB and month for the disk while the pod is stopped, 0.10 USD while it runs. It is billed by the hour: for 30 GB that is about 0.008 USD an hour while stopped, or 6 USD a month.

Modlight shows these costs per hour and per month when you add a model, when you start it and on the model's page. "Costs" lists every model with what it costs right now: the GPU and storage while it runs, the kept disk while it is stopped, otherwise nothing. Modlight counts these costs towards your spending limits. Pods with a disk left unused for longer than the period in Settings (3 days by default) are deleted, disk included, never earlier. If the card on the pod's machine is taken when it resumes, the pod and its disk are kept. Modlight then tries again every 30 seconds until the end you chose when you started it, and resumes the pod as soon as the card is free. Meanwhile the model shows "Waiting for a card". "Stop Waiting" cancels this. "Start on a New Card…" builds a new pod and downloads the model again. The old pod and its disk stay until the new one answers; if the new one fails, the old one is kept. Change the switch under "Edit" while the model is stopped.
