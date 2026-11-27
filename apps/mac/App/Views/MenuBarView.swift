import ModlightEngine
import SwiftUI

/// The menu bar panel: what runs, until when, at what price, and a way to stop it. Everything
/// here is also in the main window.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let apiModels = model.activeAPIModels
            if model.allActiveRuns.isEmpty && apiModels.isEmpty {
                Label("Nothing is running", systemImage: "lightbulb")
                    .foregroundStyle(.secondary)
            } else if !model.allActiveRuns.isEmpty {
                ForEach(model.allActiveRuns, id: \.1.id) { source, item, run in
                    HStack(spacing: 8) {
                        PhaseIcon(phase: run.phase)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name).font(.body.weight(.medium))
                            Text(line(source, run)).font(.caption).foregroundStyle(.secondary)
                            if run.phase == .ready, let gpu = UsageText.gpu(model.telemetry(item.id)) {
                                Text(gpu).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Stop") { Task { await model.stop(item) } }
                            .controlSize(.small)
                    }
                    .accessibilityElement(children: .combine)
                }
                Divider()
                LabeledContent("Total", value: Format.perHour(model.totalCostPerHour)).font(.callout)
            }
            if !apiModels.isEmpty {
                ForEach(apiModels, id: \.model.id) { entry in
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(Color(nsColor: entry.model.provider.activityColor))
                            .frame(width: 20)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.model.name).font(.body.weight(.medium))
                            Text(apiLine(entry.source, entry.model, entry.inFlight)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Sparkline(values: model.apiSummary(entry.model.id).minutes.suffix(15).map { Double($0.newInput + $0.cachedInput + $0.output) },
                                  color: Color(nsColor: entry.model.provider.activityColor))
                            .frame(width: 60, height: 20)
                    }
                    .accessibilityElement(children: .combine)
                }
                Divider()
            }
            let spend = model.state.spend(on: .now)
            LabeledContent("Today", value: Format.money(spend.todayUsd)).font(.callout).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button("Open Modlight") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Spacer()
                Text(Format.appVersion).font(.caption).foregroundStyle(.tertiary)
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 300)
        .onAppear { if model.openMainWindow == nil { model.openMainWindow = { openWindow(id: "main") } } ; if Snapshots.requestedDirectory == nil { model.launch() } }
    }

    private func apiLine(_ source: Source, _ item: ModlightModel, _ inFlight: Int) -> String {
        var parts = [item.provider.displayName]
        if case .server = source { parts.insert(model.name(of: source), at: 0) }
        parts.append(inFlight > 0 ? String(localized: "\(inFlight) requests running") : String(localized: "just used"))
        let today = model.apiTotals(item.id, period: AppModel.todayKey)
        if today.requests > 0 { parts.append(String(localized: "today \(Format.smallMoney(today.usd))")) }
        return parts.joined(separator: " · ")
    }

    private func line(_ source: Source, _ run: ModelRun) -> String {
        var parts = [PhaseText.title(run.phase)]
        if case .server = source { parts.insert(model.name(of: source), at: 0) }
        if let end = run.runUntil { parts.append(String(localized: "\(Format.remaining(until: end)) left")) }
        if let price = run.pricePerHour { parts.append(Format.perHour(price)) }
        return parts.joined(separator: " · ")
    }
}
