# Connect OpenCode

Podlight provides an OpenAI-compatible address on this Mac: `http://127.0.0.1:7635/v1`. Only programs on this Mac can reach it, and only with the Podlight key.

## How

- In Podlight, open "Connection" and click "Copy OpenCode Configuration".
- Open the file `~/.config/opencode/opencode.json`, or create it. "Open Folder in Finder" takes you there.
- Paste the configuration. If the file already has content, take over only the entry under `providers`.
- Start OpenCode and pick the model with `/models`. It is called `podlight/<name>`.

![The Connection view](screenshots/en/connection.png)

The configuration contains your Podlight key. Keep it in your home folder, never in a project repository.

## What happens on the first request

If the model is not running, Podlight starts it and holds the request until it answers. A stopped pod is back after about a minute. A brand-new pod takes up to 25 minutes. The configuration lets OpenCode wait up to 10 minutes, so start a new model in Podlight itself the first time.

A pod woken this way has no fixed end. It stops when no more requests come in (idle stop), at the latest after the 12-hour maximum.

## Other programs

Any program that speaks the OpenAI-compatible API works the same way. "Connection → Other clients" has the address, the key and the model names to copy.

## Checking the connection

"Test Connection" asks for the model list. If it says "Works.", everything is set up. If the port is taken, choose another one under Settings → Advanced and update OpenCode.
