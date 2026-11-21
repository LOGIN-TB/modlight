import PodlightEngine
import SwiftUI

/// Pairs the app with a Podlight server: its address and the code from its log.
struct AddServerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var code = ""
    @State private var pairing = false
    @State private var error: String?
    @State private var showHelp: Bool
    @State private var copied: String?

    init(expandedHelp: Bool = false) {
        _showHelp = State(initialValue: expandedHelp)
    }

    private var addressProblem: ServerAddress.Problem? {
        guard !address.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        do { _ = try ServerAddress.normalize(address); return nil } catch { return error }
    }

    private var unencrypted: Bool {
        (try? ServerAddress.normalize(address)).map(ServerAddress.isUnencrypted) ?? false
    }

    private static let compose = """
        services:
          podlight:
            image: ghcr.io/login-tb/podlight-server:latest
            restart: unless-stopped
            volumes:
              - podlight-data:/data
            ports:
              - "8080:8080"
        volumes:
          podlight-data:
        """

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add Server").font(.title2.weight(.semibold)).padding(20)
            Divider()
            Form {
                Section {
                    TextField("Address", text: $address, prompt: Text("podlight.example.com"))
                        .textContentType(.URL)
                    if let addressProblem {
                        Text(Describe.address(addressProblem)).font(.caption).foregroundStyle(.red)
                    } else if unencrypted {
                        Label("Unencrypted. Use this only on a network you trust.", systemImage: "lock.open")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    TextField("Pairing code", text: $code, prompt: Text("ABCD-EFGH-JKLM"))
                    TextField("Name", text: $name, prompt: Text("e.g. Office"))
                } footer: {
                    Text("The pairing code is in the server's log when it starts for the first time. It works once and for 30 minutes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    DisclosureGroup("How do I set up a server?", isExpanded: $showHelp) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("A Podlight server keeps models reachable for agents while this Mac is off. It runs as one container, for example on a VPS, a NAS or with Coolify:")
                                .fixedSize(horizontal: false, vertical: true)
                            SnippetBox(snippet: ConfigSnippet(id: "compose", title: String(localized: "docker-compose.yml"),
                                                              hint: String(localized: "Start it with docker compose up -d, then read the code with docker compose logs."),
                                                              content: Self.compose), copied: $copied) { EmptyView() }
                            Text("Give it an https address before it is reachable from the internet: in Coolify, set a domain for the service; elsewhere, put a reverse proxy such as Caddy in front of it. The server pays RunPod with its own API key, which you enter after pairing.")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Link("Server documentation", destination: Links.serverDocs)
                        }
                        .padding(.top, 6)
                    }
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Pair") { Task { await pair() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(pairing || address.isEmpty || code.isEmpty || addressProblem != nil)
                if pairing { ProgressView().controlSize(.small) }
            }
            .padding(20)
        }
        .frame(width: 560, height: showHelp ? 640 : 440)
    }

    private func pair() async {
        pairing = true
        error = nil
        defer { pairing = false }
        do {
            let id = try await model.addServer(name: name, address: address, code: code)
            dismiss()
            // A new server needs its RunPod key before anything runs there.
            let ready = model.server(id)?.snapshot?.settings.hasRunpodKey == true
            model.selection = ready ? .serverConnection(id) : .serverSettings(id)
        } catch {
            self.error = Describe.error(error)
        }
    }
}

/// How agents reach the models on a server: its address and access keys.
struct ServerConnectionView: View {
    @Environment(AppModel.self) private var model
    let serverID: UUID
    @State private var creatingKey = false
    /// The key created in this visit: the only time it can be shown.
    @State private var newKey: ClientToken?
    @State private var copied: String?
    @State private var showFiles = false
    @State private var error: String?
    @State private var testResult: String?

    private var server: ServerMirror? { model.server(serverID) }

