# Models and GPUs

## Which model?

Coding agents need models that can make tool calls. Podlight reads this from the model's chat template and shows it during the check. Without it, an agent cannot read files or run commands.

4-bit builds (AWQ, GPTQ, INT4) need about half the memory of the originals. In one measurement, the same 27-billion-parameter model on the same card ran more than twice as fast in 4 bits and had twice the room for context.

Podlight 0.1 runs models with vLLM. GGUF files (llama.cpp) and MLX builds do not run with it. Podlight says so during the check and suggests alternatives.

## Economical, balanced or fast

- **Economical** puts the cheapest card the model fits on first.
- **Balanced** picks, among cards managing about 15 tokens per second or more, the best speed for the price.
- **Fast** puts the fastest card first.

The speed is an estimate from the card's memory bandwidth, and usually below what is actually reached.

## When the card is taken

Free cards are scarce at RunPod and change within seconds. If your card is taken when you start, Podlight tries the next ones from the suggestion list, as long as they hold the configured context. The model then shows which card it got.

## Context

Context is how much text the model sees at once. Coding agents need a lot of it. When you add a model you choose it first, up to the model's maximum, including 256,000 or 1 million tokens. Podlight then shows only cards that hold it.

Podlight reads how much memory one token needs from the model's configuration. Small models need much less per token than large ones, so very long contexts fit on smaller cards for them. Podlight keeps a margin, so vLLM does not refuse to start after the download.

## Several cards

If a long context does not fit on one card, Podlight suggests 2, 4 or 8 cards in one pod, for example "2 × L40S". vLLM then spreads the model across all of them. The price covers all cards together. Getting several identical cards free at once is harder at RunPod; if needed, Podlight tries the next suggestions.
