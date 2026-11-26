import Foundation
import PodlightEngine

/// Configuration snippets for coding agents, for this Mac's gateway or a server's. Pure text, so
/// the same code writes both; a server gets its own provider id, so both can sit side by side in
/// one opencode.json or config.toml.
struct AgentConfigs {
    /// The key the agent sends: this Mac's gateway key, or a server access key.
    var key: String
    var models: [PodlightModel]
    /// Provider id in config files and the suffix of the shell functions.
    var provider = "podlight"
    /// Display name in the agents' model lists.
    var label = "Podlight"

    /// `podlight-office` for a server named "Office".
    static func providerID(forServerNamed name: String) -> String {
        let slug = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en"))
            .lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "podlight-server" : "podlight-\(slug)"
    }

    /// The environment variable Codex reads the key from.
    var keyVariable: String { provider.uppercased().replacingOccurrences(of: "-", with: "_") + "_API_KEY" }

    /// OpenCode, current format (opencode.ai/docs/models, "Compatible"), for the global
    /// ~/.config/opencode/opencode.json. Contains the key, so never for a repository.
    func openCode(baseURL: String) -> String {
        let first = self.models.first?.name ?? "model"
        let models = self.models.map { model in
            """
                    "\(model.name)": {
                      "name": "\(model.name) (\(label))",
                      "capabilities": { "tools": \(model.supportsTools), "input": \(model.supportsImages ? #"["text", "image"]"# : #"["text"]"#), "output": ["text"] },
                      "limit": { "context": \(model.contextTokens), "output": \(min(16_384, model.contextTokens / 4)) }
                    }
            """
        }.joined(separator: ",\n")
        return """
        {
          "$schema": "https://opencode.ai/config.json",
          "model": "\(provider)/\(first)",
          "providers": {
            "\(provider)": {
              "name": "\(label)",
              "package": "@opencode/ai/providers/openai-compatible",
              "settings": {
                "baseURL": "\(baseURL)",
                "apiKey": "\(key)",
                "headerTimeout": 600000
              },
              "models": {
        \(models)
              }
            }
          }
        }
        """
    }

    /// pi, ~/.pi/agent/models.json (github.com/earendil-works/pi, docs/models.md).
    func pi(baseURL: String) -> String {
        let models = self.models.map { model in
            "        { \"id\": \"\(model.name)\", \"contextWindow\": \(model.contextTokens), \"maxTokens\": \(min(16_384, model.contextTokens / 4)) }"
        }.joined(separator: ",\n")
        return """
        {
          "$schema": "https://pi.dev/schemas/models.schema.json",
          "providers": {
            "\(provider)": {
              "baseUrl": "\(baseURL)",
              "api": "openai-completions",
              "apiKey": "\(key)",
              "models": [
        \(models)
              ]
            }
          }
        }
        """
    }

    /// Environment variables most OpenAI-compatible tools read (Aider, scripts, SDKs).
    func environment(baseURL: String) -> String {
        """
        export OPENAI_BASE_URL="\(baseURL)"
        export OPENAI_API_BASE="\(baseURL)"
        export OPENAI_API_KEY="\(key)"
        # Model: \(models.map(\.name).joined(separator: " | "))
        """
    }

    /// Claude Code needs at least this much context to work; below it compacts constantly.
    static let claudeCodeMinimumContext = 131_072

    /// Claude Code in the terminal, pointed at Podlight through its Anthropic-compatible route
    /// (code.claude.com/docs/en/llm-gateway, env-vars). The normal Claude Code login stays untouched.
    private func claudeCodeVariables(baseURL: String, model item: PodlightModel?) -> [String] {
        let name = item?.name ?? "model"
        let context = item?.contextTokens ?? 131_072
        let root = baseURL.hasSuffix("/v1") ? String(baseURL.dropLast(3)) : baseURL
        return [
            "ANTHROPIC_BASE_URL='\(root)'",
            "ANTHROPIC_AUTH_TOKEN='\(key)'",
            "ANTHROPIC_API_KEY=''",
            "ANTHROPIC_MODEL='\(name)'",
            "ANTHROPIC_DEFAULT_OPUS_MODEL='\(name)'",
            "ANTHROPIC_DEFAULT_SONNET_MODEL='\(name)'",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL='\(name)'",
            "CLAUDE_CODE_MAX_CONTEXT_TOKENS=\(context)",
            "CLAUDE_CODE_MAX_OUTPUT_TOKENS=\(min(32_000, context / 4))",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1",
            // Beta request fields only Anthropic's own API knows; open engines may reject them.
            "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1",
        ]
    }

    /// Claude Code once, for this terminal.
    func claudeCodeOnce(baseURL: String, model item: PodlightModel?) -> String {
        claudeCodeVariables(baseURL: baseURL, model: item).joined(separator: " \\\n  ") + " \\\n  claude"
    }

    /// Claude Code permanently as `claude-podlight`, for ~/.zshrc.
    func claudeCodeFunction(baseURL: String, model item: PodlightModel?) -> String {
        """
        \(provider == "podlight" ? "claude-podlight" : "claude-\(provider)")() {
          \(claudeCodeVariables(baseURL: baseURL, model: item).joined(separator: " \\\n  ")) \\
            claude "$@"
        }
        """
    }

    /// Codex CLI: a provider for ~/.codex/config.toml that leaves the user's default untouched
    /// (learn.chatgpt.com/docs/config-file/config-reference; `wire_api = "responses"` is the only
    /// value Codex still accepts).
    func codexProvider(baseURL: String) -> String {
        """
        [model_providers.\(provider)]
        name = "\(label)"
        base_url = "\(baseURL)"
        env_key = "\(keyVariable)"
        wire_api = "responses"
        stream_idle_timeout_ms = 900000
        """
    }

    /// The shell function that selects the provider, for ~/.zshrc.
    func codexFunction(model item: PodlightModel?) -> String {
        let name = item?.name ?? "model"
        let context = item?.contextTokens ?? 131_072
        return """
        \(provider == "podlight" ? "codex-podlight" : "codex-\(provider)")() {
          \(keyVariable)='\(key)' codex \\
            -c model_provider=\(provider) -m '\(name)' \\
            -c model_context_window=\(context) "$@"
        }
        """
    }
}
