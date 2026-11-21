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

    enum Agent: String, CaseIterable, Identifiable {
        case openCode, pi, environment
        var id: String { rawValue }
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
                            Text("Environment variables").tag(Agent.environment)
                        }
                        .pickerStyle(.segmented)
                        if !model.networkBaseURLs.isEmpty {
                            Picker("For", selection: $forNetwork) {
                                Text("This Mac").tag(false)
                                Text("Another computer").tag(true)
                            }
                            .pickerStyle(.segmented)
                        }
                        Text(fileHint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        ScrollView([.horizontal, .vertical]) {
                            Text(fileContent)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 220)
                        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))
                        HStack {
                            Button(copied == "file" ? "Copied" : "Copy") { Pasteboard.copy(fileContent); copied = "file" }
                            if let folder = fileFolder {
                                Button("Open Folder in Finder") { open(folder) }
                            }
                            Spacer()
                            Link("Documentation", destination: agent == .pi ? Links.pi : Links.openCode)
                                .opacity(agent == .environment ? 0 : 1)
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

    private var fileContent: String {
        switch agent {
        case .openCode: model.openCodeConfig(baseURL: baseURL)
        case .pi: model.piConfig(baseURL: baseURL)
        case .environment: model.environmentConfig(baseURL: baseURL)
        }
    }

    private var fileHint: String {
        switch agent {
        case .openCode:
            String(localized: "Paste into ~/.config/opencode/opencode.json (if the file has content, merge the \"providers\" entry), then pick podlight/<name> with /models.")
        case .pi:
            String(localized: "Paste into ~/.pi/agent/models.json (if the file has content, merge the \"providers\" entry), then pick the model with /model.")
        case .environment:
            String(localized: "For tools that read OpenAI's environment variables, such as Aider: add these lines to ~/.zshrc or run them before the tool.")
        }
    }

    private var fileFolder: String? {
        switch agent {
        case .openCode: ".config/opencode"
        case .pi: ".pi/agent"
        case .environment: nil
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
