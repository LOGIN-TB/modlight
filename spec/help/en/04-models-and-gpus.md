# Models and GPUs

## Which model?

Coding agents need models that can make tool calls. Podlight reads this from the model's chat template and shows it during the check. Without it, an agent cannot read files or run commands.

4-bit builds (AWQ, GPTQ, NVFP4 or GGUF in Q4) need about half the memory of the originals. In one measurement, the same 27-billion-parameter model on the same card ran more than twice as fast in 4 bits and had twice the room for context.

## GGUF models

Many models on Hugging Face exist only as GGUF. Podlight runs them with llama.cpp and every other format with vLLM. Podlight picks the engine from the format.

A GGUF repository usually holds the model in many quantisations, such as Q4_K_M, Q8_0 or BF16. You pick one during the check; Podlight suggests Q4_K_M, llama.cpp's own default. As a rule of thumb, 4 bits need half the memory of 8 bits and lose little. Below 4 bits (Q2, Q3) models get noticeably worse at code and tool calls. Q8_0 and BF16 are close to the original but need two to four times the memory.

Podlight reads how much memory a token needs from the GGUF file's header, without downloading the model. llama.cpp's engine is about 4 GB, much smaller than vLLM's, so a new pod is often ready sooner. MLX builds run on Apple chips only, not at RunPod.

## Economical, balanced or fast

- **Economical** puts the cheapest card the model fits on first.
- **Balanced** picks, among cards managing about 15 tokens per second or more, the best speed for the price.
- **Fast** puts the fastest card first.

The speed is an estimate from the card's memory bandwidth, and usually below what is actually reached.

## When the card is taken

Free cards are scarce at RunPod and change within seconds. If your card is taken when you start, Podlight tries the next ones from the suggestion list, as long as they hold the configured context. The model then shows which card it got, and in orange when it costs more than yours.

A replacement may cost at most 50 % more than your card; set this under Settings → "Another card may cost more by" (for a server, in its Server Settings). Above that Podlight books nothing:

- **Started by hand:** the start window says your card is taken and lists the free, pricier cards with their price and how much more they cost. Start on one of them, or let Podlight wait.
- **Waiting:** Podlight tries every 30 seconds until the run's end for a card within the price and then starts by itself. The model's page shows "Waiting for a Card" and the cheapest free card, which you can still choose. "Stop Waiting" ends it.
- **Woken by an agent, or started by a server:** nobody can be asked, so Podlight waits for half an hour without booking the pricier card. The agent gets an error that says why.

![The start asks before a pricier card](screenshots/en/start-price.png)

## Context

Context is how much text the model sees at once. Coding agents need a lot of it. When you add a model you choose it first, up to the model's maximum, including 256,000 or 1 million tokens. Podlight then shows only cards that hold it.

Podlight reads how much memory one token needs from the model's configuration. Small models need much less per token than large ones, so very long contexts fit on smaller cards for them. Podlight keeps a margin, so vLLM does not refuse to start after the download.

## Several cards

If a long context does not fit on one card, Podlight suggests 2, 4 or 8 cards in one pod, for example "2 × L40S". vLLM then spreads the model across all of them, which also makes it faster. llama.cpp spreads the model's layers across the cards: more room, but no extra speed for a single request. The price covers all cards together. Getting several identical cards free at once is harder at RunPod; if needed, Podlight tries the next suggestions.

## Usage

While a model runs, its page shows what the pod is doing under "Usage":
- **Rings** for GPU load, graphics memory in use (VRAM), CPU, memory and disks, one set per card when there are several. Memory and disks turn orange from 85 % and red from 95 %.
- **Tiles with the engine's figures:**
  - **Writing** and **Reading:** tokens per second while answering and while reading the prompt, over the latest requests. Between requests the last value stays.
  - **Prompt cache:** the share of prompt tokens taken from the cache instead of being read again. Agents such as Claude Code send the whole conversation with every request; a high share makes answers quick.
  - **Requests** (running and waiting), with vLLM the **Context cache**, **Since the start** (tokens read and written) and the **Card** with temperature and power.
- **A chart** of the last 30 minutes.

The model list, the overview and the menu bar show the GPU load beside every running model.

The pod measures this itself, about every 10 seconds, because RunPod's API does not report graphics memory in use. vLLM taking almost all graphics memory is normal: it reserves it for the context cache when it starts. GPU load and tokens per second show whether the model is working.

Pods created by an earlier Podlight version report no usage, also when they are resumed with "Keep model on disk". The figures appear once the model starts on a new pod.

## On several Macs

A model belongs to the Mac you added it on. Podlight also keeps each model in your RunPod account, out of sight and free of charge. A second Mac with the same RunPod key therefore lists all of the first Mac's models, running and stopped, under "From other Macs" in the overview. It looks every minute, or at once with the arrow next to the heading.

"Start…" moves a stopped model to this Mac and then asks how long it should run. "Take Over" moves it without starting it. From then on this Mac starts, stops and bills it, and your agents connect to it.

The first Mac lets go within a minute, or the next time it runs, and shows "Managed by …". It leaves the model alone, and requests from its agents for that model are told to use the other Mac. "Take Back" moves the model back to it. Deleting a model another Mac took over removes it from this Mac only.

Both Macs need Podlight 0.7 or later. Models of a Mac with an older version appear only while they have a pod. For several computers using the same models at once, a Podlight server is the better fit.
