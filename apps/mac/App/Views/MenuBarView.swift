import PodlightEngine
import SwiftUI

/// The menu bar panel: what runs, until when, at what price, and a way to stop it. Everything
/// here is also in the main window.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.state.activeRuns.isEmpty {
                Label("Nothing is running", systemImage: "lightbulb")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.state.activeRuns, id: \.0.id) { item, run in
                    HStack(spacing: 8) {
                        PhaseIcon(phase: run.phase)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name).font(.body.weight(.medium))
                            Text(line(run)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Stop") { Task { await model.stop(item) } }
                            .controlSize(.small)
                    }
                    .accessibilityElement(children: .combine)
                }
                Divider()
                LabeledContent("Total", value: Format.perHour(model.state.costPerHour)).font(.callout)
            }
            let spend = model.state.spend(on: .now)
            LabeledContent("Today", value: Format.money(spend.todayUsd)).font(.callout).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button("Open Podlight") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 300)
        .onAppear { if model.openMainWindow == nil { model.openMainWindow = { openWindow(id: "main") } } ; if Snapshots.requestedDirectory == nil { model.launch() } }
    }

    private func line(_ run: ModelRun) -> String {
        var parts = [PhaseText.title(run.phase)]
        if let end = run.runUntil { parts.append(String(localized: "\(Format.remaining(until: end)) left")) }
        if let price = run.pricePerHour { parts.append(Format.perHour(price)) }
        return parts.joined(separator: " · ")
    }
}
