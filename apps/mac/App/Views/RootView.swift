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
                .sheet(isPresented: $model.showingAddModel, onDismiss: { model.addSheetDismissed() }) { AddModelSheet() }
                .sheet(item: $model.editingModel) { AddModelSheet(editing: $0) }
                .sheet(item: $model.startingModel) { StartSheet(model: $0) }
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
            Section("Models") {
                ForEach(model.state.models) { item in
                    ModelRow(item: item, run: model.state.run(item.id))
                        .tag(SidebarItem.model(item.id))
                        .contextMenu {
                            Button("Edit…") { model.editingModel = item }
                                .disabled(model.state.run(item.id).phase != .stopped && model.state.run(item.id).phase != .failed)
                        }
                }
                Button {
                    model.showingAddModel = true
                } label: {
                    Label("Add Model…", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(!model.hasRunpodKey)
            }
            Section("Podlight") {
                Label("Connection", systemImage: "point.3.connected.trianglepath.dotted").tag(SidebarItem.connection)
                Label("Costs", systemImage: "dollarsign.circle").tag(SidebarItem.costs)
                Label("Settings", systemImage: "gearshape").tag(SidebarItem.settings)
            }
        }
        .listStyle(.sidebar)
        .safeAreaBar(edge: .bottom) { GatewayStatusBadge().padding(.horizontal, 12).padding(.vertical, 8) }
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
