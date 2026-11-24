import PodlightEngine
import SwiftUI

/// The main window: the overview, the models, then Connection, Costs and Settings in the sidebar; the chosen
/// item beside it. Standard NavigationSplitView and toolbar, so the system draws them in Liquid
/// Glass; no custom backgrounds behind bars.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        Group {
            if model.showingSetup {
                // Inline, not a sheet: macOS refuses to quit an app while a sheet is attached, and
                // the first launch must always be easy to leave.
                SetupView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NavigationSplitView {
                    Sidebar()
                        .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
                } detail: {
                    Detail()
                }
                .sheet(isPresented: $model.showingAddModel, onDismiss: { model.addSheetDismissed() }) { AddModelSheet(target: model.addingTo) }
                .sheet(item: $model.editingModel) { AddModelSheet(editing: $0, target: model.source(of: $0.id)) }
                .sheet(isPresented: $model.showingAddServer, onDismiss: { model.offerTransferAfterPairing() }) { AddServerSheet() }
                .sheet(item: $model.transfer) { TransferSheet(request: $0) }
                .sheet(item: $model.startingModel) { StartSheet(model: $0) }
                .toolbar {
                    ToolbarItem {
                        Button {
                            Task { await model.refreshNow() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .keyboardShortcut("r", modifiers: .command)
                        .disabled(model.refreshing)
                        .help("Ask RunPod and the servers now")
                    }
                }
            }
        }
        .onAppear {
            model.openMainWindow = { openWindow(id: "main") }
            if MoveToApplications.shouldOffer { openWindow(id: "move") }
        }
    }
}

private struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Label("Overview", systemImage: "house").tag(SidebarItem.overview)
            Section(model.servers.isEmpty ? "Models" : "This Mac") {
                ModelRows(source: .local)
                Label("Connection", systemImage: "point.3.connected.trianglepath.dotted").tag(SidebarItem.connection)
                Label("Costs", systemImage: "dollarsign.circle").tag(SidebarItem.costs)
            }
            ForEach(model.servers) { server in
                Section {
                    if server.status != .online { ServerStatusRow(server: server) }
                    ModelRows(source: .server(server.id))
                    Label("Connection", systemImage: "point.3.connected.trianglepath.dotted").tag(SidebarItem.serverConnection(server.id))
                    Label("Costs", systemImage: "dollarsign.circle").tag(SidebarItem.serverCosts(server.id))
                    Label("Server Settings", systemImage: "gearshape").tag(SidebarItem.serverSettings(server.id))
                } header: {
                    Label(server.entry.name, systemImage: "server.rack")
                }
            }
            Section("Podlight") {
                Label("Settings", systemImage: "gearshape").tag(SidebarItem.settings)
                Button { model.showingAddServer = true } label: { Label("Add Server…", systemImage: "plus.circle") }
                    .buttonStyle(.borderless)
                    .help("Run models on a Podlight server, so agents can use them while this Mac is off")
            }
        }
        .listStyle(.sidebar)
        .safeAreaBar(edge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                GatewayStatusBadge()
                Text("Podlight \(Format.appVersion)").font(.caption2).foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }
}

/// The models of one source, then its Add Model button.
private struct ModelRows: View {
    @Environment(AppModel.self) private var model
    let source: Source

    var body: some View {
        ForEach(model.models(in: source)) { item in
            ModelRow(item: item, run: model.run(item.id))
                .tag(SidebarItem.model(item.id))
                .contextMenu {
                    Button("Edit…") { model.editingModel = item }
                        .disabled(model.run(item.id).phase != .stopped && model.run(item.id).phase != .failed)
                    if source == .local, !model.servers.isEmpty {
                        Menu("Hand Over to Server") {
                            ForEach(model.servers) { server in
                                Button(server.entry.name) { model.transfer = TransferRequest(serverID: server.id, models: [item.id], forModel: true) }
                                    .disabled(server.status != .online)
                            }
                        }
                        .disabled(!model.modelsReadyToHandOver.contains { $0.id == item.id })
                    }
                }
        }
        Button {
            model.addModel(to: source)
        } label: {
            Label("Add Model…", systemImage: "plus")
        }
        .buttonStyle(.borderless)
        .disabled(!model.canStart(in: source))
    }
}

/// A server that does not answer, or no longer accepts this app, says so at the top of its section.
struct ServerStatusRow: View {
    let server: ServerMirror

    var body: some View {
        switch server.status {
        case .online: EmptyView()
        case .connecting:
            Label("Connecting…", systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
        case .unreachable:
            Label(server.lastContact.map { String(localized: "Not reachable · as of \(Format.time($0))") } ?? String(localized: "Not reachable"),
                  systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(.orange)
        case .notPaired:
            Label("Pairing revoked", systemImage: "key.slash").font(.caption).foregroundStyle(.red)
        }
    }
}

private struct Detail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.selection {
        case .overview: OverviewView()
        case .model:
            if let item = model.selectedModel { ModelDetailView(item: item) } else { NoModelView() }
        case .connection: ConnectionView()
        case .costs: CostsView()
        case .settings: SettingsContent().navigationTitle("Settings")
        case .serverConnection(let id): ServerConnectionView(serverID: id)
        case .serverCosts(let id): CostsView(source: .server(id))
        case .serverSettings(let id): ServerSettingsView(serverID: id)
        case nil: NoModelView()
        }
    }
}

/// Shown when there is no model to show: first steps instead of an empty pane.
struct NoModelView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.hasRunpodKey {
            ContentUnavailableView {
                Label("Connect Podlight to RunPod", systemImage: "key")
            } description: {
                Text("Podlight needs your RunPod API key to start pods. It takes about a minute.")
            } actions: {
                Button("Set Up…") { model.showingSetup = true }.buttonStyle(.glassProminent)
            }
        } else {
            ContentUnavailableView {
                Label("No Models Yet", systemImage: "cpu")
            } description: {
                Text("Choose a model from Hugging Face. Podlight suggests a GPU and shows what it costs.")
            } actions: {
                Button("Add Model…") { model.showingAddModel = true }.buttonStyle(.glassProminent)
            }
        }
    }
}

/// Whether agents can reach Podlight right now, at the foot of the sidebar.
struct GatewayStatusBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            switch model.gatewayStatus {
            case .running:
                Image(systemName: model.gatewayHost == "0.0.0.0" ? "network" : "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(model.gatewayHost == "0.0.0.0" ? "Reachable on the local network" : "Reachable on this Mac")
            case .starting:
                ProgressView().controlSize(.mini)
                Text("Starting connection…")
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Connection unavailable")
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}
