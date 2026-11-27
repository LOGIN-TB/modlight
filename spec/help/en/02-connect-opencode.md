# Connect Your Agent

Modlight provides an OpenAI-compatible address. Any coding agent that accepts a custom or OpenAI-compatible provider can use it: OpenCode, Cline, Aider, pi and others.

## Three values

"Connection" shows the three values every agent needs, each with "Copy":

- **Address:** on this Mac `http://127.0.0.1:7635/v1`. With the local network switched on, the address for other computers appears as well.
- **API key:** your Modlight key. Modlight refuses every request without it.
- **Model:** the name you gave the model.

![The Connection view](screenshots/en/connection.png)

In your agent, choose a custom or OpenAI-compatible provider and enter the three values. "Test Connection" shows whether Modlight answers.

## Configuration files for experts

Some agents want a file instead of a form. Under "Configuration files for experts" Modlight writes them for you:

- **OpenCode:** `~/.config/opencode/opencode.json`. The model is called `modlight/<name>` there and is picked with `/models`.
- **pi:** `~/.pi/agent/models.json`. The model is picked with `/model`.
- **Claude Code** and **Codex:** a command or function for Terminal, see "Claude Code and Codex".
- **Environment variables:** `OPENAI_BASE_URL` and `OPENAI_API_KEY`, for example for Aider.

If the file already has content, take over only the entry under `providers`. The files contain your Modlight key, so keep them in your home folder, never in a project repository.

## What happens on the first request

If the model is not running, Modlight starts it and holds the request until it answers. A stopped pod with its model kept on disk is back after about a minute. A brand-new pod takes up to 25 minutes, so start a new model in Modlight itself the first time.

A pod woken this way has no fixed end. It stops when no more requests come in (idle stop), at the latest after the 12-hour maximum.
