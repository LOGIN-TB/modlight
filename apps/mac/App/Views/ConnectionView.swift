import PodlightEngine
import SwiftUI

/// How an agent on this Mac reaches Podlight. OpenCode first, because that is the common case.
struct ConnectionView: View {
    @Environment(AppModel.self) private var model
    @State private var showKey = false
    @State private var testResult: String?
    @State private var testing = false
    @State private var copied: String?

    var body: some View {
        Form {
            Section {
                switch model.gatewayStatus {
                case .running:
                    Label("Agents on this Mac can connect now.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .starting:
                    Label("Starting…", systemImage: "hourglass")
                case .failed(let message):
                    Label {
                        VStack(alignment: .leading) {
                            Text("Port \(String(model.gatewayPort)) is not available. Another program may be using it; choose a different port in Settings → Advanced.")
                            Text(message).font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    Button("Try Again") { model.startGateway() }
                }
            }

            Section {
                CopyRow(title: "Base URL", value: model.gatewayBaseURL, copied: $copied)
                HStack {
                    LabeledContent("API key") {
                        Text(showKey ? (model.gatewayKey ?? "") : String(repeating: "•", count: 24))
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    }
                    Button(showKey ? "Hide" : "Show") { showKey.toggle() }
                    Button(copied == "key" ? "Copied" : "Copy") { Pasteboard.copy(model.gatewayKey ?? ""); copied = "key" }
                }
                LabeledContent("Models") {
                    Text(model.state.models.isEmpty ? "–" : model.state.models.map(\.name).joined(separator: ", "))
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Test Connection") { Task { await test() } }.disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                    if let testResult { Text(testResult).foregroundStyle(.secondary) }
                }
            } header: {
                Text("OpenAI-compatible endpoint")
            } footer: {
                Text("Only programs on this Mac can connect, and only with this key. A stopped model starts by itself when an agent asks for it; the first answer then takes a few minutes.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Text("1. Open (or create) the file ~/.config/opencode/opencode.json.")
                Text("2. Paste this configuration. If the file already has content, merge the \"providers\" entry.")
                Text("3. In OpenCode, choose the model with /models: it appears as \"podlight/<name>\".")
                ScrollView([.horizontal, .vertical]) {
                    Text(model.openCodeConfig)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(8)
                }
                .frame(maxHeight: 220)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))
                HStack {
                    Button(copied == "opencode" ? "Copied" : "Copy OpenCode Configuration") {
                        Pasteboard.copy(model.openCodeConfig); copied = "opencode"
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Open Folder in Finder") { openOpenCodeFolder() }
                    Spacer()
                    Link("OpenCode documentation", destination: Links.openCode)
                }
            } header: {
                Text("Connect OpenCode")
            } footer: {
                Text("The configuration contains your Podlight key. Keep it in your home folder, never in a project repository.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Other clients") {
                Text(model.genericConfig).font(.caption.monospaced()).textSelection(.enabled)
                Button(copied == "generic" ? "Copied" : "Copy") { Pasteboard.copy(model.genericConfig); copied = "generic" }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Connection")
    }

    private func openOpenCodeFolder() {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/opencode", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    private func test() async {
        testing = true
        defer { testing = false }
        var request = URLRequest(url: URL(string: "\(model.gatewayBaseURL)/models")!)
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
