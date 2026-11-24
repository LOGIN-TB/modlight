import PodlightEngine
import SwiftUI

/// What to bring from this Mac to a server: right after pairing, from Server Settings, or for one
/// model from its context menu.
struct TransferRequest: Identifiable, Equatable {
    var id: UUID { serverID }
    let serverID: UUID
    /// Models ticked at the start (the one whose "Hand Over to Server…" opened the sheet).
    var models: Set<UUID> = []
    /// Opened for one model: keys and rules start unticked when the server already has a key.
    var forModel = false
}

/// Brings this Mac's RunPod key, Hugging Face token, limits and rules to a server, and hands
/// models over with their pods and disks, so nothing is typed twice or downloaded again.
struct TransferSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: TransferRequest

    @State private var keys = false
    @State private var rules = false
    @State private var chosen: Set<UUID> = []
    @State private var working = false
    @State private var progress: String?
    @State private var errors: [String] = []
    @State private var movedAny = false

    private var server: ServerMirror? { model.server(request.serverID) }
    private var serverHasKey: Bool { server?.snapshot?.settings.hasRunpodKey == true }
    private var ready: Set<UUID> { Set(model.modelsReadyToHandOver.map(\.id)) }
    private var candidates: [PodlightModel] { model.state.models.filter { model.state.run($0.id).managedBy == nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Bring This Mac's Setup Along").font(.title2.weight(.semibold))
                Text("To \(server?.entry.name ?? ""). Nothing has to be typed in twice.").foregroundStyle(.secondary)
            }
            .padding(20)
            Divider()
            Form {
                Section {
                    Toggle("RunPod API key and Hugging Face token", isOn: $keys)
                        .disabled(!model.hasRunpodKey)
                    Toggle("Spending limits and rules", isOn: $rules)
                } footer: {
                    Text(serverHasKey
                         ? "The server already has a RunPod key; ticking the first box replaces it with this Mac's. Rules are the daily and monthly limit, heartbeat, wake on request, deletion of unused disks, region and this Mac's time zone."
                         : "The server then pays RunPod from the same account. Rules are the daily and monthly limit, heartbeat, wake on request, deletion of unused disks, region and this Mac's time zone.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !candidates.isEmpty {
                    Section {
                        ForEach(candidates) { item in
                            let run = model.state.run(item.id)
                            Toggle(isOn: Binding(get: { chosen.contains(item.id) },
                                                 set: { on in if on { chosen.insert(item.id) } else { chosen.remove(item.id) } })) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                    Text(podLine(item.id, run)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .disabled(!ready.contains(item.id))
                        }
                    } header: {
                        Text("Models")
                    } footer: {
                        Text("A model moves with its pod and kept disk, so nothing is downloaded again; a running one keeps running. It leaves this Mac. Agents that use it through this Mac must then connect to the server: its Connection page gives them an address and an access key.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let progress {
                    HStack { ProgressView().controlSize(.small); Text(progress) }
                }
                ForEach(errors, id: \.self) { message in
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button(errors.isEmpty ? "Skip" : "Close") { finish() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
                Button("Bring Along") { Task { await run() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(working || server?.status != .online || (!keys && !rules && chosen.isEmpty))
            }
            .padding(20)
        }
        .frame(width: 560, height: candidates.isEmpty ? 400 : 600)
        .onAppear {
            let fresh = !serverHasKey && !request.forModel
            keys = fresh && model.hasRunpodKey
            rules = fresh
            chosen = request.models.intersection(ready)
        }
    }

    private func podLine(_ id: UUID, _ run: ModelRun) -> String {
        if !ready.contains(id) {
            return String(localized: "\(PhaseText.title(run.phase)): can move once it runs or has stopped")
        }
        guard run.podId != nil else { return String(localized: "No pod right now") }
        let disk = run.persistentGB.map { String(localized: " · disk \($0) GB") } ?? ""
        switch run.phase {
        case .ready: return String(localized: "Running on \(run.gpuName ?? "a GPU")\(disk)")
        default: return String(localized: "Stopped\(disk)")
        }
    }

    private func run() async {
        working = true
        errors = []
        defer { working = false; progress = nil }
        if keys || rules {
            progress = String(localized: "Copying settings…")
            if let error = await model.copyFromThisMac(to: request.serverID, keys: keys, rules: rules) {
                errors.append(error)
                return
            }
            keys = false
            rules = false
        }
        let models = candidates.filter { chosen.contains($0.id) }
        for item in models {
            progress = String(localized: "Handing over \(item.name)…")
            if let error = await model.handOver(item.id, to: request.serverID) {
                errors.append("\(item.name): \(error)")
            } else {
                chosen.remove(item.id)
                movedAny = true
            }
        }
        if errors.isEmpty { finish() }
    }

    private func finish() {
        dismiss()
        // Agents have to follow the models: the server's Connection page has what they need.
        model.selection = movedAny ? .serverConnection(request.serverID)
            : (serverHasKey ? .serverConnection(request.serverID) : .serverSettings(request.serverID))
    }
}
