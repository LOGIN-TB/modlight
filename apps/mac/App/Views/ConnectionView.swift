import PodlightEngine
import SwiftUI

/// How an agent reaches Podlight: three values to copy into any OpenAI-compatible tool, and the
/// ready-made configuration files for experts.
struct ConnectionView: View {
    @Environment(AppModel.self) private var model
    @State private var showKey = false
    @State private var testResult: String?
    @State private var testing = false
    @State private var copied: String?
    @State private var showFiles = false
    @State private var agent: Agent = .openCode
    @State private var forNetwork = false

    @State private var agentModelId: UUID?

    init(agent: Agent = .openCode, showFiles: Bool = false) {
        _agent = State(initialValue: agent)
        _showFiles = State(initialValue: showFiles)
    }

    enum Agent: String, CaseIterable, Identifiable {
        case openCode, pi, claudeCode, codex, environment
        var id: String { rawValue }
    }

    /// The model the Claude Code and Codex snippets are written for.
    private var agentModel: PodlightModel? {
        model.state.models.first { $0.id == agentModelId } ?? model.state.models.first
    }

    private var baseURL: String {
        forNetwork ? (model.networkBaseURLs.first ?? model.localBaseURL) : model.localBaseURL
    }

    var body: some View {
        Form {
            status

            Section {
                CopyRow(title: "Address on this Mac", value: model.localBaseURL, copied: $copied)
                ForEach(model.networkBaseURLs, id: \.self) { url in
                    CopyRow(title: "Address in the network", value: url, copied: $copied)
                }
                HStack {
                    LabeledContent("API key") {
                        Text(showKey ? (model.gatewayKey ?? "") : String(repeating: "•", count: 24))
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    }
                    Button(showKey ? "Hide" : "Show") { showKey.toggle() }
                    Button(copied == "key" ? "Copied" : "Copy") { Pasteboard.copy(model.gatewayKey ?? ""); copied = "key" }
                }
                ForEach(model.state.models) { item in
                    CopyRow(title: "Model", value: item.name, copied: $copied)
                }
                if model.state.models.isEmpty {
                    LabeledContent("Model") { Text("Add a model first").foregroundStyle(.secondary) }
                }
                HStack {
                    Button("Test Connection") { Task { await test() } }.disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                    if let testResult { Text(testResult).foregroundStyle(.secondary) }
                }
            } header: {
                Text("Connect your agent")
            } footer: {
                Text("In your coding agent (OpenCode, Cline, Aider, pi, …) choose a custom or OpenAI-compatible provider and enter these three values. A stopped model starts by itself when an agent asks for it; a new pod then needs up to 25 minutes, so start a new model in Podlight first.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                DisclosureGroup("Configuration files for experts", isExpanded: $showFiles) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Agent", selection: $agent) {
                            Text("OpenCode").tag(Agent.openCode)
                            Text("pi").tag(Agent.pi)
                            Text("Claude Code").tag(Agent.claudeCode)
                            Text("Codex").tag(Agent.codex)
                            Text("Variables").tag(Agent.environment)
                        }
                        .pickerStyle(.segmented)
                        if (agent == .claudeCode || agent == .codex) && model.state.models.count > 1 {
                            Picker("Model", selection: Binding(get: { agentModel?.id }, set: { agentModelId = $0 })) {
                                ForEach(model.state.models) { Text($0.name).tag(Optional($0.id)) }
                            }
                        }
                        if let install = installCommand {
                            HStack {
                                LabeledContent("Install") { Text(install).font(.caption.monospaced()).textSelection(.enabled) }
                                Button(copied == "install" ? "Copied" : "Copy") { Pasteboard.copy(install); copied = "install" }
                            }
                        }
                        ForEach(agentWarnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !model.networkBaseURLs.isEmpty {
                            Picker("For", selection: $forNetwork) {
                                Text("This Mac").tag(false)
                                Text("Another computer").tag(true)
                            }
                            .pickerStyle(.segmented)
                        }
                        ForEach(snippets) { snippet in
                            SnippetBox(snippet: snippet, copied: $copied) {
                                if let folder = snippet.folder {
                                    Button("Open Folder in Finder") { open(folder) }
                                }
                            }
                        }
                        if let documentation {
                            HStack {
                                Spacer()
                                Link("Documentation", destination: documentation)
                            }
                        }
                    }
                    .padding(.top, 6)
                }
            } footer: {
                Text("These files contain your Podlight key. Keep them in your home folder, never in a project repository.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Connection")
    }

    @ViewBuilder private var status: some View {
        Section {
            switch model.gatewayStatus {
            case .running:
                Label(model.gatewayHost == "0.0.0.0" ? "Agents on this Mac and in the local network can connect now."
                                                     : "Agents on this Mac can connect now.",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .starting:
                Label("Starting…", systemImage: "hourglass")
            case .failed(let message):
                Label {
                    VStack(alignment: .leading) {
                        Text("Port \(String(model.gatewayPort)) is not available. Another program may be using it; choose a different port in Settings.")
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                Button("Try Again") { model.startGateway() }
            }
        }
    }

    private var installCommand: String? {
        switch agent {
        case .openCode: nil
        case .pi: nil
        case .claudeCode: "curl -fsSL https://claude.ai/install.sh | bash"
        case .codex: "npm install -g @openai/codex"
        case .environment: nil
        }
    }

    private var documentation: URL? {
        switch agent {
        case .openCode: Links.openCode
        case .pi: Links.pi
        case .claudeCode: Links.claudeCodeGateway
        case .codex: Links.codexConfig
        case .environment: nil
        }
    }

    private var agentWarnings: [String] {
        guard agent == .claudeCode || agent == .codex else { return [] }
        var warnings: [String] = []
        if let item = agentModel, item.contextTokens < AppModel.claudeCodeMinimumContext {
            warnings.append(String(localized: "\(item.name) is set to \(Format.tokens(item.contextTokens)) tokens. These agents send long instructions and need at least 128k, better 200k: choose more context under Edit."))
        }
        if let item = agentModel, item.toolCallParser == nil {
            warnings.append(String(localized: "\(item.name) has no tool calls, so the agent cannot edit files or run commands with it."))
        }
        if agent == .claudeCode {
            warnings.append(String(localized: "Anthropic does not officially support other models in Claude Code. It works through Podlight's Anthropic-compatible route, but web search and some newer features do not."))
        }
        return warnings
    }

    /// What to copy for the chosen agent, one box per place it goes, so each copies on its own.
    private var snippets: [ConfigSnippet] {
        switch agent {
        case .openCode:
            [ConfigSnippet(id: "opencode", title: String(localized: "For ~/.config/opencode/opencode.json"),
                           hint: String(localized: "If the file has content, merge the \"providers\" entry. Then pick podlight/<name> with /models."),
                           content: model.openCodeConfig(baseURL: baseURL), folder: ".config/opencode")]
        case .pi:
            [ConfigSnippet(id: "pi", title: String(localized: "For ~/.pi/agent/models.json"),
                           hint: String(localized: "If the file has content, merge the \"providers\" entry. Then pick the model with /model."),
                           content: model.piConfig(baseURL: baseURL), folder: ".pi/agent")]
        case .claudeCode:
            [ConfigSnippet(id: "claude-once", title: String(localized: "Once, in a terminal"),
                           hint: String(localized: "Starts Claude Code with Podlight in this terminal. Plain claude keeps your normal login."),
                           content: model.claudeCodeOnce(baseURL: baseURL, model: agentModel)),
             ConfigSnippet(id: "claude-function", title: String(localized: "Permanently as claude-podlight"),
                           hint: String(localized: "Add to ~/.zshrc and open a new terminal; from then on claude-podlight starts Claude Code with Podlight."),
                           content: model.claudeCodeFunction(baseURL: baseURL, model: agentModel))]
        case .codex:
            [ConfigSnippet(id: "codex-provider", title: String(localized: "1. Provider for ~/.codex/config.toml"),
                           hint: String(localized: "Add at the end of the file. Your default provider stays as it is."),
                           content: model.codexProvider(baseURL: baseURL), folder: ".codex"),
             ConfigSnippet(id: "codex-function", title: String(localized: "2. Function codex-podlight for ~/.zshrc"),
                           hint: String(localized: "Add to ~/.zshrc and open a new terminal, then start Codex with codex-podlight. Plain codex keeps your normal setup."),
                           content: model.codexFunction(model: agentModel))]
        case .environment:
            [ConfigSnippet(id: "environment", title: String(localized: "Environment variables"),
                           hint: String(localized: "For tools that read OpenAI's environment variables, such as Aider: add these lines to ~/.zshrc or run them before the tool."),
                           content: model.environmentConfig(baseURL: baseURL))]
        }
    }

    private func open(_ relative: String) {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(relative, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    private func test() async {
        testing = true
        defer { testing = false }
        var request = URLRequest(url: URL(string: "\(model.localBaseURL)/models")!)
        request.setValue("Bearer \(model.gatewayKey ?? "")", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            testResult = status == 200 ? String(localized: "Works.") : String(localized: "Answered with \(status).")
        } catch {
            testResult = String(localized: "No answer: \(error.localizedDescription)")
        }
    }
}

/// One piece of configuration and where it goes.
struct ConfigSnippet: Identifiable {
    var id: String
    var title: String
    var hint: String
    var content: String
    /// A folder under the home folder to open in Finder, for snippets that go into a file.
    var folder: String? = nil
}

/// A snippet in its own box with its own Copy button, which copies exactly this box.
struct SnippetBox<Extra: View>: View {
    let snippet: ConfigSnippet
    @Binding var copied: String?
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(snippet.title).font(.headline)
                Spacer()
                extra()
                Button(copied == snippet.id ? "Copied" : "Copy") {
                    Pasteboard.copy(snippet.content)
                    copied = snippet.id
                }
                .accessibilityLabel(Text("Copy: \(snippet.title)"))
            }
            Text(snippet.hint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView(.horizontal) {
                Text(snippet.content)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))
        }
        .padding(.top, 4)
    }
}

struct CopyRow: View {
    let title: LocalizedStringKey
    let value: String
    @Binding var copied: String?

    var body: some View {
        HStack {
            LabeledContent(title) { Text(value).font(.body.monospaced()).textSelection(.enabled) }
            Button(copied == value ? "Copied" : "Copy") { Pasteboard.copy(value); copied = value }
        }
    }
}
