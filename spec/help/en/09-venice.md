# Venice

Venice.ai is a second provider next to RunPod. Instead of renting a card and loading a model onto it, you pick a ready model from Venice's catalog. It answers right away; there is no pod. You pay per token, so only for what your agent actually sends and receives. For the agent nothing changes: same address, same key, and the model is called whatever you name it in Podlight.

![A Venice model in Podlight](screenshots/en/venice-model.png)

## Pod or Venice?

- **Venice** suits you when you need a model only now and then, don't want to wait 10 to 25 minutes for a start, or want a large model that would need expensive cards. Without requests it costs nothing.
- **A pod** suits you when you want a particular model from Hugging Face that Venice doesn't offer, when you want to choose the region it runs in, or when an agent works for hours on end. A fixed price per hour is then often cheaper than many millions of tokens.

You can mix both. An agent can use a Venice model and a pod model side by side.

## A Venice account

Create an account on venice.ai. The API needs credit; a free account alone is not enough.

## Topping up

Venice has several kinds of credit:

- **USD credit:** you top it up by card or crypto. It does not expire.
- **Plan credit:** the Pro, Plus and Max plans include a monthly allowance for the API.
- **DIEM:** if you stake DIEM tokens, each DIEM gives you about 1 USD of credit per day. It is good for that day and refills the next.

Venice deducts in this order: DIEM first, then earned credit, then plan credit, USD last. When all of it is used up, Venice refuses requests with error 402.

## Creating an API key

- Open https://venice.ai/settings/api and click "Generate New API Key".
- "Inference Only" is enough as the type. Podlight does not need an Admin key.
- If you like, set an expiry date and a daily limit in USD or DIEM. Venice then refuses anything beyond it, regardless of Podlight.
- Copy the key. Venice shows it only this once. It starts with `VENICE_INFERENCE_KEY_`.

## Adding the key to Podlight

Paste the key under Settings → Providers and access, or during setup when Podlight asks about Venice. Podlight checks it right away and shows your Venice balance and plan. The key is kept in this Mac's keychain and only sent to Venice.

![The Venice key step](screenshots/en/setup-venice.png)

## Adding a Venice model

- Click "Add Model…" and choose "Ready model at Venice · per token" at the top of the sheet.
- Search the catalog by name. Filters narrow the list: by privacy (see below) and by abilities such as tool calls, vision, reasoning and code. Coding agents need tool calls.
- Each model shows its price per 1 million tokens for input and output, and its context length.
- Give it a name. Your agent asks for the model by this name.

The model is now ready. There is nothing to start.

![The Venice catalog with filters and prices](screenshots/en/add-venice.png)

### Private and Anonymized

Venice sorts its models into two tiers:

- **Private:** Venice runs the model itself and keeps neither requests nor answers. Only these are listed until you tick "Include anonymized".
- **Anonymized:** models from other providers such as Claude, GPT or Gemini. Venice forwards the request and first removes what points to you, such as your account and IP address. The provider still sees the content, though, and its own retention rules apply.

If your agent sends code that must not leave your hands, stay with "Private".

## Using it

You reach a Venice model like any other model in Podlight: with the address and key under "Connection" and the name you gave it. This works with OpenCode, Codex, Claude Code and any program that speaks to OpenAI. For Claude Code, Podlight translates between the Anthropic interface and Venice's. You don't have to change an existing configuration, only the model name.

## Costs and limits

A Venice model's page shows live what it does and costs:

- **Cost today** and, while an agent works, the cost per hour right now.
- **Cache hits:** the share of input that came from Venice's cache. Green from 60 %, orange below, red under 30 %.
- **Writing** and **first token:** how fast answers come, each next to the median Venice measures for everyone on this model.
- **Avg. context:** how much conversation an agent sends per request.
- **Tokens per minute** over the last half hour, split into new input, cached input and output, next to Venice's **rate limits** as the latest answer reported them, the daily limit, and how long the balance lasts at the current rate.
- **Cost today by hour.**

![A Venice model's page](screenshots/en/venice-model.png)

### Cache and costs

An agent sends the whole conversation with every request, often tens of thousands of tokens, so the input price usually matters more than the output price. When the start of a request is already in Venice's cache, that part costs a fraction, about a fifth for many models.

Venice spreads requests over several machines, though, and without a hint the next request often lands on one that does not know the start. Since 0.12 Podlight therefore sends a fixed cache key (`prompt_cache_key`) per agent and system prompt. If your agent sets one itself, its own is kept. "What today's cost is for" shows how the cost splits into new input, cache and output; when the cache barely helps, Podlight estimates there what the day would have cost at 70 %.

Podlight checks your Venice balance regularly. The refresh button in the toolbar (⌘R) checks right away.

The spending limits under Settings → Costs and safety (or under Costs) cover pods and Venice together. At a limit, Podlight sends no more requests to Venice until the next day or month. A daily limit on the key itself (see above) applies on top, directly at Venice.

### When Venice refuses

- **No credit (error 402):** top up at Venice. If you only use DIEM, the credit comes back the next day.
- **Key limit reached:** the daily USD or DIEM limit you set on the key is used up. Raise it at https://venice.ai/settings/api or wait until the next day.
- **Key expired or invalid:** create a new key at Venice and enter it under Settings → Providers and access.
