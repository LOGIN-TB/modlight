import PodlightEngine
import SwiftUI

/// The main window: a sidebar with the three areas of "This Mac", and the chosen area beside it.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        if model.showingSetup {
            // Inline, not a sheet: macOS refuses to quit an app while a sheet is attached, and the
            // first launch must always be easy to leave.
            SetupView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { model.openMainWindow = { openWindow(id: "main") } }
        } else {
            main
        }
    }

    private var main: some View {
        @Bindable var model = model
        return NavigationSplitView {
            List(selection: $model.selection) {
                Section("This Mac") {
                    Label("Models", systemImage: "cpu").tag(SidebarItem.models)
                    Label("Connection", systemImage: "point.3.connected.trianglepath.dotted").tag(SidebarItem.connection)
                    Label("Costs", systemImage: "dollarsign.circle").tag(SidebarItem.costs)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) { GatewayStatusBadge().padding(10) }
        } detail: {
            switch model.selection ?? .models {
            case .models: ModelsView()
            case .connection: ConnectionView()
            case .costs: CostsView()
            }
        }
        .sheet(isPresented: $model.showingAddModel) { AddModelSheet() }
        .sheet(item: $model.startingModel) { StartSheet(model: $0) }
        .onAppear { model.openMainWindow = { openWindow(id: "main") } }
    }
}

/// Whether agents can reach Podlight right now. Shown at the foot of the sidebar.
struct GatewayStatusBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            switch model.gatewayStatus {
            case .running:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Listening on port \(String(model.gatewayPort))")
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
