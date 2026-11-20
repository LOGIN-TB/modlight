# Troubleshooting

## "RunPod does not know this key"

The key was not copied completely, or it was revoked. Create a new one at RunPod and paste it under Settings → Access.

## "No free card at RunPod"

Every suitable card was taken at that moment. Try again in a few minutes, or set the model's goal to "Fast", which allows more card types.

## The start takes long

A new pod first downloads the engine (about 9 GB), then the model. Then vLLM starts, which alone takes about two minutes. Up to 25 minutes is normal while Podlight shows "Loading the model". Resuming is faster because the pod keeps its disk.

## "This model needs a Hugging Face token"

Some publishers release their models only after you agree to their terms. Open the model page on huggingface.co, accept the terms, and add a token with read access under Settings → Access.

## OpenCode gets no answer

- Check that "Connection" says "Agents on this Mac can connect now."
- Check that the key in `opencode.json` is current. After "Create New Key" it has to be replaced there.
- Is the model name right? `/v1/models` returns the names Podlight knows.

## A pod kept running after Podlight closed

Podlight had quit, and the pod's safety stop ends it only after the set time without contact, 15 minutes by default. Next time you open Podlight, the model shows that it was stopped outside Podlight. If in doubt, check the RunPod console: it is the authoritative list of running pods.
