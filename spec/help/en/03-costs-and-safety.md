# Costs and Safety

A rented pod costs money while it runs, whether anyone uses it or not. Podlight stops it in several ways.

## Every start has an end

When you start, you choose "Runs until", two hours for example, or a time of day. Podlight shows the most it can cost. You can extend it while it runs, in the model or with "Model → Extend by One Hour".

![A running model](screenshots/en/models.png)

## Idle stop

When no request comes in for a while, the pod stops, after 30 minutes by default. It cannot be switched off, only shortened or lengthened.

## Safety stop inside the pod

Every pod runs a small watchdog. If it hears nothing from Podlight for 15 minutes, it stops the pod itself. That covers a sleeping Mac, a crashed Podlight or a lost network. It uses a key RunPod puts into every pod that can control only that pod. Your own API key never leaves your Mac.

## Spending limits

Under Settings → General you set how much Podlight may spend per day and per month. At a limit, Podlight stops the pods and does not start them again until the next day or month, not even when an agent asks.

![The Costs view](screenshots/en/costs.png)

The figures under "Costs" are Podlight's own count: price per hour times running time, for this Mac's pods only. RunPod's billing is authoritative.

## Quitting Podlight

With pods still running, Podlight asks before quitting. "Stop and Quit" is the default. If you keep them running, your agent can no longer reach them, and the safety stop ends them after the set time.

Closing the window does not quit Podlight. It keeps running in the menu bar, and your agent stays connected.

## Keep model on disk

For each model you decide whether it stays on a disk at RunPod between runs:

- **Off (default):** at the end of a run Podlight deletes the pod. Nothing is billed until the next start. Each start downloads the model again, which takes 10 to 25 minutes.
- **On:** the pod is only stopped and keeps its disk. The next start takes about a minute. RunPod charges 0.20 USD per GB and month for the disk while the pod is stopped, 0.10 USD while it runs. For 30 GB that is about 6 USD a month.

Podlight shows these costs when you add a model, when you start it and under "Costs", and counts them towards your spending limits. Pods with a disk left unused for three days are deleted, disk included. Change the switch under "Edit" while the model is stopped.
