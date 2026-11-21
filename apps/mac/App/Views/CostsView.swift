import Charts
import PodlightEngine
import SwiftUI

/// What the pods of this Mac or of one server cost, against the limits that stop them.
struct CostsView: View {
    @Environment(AppModel.self) private var model
    @State private var editingLimits = false
    var source: Source = .local

    private struct Day: Identifiable {
        var id: Date { date }
        let date: Date
        let usd: Double
    }

    private var spend: Spend { model.spend(in: source) }

    private var spendByDay: [String: Double] {
        switch source {
        case .local: model.state.spendByDay
        case .server(let id): model.server(id)?.snapshot?.spendByDay ?? [:]
        }
    }

    private var runs: [ModelRun] { model.models(in: source).map { model.run($0.id) } }

    private func setLimits(daily: Double?? = .none, monthly: Double?? = .none) async {
        switch source {
        case .local:
            await model.updateSettings { settings in
                if let daily { settings.dailyLimitUsd = daily }
                if let monthly { settings.monthlyLimitUsd = monthly }
            }
        case .server(let id):
            var change = ServerSettingsChange()
            if let daily { change.dailyLimit(daily) }
            if let monthly { change.monthlyLimit(monthly) }
            model.actionError = await model.updateServer(id, change)
        }
    }

    private var lastThirtyDays: [Day] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        return (0..<30).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return Day(date: date, usd: spendByDay[PodlightState.dayKey(date)] ?? 0)
        }
    }

    private var stoppedDiskGB: Int {
        runs.filter { $0.podId != nil && $0.phase == .stopped }.compactMap(\.persistentGB).reduce(0, +)
    }

    var body: some View {
        Form {
            Section("Now") {
                LabeledContent("Running pods", value: "\(model.activeRuns(in: source).count)")
                LabeledContent("Cost per hour", value: Format.perHour(model.costPerHour(in: source)))
            }
            Section {
                LimitRow(title: "Today", spent: spend.todayUsd, limit: spend.dailyLimitUsd)
                LimitRow(title: "This month", spent: spend.monthUsd, limit: spend.monthlyLimitUsd)
                Button("Change Limits…") { editingLimits = true }
                    .popover(isPresented: $editingLimits, arrowEdge: .bottom) {
                        Form {
                            LimitField(title: "Per day", value: spend.dailyLimitUsd) { v in await setLimits(daily: .some(v)) }
                            LimitField(title: "Per month", value: spend.monthlyLimitUsd) { v in await setLimits(monthly: .some(v)) }
                            Text("Leave a field empty for no limit.").font(.caption).foregroundStyle(.secondary)
                        }
                        .formStyle(.grouped)
                        .frame(width: 320)
                    }
            } header: {
                Text("Spending limits")
            } footer: {
                Text(source == .local
                     ? "At a limit, Podlight stops this Mac's pods and does not start or wake them again until the next day or month."
                     : "At a limit, the server stops its pods and does not start or wake them again until the next day or month. Days are counted in the server's time zone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Last 30 days") {
                Chart(lastThirtyDays) { day in
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value("USD", day.usd))
                }
                .chartYAxis { AxisMarks { AxisValueLabel(format: .currency(code: "USD")) ; AxisGridLine() } }
                .frame(height: 160)
                .accessibilityLabel(Text("Spending per day, last 30 days"))
                .accessibilityValue(Text("Total \(Format.money(lastThirtyDays.map(\.usd).reduce(0, +)))"))
            }
            if stoppedDiskGB > 0 {
                Section("Kept disks") {
                    LabeledContent("Disk kept", value: "\(stoppedDiskGB) GB")
                    LabeledContent("Costs while stopped", value: String(localized: "about \(Format.money(StoragePricing.stoppedPerMonth(volumeGB: stoppedDiskGB))) a month"))
                    Text("Models with \"Keep model on disk\" switched on keep their disk while stopped, so the next start skips the download. RunPod charges 0.20 USD per GB and month for it; it is included in the figures above. Podlight deletes pods left unused for \(model.deleteStoppedAfterDays(in: source)) days.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Text(source == .local
                     ? "These figures are Podlight's own count of this Mac's pods (price per hour × running time). Your RunPod account shows the exact charges, including other pods."
                     : "These figures are the server's own count of its pods (price per hour × running time). Your RunPod account shows the exact charges, including other pods.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Open RunPod billing", destination: Links.runpodBilling)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(source == .local ? String(localized: "Costs") : String(localized: "Costs · \(model.name(of: source))"))
    }
}

struct LimitRow: View {
    let title: LocalizedStringKey
    let spent: Double
    let limit: Double?

    var body: some View {
        if let limit, limit > 0 {
            Gauge(value: min(spent, limit), in: 0...limit) {
                Text(title)
            } currentValueLabel: {
                Text("\(Format.money(spent)) of \(Format.money(limit))")
            }
            .tint(spent >= limit ? .red : spent >= limit * 0.8 ? .orange : .accentColor)
        } else {
            LabeledContent(title) { Text("\(Format.money(spent)), no limit") }
        }
    }
}