    var body: some View {
        if let server {
            Form {
                Section {
                    ServerStatusLine(server: server)
                }
                Section {
                    CopyRow(title: "Address", value: server.entry.gatewayURL, copied: $copied)
                    if let key = newKey?.token {
                        HStack {
                            LabeledContent("New access key") { Text(key).font(.body.monospaced()).textSelection(.enabled) }
                            Button(copied == "newkey" ? "Copied" : "Copy") { Pasteboard.copy(key); copied = "newkey" }
                        }
                        Text("Copy it now: the server keeps only a fingerprint, so it cannot be shown again.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    ForEach(server.models) { item in
                        CopyRow(title: "Model", value: item.name, copied: $copied)
                    }
                    if server.models.isEmpty {
                        LabeledContent("Model") { Text("Add a model to this server first").foregroundStyle(.secondary) }
                    }
                    if newKey?.token != nil {
                        HStack {
                            Button("Test Connection") { Task { await test() } }
                            if let testResult { Text(testResult).foregroundStyle(.secondary) }
                        }
                    }
                } header: {
                    Text("Connect your agent")
                } footer: {
                    Text("Agents use an access key of their own, not this Mac's key. A stopped model starts by itself when an agent asks for it, within the server's spending limits.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    ForEach(server.tokens.filter { $0.revokedAt == nil }) { token in
                        TokenRow(server: server, token: token)
                    }
                    if server.tokens.allSatisfy({ $0.revokedAt != nil }) {
                        Text("No access keys yet.").foregroundStyle(.secondary)
                    }
                    Button("New Access Key…") { creatingKey = true }
                        .disabled(server.status != .online)
                    if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                } header: {
                    Text("Access keys")
                } footer: {
                    Text("One key per agent or machine, so you can revoke one without touching the others. A key can be limited to some models.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    DisclosureGroup("Configuration files for experts", isExpanded: $showFiles) {
                        if newKey?.token == nil {
                            Text("Create a new access key first; the files then contain it. Older keys cannot be shown again.")
                                .font(.callout).foregroundStyle(.secondary).padding(.top, 6)
                        }
                        AgentConfigPanel(configs: configs(server), baseURL: server.entry.gatewayURL)
                            .padding(.top, 6)
                    }
                } footer: {
                    Text("These files contain an access key. Keep them in your home folder, never in a project repository.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "Connection · \(server.entry.name)"))
            .task { await model.loadTokens(serverID) }
            .sheet(isPresented: $creatingKey) {
                NewAccessKeySheet(server: server) { created in
                    newKey = created
                    Task { await model.loadTokens(serverID) }
                }
            }
        } else {
            ContentUnavailableView("Server removed", systemImage: "server.rack")
        }
    }

    private func configs(_ server: ServerMirror) -> AgentConfigs {
        let allowed = newKey?.models.map { ids in server.models.filter { ids.contains($0.id) } } ?? server.models
        return AgentConfigs(key: newKey?.token ?? "PASTE-ACCESS-KEY", models: allowed,
                            provider: AgentConfigs.providerID(forServerNamed: server.entry.name),
                            label: "Podlight · \(server.entry.name)")
    }

    private func test() async {
        guard let server, let key = newKey?.token else { return }
        var request = URLRequest(url: URL(string: "\(server.entry.gatewayURL)/models")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 8
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            testResult = status == 200 ? String(localized: "Works.") : String(localized: "Answered with \(status).")
        } catch {
            testResult = String(localized: "No answer: \(error.localizedDescription)")
        }
    }
}

private struct TokenRow: View {
    @Environment(AppModel.self) private var model
    let server: ServerMirror
    let token: ClientToken
    @State private var confirming = false

    private var scope: String {
        guard let ids = token.models else { return String(localized: "All models") }
        let names = server.models.filter { ids.contains($0.id) }.map(\.name)
        return names.isEmpty ? String(localized: "No model") : names.joined(separator: ", ")
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(token.name)
                Text(token.lastUsedAt.map { String(localized: "\(scope) · last used \(Format.time($0))") }
                     ?? String(localized: "\(scope) · not used yet"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Revoke…", role: .destructive) { confirming = true }
        }
        .confirmationDialog("Revoke \(token.name)?", isPresented: $confirming) {
            Button("Revoke", role: .destructive) {
                Task {
                    let client = server.client(model.keychain)
                    try? await client.revokeClientToken(token.id)
                    try? await client.deleteClientToken(token.id)
                    await model.loadTokens(server.id)
                }
            }
        } message: {
            Text("Agents using this key are refused from now on.")
        }
    }
}

private struct NewAccessKeySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let server: ServerMirror
    let created: (ClientToken) -> Void
    @State private var name = ""
    @State private var limited = false
    @State private var chosen: Set<UUID> = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Access Key").font(.title2.weight(.semibold))
            Form {
                TextField("For", text: $name, prompt: Text("e.g. OpenCode on the laptop"))
                Toggle("Only some models", isOn: $limited)
                if limited {
                    ForEach(server.models) { item in
                        Toggle(item.name, isOn: Binding(get: { chosen.contains(item.id) },
                                                        set: { if $0 { chosen.insert(item.id) } else { chosen.remove(item.id) } }))
                    }
                }
                if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { Task { await create() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || (limited && chosen.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func create() async {
        do {
            let token = try await server.client(model.keychain).createClientToken(name: name, models: limited ? Array(chosen) : nil)
            created(token)
            dismiss()
        } catch {
            self.error = Describe.serverError(error)
        }
    }
}

/// Whether the server answers, in one line.
struct ServerStatusLine: View {
    let server: ServerMirror

    var body: some View {
        switch server.status {
        case .online:
            Label(server.snapshot.map { String(localized: "Connected · Podlight server \($0.version)") } ?? String(localized: "Connected"),
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .connecting:
            Label("Connecting…", systemImage: "hourglass")
        case .unreachable(let message):
            Label {
                VStack(alignment: .leading) {
                    Text("Not reachable. Models there keep running under the server's own rules.")
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange) }
        case .notPaired:
            Label("The server no longer accepts this Mac. Remove it and pair again with a new code.", systemImage: "key.slash")
                .foregroundStyle(.red)
        }
    }
}

/// A server's own settings: its RunPod key, limits and rules, paired apps.
struct ServerSettingsView: View {
    @Environment(AppModel.self) private var model
    let serverID: UUID
    @State private var runpodKey = ""
    @State private var huggingFaceToken = ""
    @State private var message: String?
    @State private var busy = false
    @State private var name = ""
    @State private var devices: [PairedDevice] = []
    @State private var pairingCode: PairingCode?
    @State private var confirmingRemove = false

    private var server: ServerMirror? { model.server(serverID) }
    private var settings: ServerSettings? { server?.snapshot?.settings }

    var body: some View {
        if let server {
            Form {
                Section {
                    ServerStatusLine(server: server)
                    TextField("Name", text: $name).onSubmit { Task { await model.renameServer(serverID, to: name) } }
                    LabeledContent("Address", value: server.entry.baseURL.absoluteString)
                    if ServerAddress.isUnencrypted(server.entry.baseURL) {
                        Label("Unencrypted connection. Use this only on a network you trust.", systemImage: "lock.open")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                if let settings {
                    accessSection(settings)
                    rulesSection(settings)
                }
                Section("Paired apps") {
                    ForEach(devices.filter { $0.revokedAt == nil }) { device in
                        HStack {
                            Text(device.current == true ? String(localized: "\(device.name) (this Mac)") : device.name)
                            Spacer()
                            if device.current != true {
                                Button("Unpair", role: .destructive) {
                                    Task { try? await server.client(model.keychain).revokeDevice(device.id); await loadDevices() }
                                }
                            }
                        }
                    }
                    if let pairingCode {
                        LabeledContent("Pairing code", value: pairingCode.code).font(.body.monospaced()).textSelection(.enabled)
                        Text("Valid once, until \(Format.time(pairingCode.expiresAt)). Enter it on the other Mac under Add Server.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Pair Another Mac…") {
                            Task { pairingCode = try? await server.client(model.keychain).newPairingCode() }
                        }
                        .disabled(server.status != .online)
                    }
                }
                Section {
                    Button("Remove Server…", role: .destructive) { confirmingRemove = true }
                } footer: {
                    Text("Podlight on this Mac forgets the server. Models on it keep running under the server's own rules, and the server keeps them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(String(localized: "Server Settings · \(server.entry.name)"))
            .onAppear { name = server.entry.name }
            .task { await loadDevices() }
            .confirmationDialog("Remove \(server.entry.name)?", isPresented: $confirmingRemove) {
                Button("Remove", role: .destructive) { Task { await model.removeServer(serverID) } }
            } message: {
                Text("Models on the server keep running under its rules. To pair again later you need a new code from the server.")
            }
        } else {
            ContentUnavailableView("Server removed", systemImage: "server.rack")
        }
    }

    private func accessSection(_ settings: ServerSettings) -> some View {
        Section {
            LabeledContent("RunPod API key", value: settings.hasRunpodKey ? String(localized: "Saved on the server") : String(localized: "Not set"))
            HStack {
                SecureField(settings.hasRunpodKey ? "Replace key" : "RunPod API key", text: $runpodKey)
                Button("Check and Save") { Task { await saveRunpodKey() } }
                    .disabled(runpodKey.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }
            LabeledContent("Hugging Face token", value: settings.hasHuggingFaceToken ? String(localized: "Saved on the server") : String(localized: "Not set (optional)"))
            HStack {
                SecureField("Hugging Face token", text: $huggingFaceToken)
                Button("Save") { Task { await saveToken() } }
                    .disabled(huggingFaceToken.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                if settings.hasHuggingFaceToken {
                    Button("Remove") { Task { await saveToken(remove: true) } }
                }
            }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            Link("Create a RunPod API key", destination: Links.runpodAPIKeys)
        } header: {
            Text("Access")
        } footer: {
            Text("The server starts and pays for its pods with its own RunPod key, stored encrypted on the server. Podlight on this Mac never reads it back.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func rulesSection(_ settings: ServerSettings) -> some View {
        Section {
            LimitField(title: "Limit per day", value: settings.dailyLimitUsd) { v in await change { $0.dailyLimit(v) } }
            LimitField(title: "Limit per month", value: settings.monthlyLimitUsd) { v in await change { $0.monthlyLimit(v) } }
            Picker("Safety stop without the server", selection: Binding(get: { settings.heartbeatMinutes },
                                                                         set: { v in Task { await change { $0.heartbeatMinutes(v) } } })) {
                ForEach([5, 10, 15, 30, 60], id: \.self) { Text("\($0) minutes").tag($0) }
            }
            Toggle("Start a stopped model when an agent asks", isOn: Binding(get: { settings.wakeOnRequest },
                                                                             set: { v in Task { await change { $0.wakeOnRequest(v) } } }))
            Picker("Delete unused stopped pods after", selection: Binding(get: { settings.deleteStoppedAfterDays },
                                                                          set: { v in Task { await change { $0.deleteStoppedAfterDays(v) } } })) {
                ForEach([1, 3, 7, 14, 30], id: \.self) { Text("\($0) days").tag($0) }
            }
            Picker("Default location for new models", selection: Binding(get: { settings.hostingRegion },
                                                                         set: { v in Task { await change { $0.hosting(HostingPolicy(region: v, secureOnly: settings.secureCloudOnly || v != .anywhere)) } } })) {
                Text("Anywhere").tag(HostingRegion.anywhere)
                Text("EU only").tag(HostingRegion.eu)
                Text("EU and EEA").tag(HostingRegion.euEEA)
            }
            Picker("Days are counted in", selection: Binding(get: { settings.timezone },
                                                             set: { v in Task { await change { $0.timezone(v) } } })) {
                ForEach(Array(Set([settings.timezone, TimeZone.current.identifier, "UTC"])).sorted(), id: \.self) { Text($0).tag($0) }
            }
        } header: {
            Text("Rules on the server")
        } footer: {
            Text("A pod stops itself when the server has not been in touch for this long, for example when the server is down.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func change(_ edit: (inout ServerSettingsChange) -> Void) async {
        var change = ServerSettingsChange()
        edit(&change)
        message = await model.updateServer(serverID, change)
    }

    private func saveRunpodKey() async {
        guard let server else { return }
        busy = true
        defer { busy = false }
        let key = runpodKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            switch try await server.client(model.keychain).verifyRunpodKey(key) {
            case .valid:
                var change = ServerSettingsChange()
                change.runpodApiKey(key)
                message = await model.updateServer(serverID, change) ?? String(localized: "Saved. The server can start pods now.")
                runpodKey = ""
            case .invalid: message = String(localized: "RunPod did not accept this key.")
            case .missingPermission: message = String(localized: "This key may not manage pods. Create one with read and write access.")
            case .unreachable(let why): message = why
            }
        } catch {
            message = Describe.serverError(error)
        }
    }

    private func saveToken(remove: Bool = false) async {
        var change = ServerSettingsChange()
        change.huggingFaceToken(remove ? "" : huggingFaceToken.trimmingCharacters(in: .whitespacesAndNewlines))
        message = await model.updateServer(serverID, change) ?? (remove ? String(localized: "Removed.") : String(localized: "Saved."))
        huggingFaceToken = ""
    }

    private func loadDevices() async {
        guard let server else { return }
        devices = (try? await server.client(model.keychain).devices()) ?? []
    }
}
