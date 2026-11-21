import PodlightEngine
import SwiftUI

/// The settings window (⌘,), with the same content as the "Settings" item in the sidebar.
struct SettingsView: View {
    var body: some View {
        SettingsContent()
            .frame(width: 600, height: 640)
    }
}

/// All of Podlight's settings in one place. Things that belong to one model (context, card, cache,
/// idle stop) live with that model instead.
struct SettingsContent: View {
    @Environment(AppModel.self) private var model
    @State private var editingKey = false
    @State private var hfToken = ""
    @State private var hfMessage: String?
    @State private var port = ""

    var body: some View {
        let settings = model.state.settings
        Form {
            Section {
                LimitField(title: "Per day", value: settings.dailyLimitUsd) { v in await model.updateSettings { $0.dailyLimitUsd = v } }
                LimitField(title: "Per month", value: settings.monthlyLimitUsd) { v in await model.updateSettings { $0.monthlyLimitUsd = v } }
                Picker("Stop pods without contact after", selection: binding(\.heartbeatMinutes)) {
                    ForEach([5, 10, 15, 30, 60], id: \.self) { Text("\($0) minutes").tag($0) }
                }
                Toggle("Start a stopped model when an agent asks for it", isOn: binding(\.wakeOnRequest))
                Picker("Delete stopped pods after", selection: binding(\.deleteStoppedAfterDays)) {
                    ForEach([1, 3, 7, 14], id: \.self) { Text("\($0) days").tag($0) }
                }
            } header: {
                Text("Costs and safety")
            } footer: {
                Text("At a limit, Podlight stops this Mac's pods and starts them again only the next day or month. Every pod also stops itself when it has not heard from Podlight for the set time, for example while this Mac sleeps.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Where pods may run", selection: binding(\.hostingRegion)) {
                    Text("Anywhere").tag(HostingRegion.anywhere)
                    Text("EU only").tag(HostingRegion.eu)
                    Text("EU and EEA (incl. Iceland, Norway)").tag(HostingRegion.euEEA)
                }
                Toggle("Secure Cloud only", isOn: binding(\.secureCloudOnly))
            } header: {
                Text("Hosting")
            } footer: {
                Text("Secure Cloud runs in certified data centers (RunPod names SOC 2, ISO 27001, PCI DSS) instead of on community hosts, usually at a higher price. RunPod treats the chosen region as a preference and gives no data residency guarantee, so Podlight checks where each pod landed and deletes it straight away if it is outside. Fewer cards are available with these limits.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Who may connect", selection: Binding(
                    get: { settings.allowLAN },
                    set: { value in Task { await model.updateSettings { $0.allowLAN = value }; await model.restartGateway() } })) {
                    Text("Only this Mac").tag(false)
                    Text("This Mac and the local network").tag(true)
                }
                .pickerStyle(.radioGroup)
                HStack {
                    TextField("Port", text: $port)
                        .frame(maxWidth: 120)
                    Button("Apply") {
                        guard let value = Int(port), (1024...65535).contains(value) else { return }
                        Task {
                            await model.updateSettings { $0.gatewayPort = value }
                            await model.restartGateway()
                        }
                    }
                    .disabled(Int(port) == settings.gatewayPort)
                }
            } header: {
                Text("Network")
            } footer: {
                Text(settings.allowLAN
                     ? "Other computers connect with the address under Connection and the same key. The connection is not encrypted: use this only in networks you trust, not in public Wi-Fi. macOS may ask once whether Podlight may accept incoming connections."
                     : "Only programs on this Mac can connect. Switch on the local network to use your models from a second computer.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("RunPod API key", value: model.hasRunpodKey ? String(localized: "Saved in the keychain") : String(localized: "Not set"))
                Button(model.hasRunpodKey ? "Replace API Key…" : "Add API Key…") { editingKey = true }
                LabeledContent("Hugging Face token", value: model.hasHuggingFaceToken ? String(localized: "Saved in the keychain") : String(localized: "Not set"))
                SecureField("Paste a new token", text: $hfToken)
                HStack {
                    Button("Check and Save Token") { Task { await saveToken() } }
                        .disabled(hfToken.isEmpty)
                    if model.hasHuggingFaceToken {
                        Button("Remove Token", role: .destructive) { try? model.saveHuggingFaceToken("") }
                    }
                    if let hfMessage { Text(hfMessage).foregroundStyle(.secondary) }
                }
                Link("Create a token at Hugging Face (Read access is enough)", destination: Links.huggingFaceTokens)
                Button("Create New Podlight Key…") { model.newGatewayKey() }
            } header: {
                Text("Access")
            } footer: {
                Text("A Hugging Face token is recommended: pods download over addresses RunPod shares with others, and Hugging Face limits anonymous downloads more strictly. It is required for gated models. After a new Podlight key, paste it into your agents' configuration.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Open Podlight at login", isOn: Binding(get: { model.launchesAtLogin }, set: { model.launchesAtLogin = $0 }))
            }
        }
        .formStyle(.grouped)
        .onAppear { port = String(settings.gatewayPort) }
        .sheet(isPresented: $editingKey) {
            RunpodKeyStep(onDone: { editingKey = false })
                .environment(model)
                .padding(20)
                .frame(width: 520, height: 420)
        }
    }

    private func binding<T: Sendable>(_ keyPath: WritableKeyPath<PodlightSettings, T> & Sendable) -> Binding<T> {
        Binding(
            get: { model.state.settings[keyPath: keyPath] },
            set: { value in Task { await model.updateSettings { $0[keyPath: keyPath] = value } } })
    }

    private func saveToken() async {
        let token = hfToken.trimmingCharacters(in: .whitespacesAndNewlines)
        switch await HuggingFaceClient(token: token).checkToken() {
        case .valid(let user):
            do {
                try model.saveHuggingFaceToken(token)
                hfToken = ""
                hfMessage = user.isEmpty ? String(localized: "Saved.") : String(localized: "Saved for \(user).")
            } catch {
                hfMessage = error.localizedDescription
            }
        case .invalid:
            hfMessage = String(localized: "Hugging Face does not accept this token.")
        case .unreachable:
            hfMessage = String(localized: "Hugging Face could not be reached.")
        }
    }
}

/// A money limit as a text field; empty means no limit.
struct LimitField: View {
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
