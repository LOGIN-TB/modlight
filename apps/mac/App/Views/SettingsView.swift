import PodlightEngine
import SwiftUI

/// App settings (⌘,). Things that belong to one model live with that model instead.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Access", systemImage: "key") { AccessSettings() }
            Tab("Advanced", systemImage: "slider.horizontal.3") { AdvancedSettings() }
        }
        .frame(width: 560, height: 440)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let settings = model.state.settings
        Form {
            Section("Spending limits") {
                LimitField(title: "Per day", value: settings.dailyLimitUsd) { v in await model.updateSettings { $0.dailyLimitUsd = v } }
                LimitField(title: "Per month", value: settings.monthlyLimitUsd) { v in await model.updateSettings { $0.monthlyLimitUsd = v } }
            }
            Section {
                Picker("Stop pods without contact after", selection: Binding(
                    get: { settings.heartbeatMinutes },
                    set: { v in Task { await model.updateSettings { $0.heartbeatMinutes = v } } })) {
                    ForEach([5, 10, 15, 30, 60], id: \.self) { Text("\($0) minutes").tag($0) }
                }
                Toggle("Start a stopped model when an agent asks for it", isOn: Binding(
                    get: { settings.wakeOnRequest },
                    set: { v in Task { await model.updateSettings { $0.wakeOnRequest = v } } }))
                Picker("Delete stopped pods after", selection: Binding(
                    get: { settings.deleteStoppedAfterDays },
                    set: { v in Task { await model.updateSettings { $0.deleteStoppedAfterDays = v } } })) {
                    ForEach([1, 3, 7, 14], id: \.self) { Text("\($0) days").tag($0) }
                }
            } header: {
                Text("Safety")
            } footer: {
                Text("Every pod stops itself when it has not heard from Podlight for this long, for example while this Mac sleeps. The new value applies to pods started from now on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Open Podlight at login", isOn: Binding(
                    get: { model.launchesAtLogin },
                    set: { model.launchesAtLogin = $0 }))
            }
        }
        .formStyle(.grouped)
    }
}

private struct LimitField: View {
    let title: LocalizedStringKey
    let value: Double?
    let save: (Double?) async -> Void
    @State private var text = ""

    var body: some View {
        HStack {
            TextField(title, text: $text, prompt: Text("no limit"))
                .onSubmit { commit() }
            Text("USD").foregroundStyle(.secondary)
        }
        .onAppear { text = value.map { String(format: "%.0f", $0) } ?? "" }
        .onChange(of: text) { commit() }
    }

    private func commit() {
        let trimmed = text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        let parsed = Double(trimmed)
        guard trimmed.isEmpty || parsed != nil else { return }
        Task { await save(trimmed.isEmpty ? nil : parsed) }
    }
}

private struct AccessSettings: View {
    @Environment(AppModel.self) private var model
    @State private var editingKey = false
    @State private var hfToken = ""
    @State private var hfMessage: String?

    var body: some View {
        Form {
            Section("RunPod") {
                LabeledContent("API key", value: model.hasRunpodKey ? String(localized: "Saved in the keychain") : String(localized: "Not set"))
                Button(model.hasRunpodKey ? "Replace API Key…" : "Add API Key…") { editingKey = true }
            }
            Section {
                LabeledContent("Token", value: model.hasHuggingFaceToken ? String(localized: "Saved in the keychain") : String(localized: "Not set"))
                SecureField("Paste a new token", text: $hfToken)
                HStack {
                    Button("Save Token") {
                        do { try model.saveHuggingFaceToken(hfToken); hfToken = ""; hfMessage = String(localized: "Saved.") }
                        catch { hfMessage = error.localizedDescription }
                    }
                    .disabled(hfToken.isEmpty)
                    if model.hasHuggingFaceToken {
                        Button("Remove Token", role: .destructive) { try? model.saveHuggingFaceToken("") }
                    }
                    if let hfMessage { Text(hfMessage).foregroundStyle(.secondary) }
                }
                Link("Create a token at Hugging Face (Read access is enough)", destination: Links.huggingFaceTokens)
            } header: {
                Text("Hugging Face (optional)")
            } footer: {
                Text("Only needed for gated models such as Llama or Gemma, after you have accepted their licence on the model page.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Podlight key for agents") {
                Button("Create New Key…") { model.newGatewayKey() }
                Text("Agents using the old key stop working until you paste the new one into their configuration.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $editingKey) {
            RunpodKeyStep(onDone: { editingKey = false })
                .environment(model)
                .padding(20)
                .frame(width: 520)
        }
    }
}

private struct AdvancedSettings: View {
    @Environment(AppModel.self) private var model
    @State private var port = ""

    var body: some View {
        Form {
            Section {
                TextField("Port", text: $port)
                Button("Apply and Restart Connection") {
                    guard let value = Int(port), (1024...65535).contains(value) else { return }
                    Task {
                        await model.updateSettings { $0.gatewayPort = value }
                        await model.restartGateway()
                    }
                }
            } header: {
                Text("Local connection")
            } footer: {
                Text("Agents use http://127.0.0.1:<port>/v1. After a change, update their configuration.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { port = String(model.state.settings.gatewayPort) }
    }
}
