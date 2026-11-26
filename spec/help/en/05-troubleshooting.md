# Troubleshooting

## "RunPod does not know this key"

The key was not copied completely, or it was revoked. Create a new one at RunPod and paste it under Settings → Providers and access.

## "No free card at RunPod"

Every suitable card was taken at that moment. Try again in a few minutes, or set the model's goal to "Fast", which allows more card types.

## "Your card is taken" with a list of pricier cards

Your card was taken and the free ones cost more than a replacement may (Settings → "Another card may cost more by"). Nothing was booked. Choose one of the cards, wait for Podlight to find one within the price, or allow a higher extra cost.

## The start takes long

A new pod first downloads the engine (about 9 GB), then the model. Then vLLM starts, which alone takes about two minutes. Up to 25 minutes is normal while Podlight shows "Loading the model". Resuming is faster because the pod keeps its disk.

## "This model needs a Hugging Face token"

Some publishers release their models only after you agree to their terms. Open the model page on huggingface.co, accept the terms, and add a token with read access under Settings → Providers and access.

## "RunPod placed the pod outside your chosen region"

RunPod treats the chosen region as a preference only. Podlight deleted the pod before it answered anything. Start again; usually the next attempt works. If it keeps happening, allow "EU and EEA" under Settings → Hosting or switch off "Secure Cloud only".

## OpenCode gets no answer

- Check that "Connection" says "Agents on this Mac can connect now."
- Check that the key in `opencode.json` is current. After "Create New Key" it has to be replaced there.
- Is the model name right? `/v1/models` returns the names Podlight knows.

## A pod kept running after Podlight closed

Podlight had quit, and the pod's safety stop ends it only after the set time without contact, 15 minutes by default. Next time you open Podlight, the model shows that it was stopped outside Podlight. If in doubt, check the RunPod console: it is the authoritative list of running pods.

## "Start test failed", or Claude Code says "exceeded the 32000 output token maximum"

After every start Podlight asks the model a short question. If it answers only with repeated characters such as "!!!!", Podlight stops the pod at once. Such a model never stops writing on its own, and Claude Code then cuts every answer off at its length limit. The cause is usually a broken quantisation, or a kernel that computes wrongly on this card. Use another build of the model, such as the publisher's GGUF, or another card type.

## "The RunPod machine could not use its card"

The engine stopped with a CUDA error before it loaded the model. That is the machine at RunPod, not the model. Start with "Start on a New Card…", or choose another card type under Edit. "Show Engine Log…" shows the engine's last lines.

## "The engine made no progress for 10 minutes while loading"

While a model loads, Podlight checks that something happens: the disk fills with the download, the engine's log grows, the engine takes graphics memory or computes. If all of that stands still for ten minutes, the engine has hung, usually on a stalled download on that machine. Podlight then stops the pod instead of letting it run, and cost, until the end you chose. Start again, or use "Start on a New Card…" to get another machine.
