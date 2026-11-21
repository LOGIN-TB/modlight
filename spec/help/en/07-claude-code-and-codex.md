# Claude Code and Codex

Anthropic's Claude Code and OpenAI's Codex run in the terminal. Both can use a model in Podlight. Podlight passes through the interfaces they need: the Anthropic Messages API for Claude Code and the Responses API for Codex. vLLM and llama.cpp serve both.

## Before you start

- The model needs tool calls, or the agent cannot edit files or run commands. Podlight shows this during the check.
- Both agents send long instructions. Set at least 128,000 tokens of context, better 200,000. With less, Podlight warns next to the configuration.
- Start the model in Podlight first. A new pod takes longer than the agents wait.

## Claude Code

Install in Terminal:

```
curl -fsSL https://claude.ai/install.sh | bash
```

Under "Connection" → "Configuration files for experts" → "Claude Code" there is a ready command with your address, key and model name. It starts Claude Code with Podlight once. In its own box below is the same setting as a function `claude-podlight` for the file `~/.zshrc`. Then open a new terminal and start with `claude-podlight`. The plain `claude` command keeps your usual login. Each box has its own Copy button that copies exactly that part.

Good to know: Anthropic does not officially support other models in Claude Code. It works through the Anthropic-compatible interface, but web search and some newer features do not.

## Codex

Install in Terminal (needs Node.js):

```
npm install -g @openai/codex
```

Under "Codex" there are two parts, each in its own box to copy: a provider `podlight` for the file `~/.codex/config.toml` and a function `codex-podlight` for `~/.zshrc`. "Open Folder in Finder" shows the `.codex` folder. Then start with `codex-podlight`. The plain `codex` command stays as it was.

These configurations contain your Podlight key. Keep them in your home folder, never in a project repository.
