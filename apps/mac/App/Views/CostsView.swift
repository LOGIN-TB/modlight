import Charts
import PodlightEngine
import SwiftUI

/// What the pods and Venice models of this Mac or of one server cost, against the limits that stop them.
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

    private var keptDisks: [KeptDisk] { model.keptDisks(in: source) }

    private var balance: RunpodBalance? {
        switch source {
        case .local: model.localBalance
        case .server(let id): model.server(id)?.snapshot?.balance
        }
    }

    var body: some View {
        Form {
            Section("Now") {
                LabeledContent("Running pods", value: "\(model.activeRuns(in: source).count)")
                LabeledContent("Cost per hour", value: Format.perHour(model.costPerHour(in: source)))
                if !keptDisks.isEmpty {
                    LabeledContent("Kept disks (\(keptDisks.gb) GB)", value: Format.keptDisk(perHour: keptDisks.perHour, perMonth: keptDisks.perMonth))
                }
                BalanceRow(balance: balance)
            }
            VeniceCostsSection(source: source)
            let models = model.models(in: source).filter(\.isPod)
            if !models.isEmpty {
                Section {
                    ForEach(models) { item in
                        ModelCostRow(item: item, run: model.run(item.id), keptGB: keptDisks.first { $0.id == item.id }?.gb)
                    }
                } header: {
                    Text("Pods")
                } footer: {
                    Text("Running models are billed for the GPU and their storage. A stopped model costs nothing unless it keeps its disk: RunPod bills that disk by the hour (0.20 USD per GB and month) until Podlight deletes it after \(model.deleteStoppedAfterDays(in: source)) days without use. These costs are included in the figures below.")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
                     ? "At a limit, Podlight stops this Mac's pods, does not start or wake them again, and refuses requests to Venice models until the next day or month."
                     : "At a limit, the server stops its pods, does not start or wake them again, and refuses requests to Venice models until the next day or month. Days are counted in the server's time zone.")
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
            Section {
                Text(source == .local
                     ? "These figures are Podlight's own count: pods as price per hour × running time, Venice models from the cost or tokens in each answer. Your RunPod and Venice accounts show the exact charges, including use outside Podlight."
                     : "These figures are the server's own count: pods as price per hour × running time, Venice models from the cost or tokens in each answer. Your RunPod and Venice accounts show the exact charges, including use outside Podlight.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Open RunPod billing", destination: Links.runpodBilling)
                Link("Open Venice API settings", destination: Links.veniceAPIKeys)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(source == .local ? String(localized: "Costs") : String(localized: "Costs · \(model.name(of: source))"))
        .task { if source == .local { await model.refreshBalance(); await model.refreshVeniceAccount() } }
    }
}

/// The RunPod account's credit and how long it lasts at the account's current rate (all its pods,
/// not only Podlight's), orange under a day and red under three hours.
struct BalanceRow: View {
    let balance: RunpodBalance?

    var body: some View {
        if let balance {
            LabeledContent {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Format.money(balance.usd)).foregroundStyle(color(balance)).monospacedDigit()
                    Text(lasts(balance)).font(.caption).foregroundStyle(color(balance) == .primary ? .secondary : color(balance))
                }
            } label: {
                Text("Credit at RunPod")
                if let checked = balance.checkedAt {
                    Text("As of \(Format.time(checked)), for the whole account").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            LabeledContent("Credit at RunPod") {
                Text("Not available").foregroundStyle(.secondary)
            }
            .help(Text("RunPod did not answer, or the API key may not read the account."))
        }
    }

    private func color(_ balance: RunpodBalance) -> Color {
        guard let hours = balance.hoursLeft else { return .primary }
        return hours < 3 ? .red : hours < 24 ? .orange : .primary
    }

    private func lasts(_ balance: RunpodBalance) -> String {
        guard let hours = balance.hoursLeft else { return String(localized: "Nothing in the account costs anything right now") }
        let rate = Format.perHour(balance.spendPerHourUsd)
        if hours < 1 { return String(localized: "Lasts under an hour at \(rate)") }
        if hours < 48 { return String(localized: "Lasts about \(Int(hours.rounded())) hours at \(rate)") }
        return String(localized: "Lasts about \(Int((hours / 24).rounded())) days at \(rate)")
    }
}

/// One model and what it costs right now: running, stopped with its disk kept, or nothing.
private struct ModelCostRow: View {
    let item: PodlightModel
    let run: ModelRun
    let keptGB: Int?

    private var isActive: Bool { run.managedBy == nil && [.creating, .loading, .ready, .stopping].contains(run.phase) }

    var body: some View {
        LabeledContent {
            if isActive, let price = run.pricePerHour {
                Text(Format.perHour(price + (run.storagePerHour ?? 0)))
            } else if let keptGB {
                Text(Format.keptDisk(gb: keptGB))
            } else {
                Text("nothing")
            }
        } label: {
            Text(item.name)
            Text(caption)
        }
    }

    private var caption: String {
        if let other = run.managedBy { return String(localized: "Managed by \(PodOwner.displayName(of: other))") }
        if isActive {
            if let price = run.pricePerHour, let storage = run.storagePerHour, storage > 0 {
                return String(localized: "Running · \(Format.perHour(price)) GPU + \(Format.storagePerHour(storage)) storage")
            }
            return String(localized: "Running")
        }
        if let keptGB { return String(localized: "Stopped · disk kept (\(keptGB) GB)") }
        return item.keepDisk
            ? String(localized: "Stopped · nothing on disk right now")
            : String(localized: "Stopped · disk not kept")
    }
}

struct LimitRow: View {
    let title: LocalizedStringKey
    let spent: Double
    let limit: Double?

    /// Like every other row: the name on the left, the amount on the right, the bar beneath. The
    /// grouped form centres a Gauge's labels, which read as a heading over each bar.
    var body: some View {
        if let limit, limit > 0 {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent(title) { Text("\(Format.money(spent)) of \(Format.money(limit))").monospacedDigit() }
                ProgressView(value: min(spent, limit), total: limit)
                    .progressViewStyle(.linear)
                    .tint(spent >= limit ? .red : spent >= limit * 0.8 ? .orange : .accentColor)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)
        } else {
            LabeledContent(title) { Text("\(Format.money(spent)), no limit") }
        }
    }
}
