import Charts
import PodlightEngine
import SwiftUI

/// What this Mac's pods cost, against the limits that stop them.
struct CostsView: View {
    @Environment(AppModel.self) private var model

    private struct Day: Identifiable {
        var id: Date { date }
        let date: Date
        let usd: Double
    }

    private var spend: Spend { model.state.spend(on: .now) }

    private var lastThirtyDays: [Day] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        return (0..<30).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return Day(date: date, usd: model.state.spendByDay[PodlightState.dayKey(date)] ?? 0)
        }
    }

    private var stoppedDiskGB: Int {
        model.state.runs.values.filter { $0.podId != nil && $0.phase == .stopped }.compactMap(\.persistentGB).reduce(0, +)
    }

    var body: some View {
        Form {
            Section("Now") {
                LabeledContent("Running pods", value: "\(model.state.activeRuns.count)")
                LabeledContent("Cost per hour", value: Format.perHour(model.state.costPerHour))
            }
            Section {
                LimitRow(title: "Today", spent: spend.todayUsd, limit: spend.dailyLimitUsd)
                LimitRow(title: "This month", spent: spend.monthUsd, limit: spend.monthlyLimitUsd)
                SettingsLink { Text("Change limits…") }
            } header: {
                Text("Spending limits")
            } footer: {
                Text("At a limit, Podlight stops this Mac's pods and does not start or wake them again until the next day or month.")
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
                Section("Stopped pods") {
                    LabeledContent("Disk kept", value: "\(stoppedDiskGB) GB")
                    Text("Stopped pods keep their disk so the next start skips the download. RunPod charges a few cents per GB and month for it. Podlight deletes pods left unused for \(model.state.settings.deleteStoppedAfterDays) days.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Text("These figures are Podlight's own count of this Mac's pods (price per hour × running time). Your RunPod account shows the exact charges, including other pods.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Open RunPod billing", destination: Links.runpodBilling)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Costs")
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
