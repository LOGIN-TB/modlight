# Getting Started

Podlight runs a language model of your choice on a rented GPU at RunPod. Your coding agent on this Mac, OpenCode for example, then talks to that model as it would to an OpenAI service.

## The overview

Podlight opens with the overview. At the top it shows what is running and what it costs per hour; below that the next steps up to your first connected agent, spending against your limits, your models with "Start", and the address for agents. Once every step is done, the list disappears.

![The overview](screenshots/en/overview.png)

## What you need

- A RunPod account with some credit. You are billed per minute while a pod runs.
- A RunPod API key. Podlight takes you there on first launch.
- Optionally a Hugging Face token, only for gated models such as Llama or Gemma.

## Creating the RunPod API key

- In Podlight, open setup (Help → Run Setup Again) and click "Open RunPod Settings".
- Sign in. Under "API Keys", click "Create API Key" and name it "Podlight".
- Choose the permission "All", or "Restricted" with read and write access to Pods.
- Copy the key and paste it into Podlight. RunPod shows it only once.
- "Check and Save" tests the key straight away. Podlight keeps it in this Mac's keychain and only ever sends it to RunPod.

![The API key step in Podlight](screenshots/en/setup-key.png)

## Hugging Face token (recommended)

Setup offers a Hugging Face token as its second step. It is optional but recommended: pods download models over addresses RunPod shares with other customers, and Hugging Face limits downloads without an account more strictly. Gated models such as Llama or Gemma require one. A token with read access is enough.

## Your first model

- Under "Models", click "Add Model".
- Search by name, or paste a link from huggingface.co.
- Podlight checks the format, the size, and whether the model can make tool calls, which coding agents need. If there is a smaller 4-bit build, Podlight suggests it.
- Choose where the pod may run (anywhere, EU only, EU and EEA, optionally Secure Cloud only). It starts with what Settings say; the choice applies to this model only.
- Choose the context and what matters to you: economical, balanced or fast. Podlight shows how much card memory the model needs for it, and suitable cards with their price per hour, an estimated speed and where they are. Change the context and the list follows.
- Give it a name. Your agent asks for the model by this name.
- Decide whether to keep the model on disk (fast restarts, but billed while stopped) or not (the default).

None of this costs anything. "Add and Start" goes straight to starting it; "Add Only" sets up the model without renting a card.

## Starting

You find "Start" with the model, right below its status, on the overview, and at the top right of the toolbar. It asks how long the pod should run and shows the cost until then. A new pod takes 10 to 25 minutes: the RunPod host first downloads the engine (about 9 GB for vLLM, 4 GB for llama.cpp), then the model. Measured: 22 minutes for a small model. Resuming a stopped pod takes about a minute (measured: 64 seconds), because it keeps its disk.


![Starting with "Runs until"](screenshots/en/start.png)

## Without a pod: Venice

Instead of renting a card, you can also use a ready model from Venice.ai. It answers right away and is billed per token instead of per hour. You need an account and an API key at Venice. "Venice" explains how.
