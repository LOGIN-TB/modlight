import Charts
import ModlightEngine
import SwiftUI

/// What the pods and Venice models of this Mac or of one server cost, against the limits that stop them.
struct CostsView: View {
    @Environment(AppModel.self) private var model
    @State private var editingLimits = false
    var source: Source = .local


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


    private var keptDisks: [KeptDisk] { model.keptDisks(in: source) }

    private var balance: RunpodBalance? {
        switch source {
        case .local: model.localBalance
        case .server(let id): model.server(id)?.snapshot?.balance
        }
    }

    private var apiModels: [ModlightModel] { model.models(in: source).filter { !$0.isPod } }
    private var podModels: [ModlightModel] { model.models(in: source).filter(\.isPod) }
    /// What API models cost per hour at the moment, from the last 15 minutes.
    private var apiPerHour: Double { apiModels.map { model.apiSummary($0.id).usdPerHour }.reduce(0, +) }

    var body: some View {
        let split = model.spendSplitByDay(in: source)
        let today = split[AppModel.todayKey] ?? (0, 0)
        let month = split.filter { $0.key.hasPrefix(AppModel.monthKey) }.values
            .reduce((pods: 0.0, api: 0.0)) { ($0.pods + $1.pods, $0.api + $1.api) }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                tiles
                CardSection("Spending limits") {
                    VStack(alignment: .leading, spacing: 14) {
                        MeterRow("Today", value: spend.todayUsd, limit: spend.dailyLimitUsd, segments: segments(today))
                        MeterRow("This month", value: spend.monthUsd, limit: spend.monthlyLimitUsd, segments: segments(month))
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
                    }
                } accessory: {
                    InfoButton(source == .local
                               ? "At a limit, Modlight stops this Mac's pods, does not start or wake them again, and refuses requests to Venice models until the next day or month."
                               : "At a limit, the server stops its pods, does not start or wake them again, and refuses requests to Venice models until the next day or month. Days are counted in the server's time zone.")
                }
                CardSection("Last 30 days") {
                    thirtyDays(split)
                } accessory: {
                    InfoButton(source == .local
                               ? "These figures are Modlight's own count: pods as price per hour × running time, Venice models from the cost or tokens in each answer. Your RunPod and Venice accounts show the exact charges, including use outside Modlight."
                               : "These figures are the server's own count: pods as price per hour × running time, Venice models from the cost or tokens in each answer. Your RunPod and Venice accounts show the exact charges, including use outside Modlight.")
                }
                if !apiModels.isEmpty {
                    CardSection("Venice models this month") { apiRanking }
                }
                if !podModels.isEmpty {
                    CardSection("Pods") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(podModels) { item in
                                ModelCostRow(item: item, run: model.run(item.id), keptGB: keptDisks.first { $0.id == item.id }?.gb)
                            }
                            if !keptDisks.isEmpty {
                                Divider()
                                HStack {
                                    Text("Kept disks (\(keptDisks.gb) GB)")
                                    Spacer()
                                    Text(Format.keptDisk(perHour: keptDisks.perHour, perMonth: keptDisks.perMonth)).monospacedDigit()
                                }
                            }
                        }
                    } accessory: {
                        InfoButton("Running models are billed for the GPU and their storage. A stopped model costs nothing unless it keeps its disk: RunPod bills that disk by the hour (0.20 USD per GB and month) until Modlight deletes it after \(model.deleteStoppedAfterDays(in: source)) days without use. These costs are included in the figures above.")
                    }
                }
                HStack(spacing: 16) {
                    Link("Open RunPod billing", destination: Links.runpodBilling)
                    Link("Open Venice API settings", destination: Links.veniceAPIKeys)
                }
                .font(.callout)
            }
            .padding(20)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .navigationTitle(source == .local ? String(localized: "Costs") : String(localized: "Costs · \(model.name(of: source))"))
        .task { if source == .local { await model.refreshBalance(); await model.refreshVeniceAccount() } }
    }

    private func segments(_ split: (pods: Double, api: Double)) -> [MeterRow.Segment] {
        guard split.api > 0 else { return [] }
        return [.init(String(localized: "Pods"), value: split.pods, color: .green),
                .init("Venice", value: split.api, color: Color(nsColor: ModelProvider.venice.activityColor))]
    }

    private var tiles: some View {
        let podsPerHour = model.costPerHour(in: source)
        let venice = model.veniceAccount(in: source)
        return MetricGrid(minimumTileWidth: 150) {
            MetricTile("Today", value: Format.money(spend.todayUsd), symbol: "calendar",
                       caption: spend.dailyLimitUsd.map { String(localized: "of \(Format.money($0))") } ?? String(localized: "no limit"),
                       status: Self.limitStatus(spend.todayUsd, spend.dailyLimitUsd))
            MetricTile("This month", value: Format.money(spend.monthUsd), symbol: "calendar.badge.clock",
                       caption: spend.monthlyLimitUsd.map { String(localized: "of \(Format.money($0))") } ?? String(localized: "no limit"),
                       status: Self.limitStatus(spend.monthUsd, spend.monthlyLimitUsd))
            MetricTile("Cost per hour now", value: Format.perHour(podsPerHour + apiPerHour), symbol: "speedometer",
                       caption: String(localized: "pods \(Format.money(podsPerHour)) · Venice \(Format.money(apiPerHour))"))
            if let balance {
                MetricTile("RunPod credit", value: Format.money(balance.usd), symbol: "cpu",
                           caption: balance.hoursLeft.map { String(localized: "lasts about \(APIModelDetailView.runway($0))") }
                                    ?? String(localized: "nothing running"),
                           status: (balance.hoursLeft ?? .infinity) < 24 ? .warning : .normal, tint: .green)
            }
            if let venice {
                let usd = venice.usd ?? 0
                MetricTile("Venice credit", value: VeniceText.balances(venice), symbol: "sparkles",
                           caption: apiPerHour > 0 ? String(localized: "lasts about \(APIModelDetailView.runway(usd / apiPerHour))")
                                                   : String(localized: "nothing in use"),
                           status: apiPerHour > 0 && usd / apiPerHour < 2 ? .warning : .normal,
                           tint: Color(nsColor: ModelProvider.venice.activityColor))
            }
        }
    }

    static func limitStatus(_ spent: Double, _ limit: Double?) -> MetricStatus {
        guard let limit, limit > 0 else { return .normal }
        return spent >= limit ? .critical : spent >= limit * 0.8 ? .warning : .normal
    }

    private struct DayPart: Identifiable {
        var id: String { "\(date.timeIntervalSince1970)-\(kind)" }
        let date: Date
        let kind: String
        let usd: Double
    }

    private func thirtyDays(_ split: [String: (pods: Double, api: Double)]) -> some View {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: .now)
        let parts: [DayPart] = (0..<30).reversed().flatMap { offset -> [DayPart] in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: start) else { return [] }
            let day = split[ModlightState.dayKey(date)] ?? (0, 0)
            return [DayPart(date: date, kind: String(localized: "Pods"), usd: day.pods),
                    DayPart(date: date, kind: "Venice", usd: day.api)]
        }
        let total = parts.map(\.usd).reduce(0, +)
        return Chart(parts) { part in
            BarMark(x: .value("Day", part.date, unit: .day), y: .value("USD", part.usd))
                .foregroundStyle(by: .value("Kind", part.kind))
        }
        .chartForegroundStyleScale([String(localized: "Pods"): Color.green, "Venice": Color(nsColor: ModelProvider.venice.activityColor)])
        .chartLegend(position: .top, alignment: .leading)
        .chartYAxis { AxisMarks { AxisValueLabel(format: .currency(code: "USD")); AxisGridLine() } }
        .frame(height: 170)
        .accessibilityLabel(Text("Spending per day, last 30 days, pods and Venice"))
        .accessibilityValue(Text("Total \(Format.money(total))"))
    }

    private var apiRanking: some View {
        let rows = apiModels.map { ($0, model.apiTotals($0.id, period: AppModel.monthKey)) }.sorted { $0.1.usd > $1.1.usd }
        let top = max(rows.first?.1.usd ?? 0, 0.0001)
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(rows, id: \.0.id) { item, totals in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "sparkles").foregroundStyle(Color(nsColor: item.provider.activityColor)).accessibilityHidden(true)
                        Text(item.name)
                        Spacer()
                        Text(Format.smallMoney(totals.usd)).monospacedDigit()
                    }
                    GeometryReader { geo in
                        Capsule().fill(Color(nsColor: item.provider.activityColor))
                            .frame(width: max(2, geo.size.width * totals.usd / top), height: 6)
                    }
                    .frame(height: 6)
                    .accessibilityHidden(true)
                    Text(totals.requests == 0 ? String(localized: "No requests this month")
                         : String(localized: "\(totals.requests) requests · \(Format.tokenCount(totals.promptTokens + totals.completionTokens)) tokens · cache \(APIModelDetailView.percent(totals.promptTokens > 0 ? Double(totals.cachedTokens) / Double(totals.promptTokens) : 0))"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct ModelCostRow: View {
    let item: ModlightModel
    let run: ModelRun
    let keptGB: Int?

    private var isActive: Bool { run.managedBy == nil && [.creating, .loading, .ready, .stopping].contains(run.phase) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: isActive ? "lightbulb.max.fill" : "lightbulb")
                .foregroundStyle(isActive ? Color.green : Color.secondary).frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Group {
                if isActive, let price = run.pricePerHour {
                    Text(Format.perHour(price + (run.storagePerHour ?? 0)))
                } else if let keptGB {
                    Text(Format.keptDisk(gb: keptGB))
                } else {
                    Text("nothing")
                }
            }
            .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
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

/// An amount against its limit. Kept for the pages not yet rebuilt on `MeterRow`, which draws it.
struct LimitRow: View {
    let title: LocalizedStringKey
    let spent: Double
    let limit: Double?

    var body: some View {
        MeterRow(title, value: spent, limit: limit)
    }
}
