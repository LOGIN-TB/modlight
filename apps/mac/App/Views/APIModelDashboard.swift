import Charts
import ModlightEngine
import SwiftUI

/// An API model's page: is it in use right now, what it cost and why, how fast it answers, how
/// close it is to its limits. Figures first, charts next, details folded away.
struct APIModelDetailView: View {
    @Environment(AppModel.self) private var model
    let item: ModlightModel
    @State private var confirmingDelete = false

    private var source: Source { model.source(of: item.id) }
    private var spec: APIModelSpec? { item.api }
    private var tint: Color { Color(nsColor: item.provider.activityColor) }
    private var hasKey: Bool { model.hasVeniceKey(in: source) }

    var body: some View {
        let today = model.apiTotals(item.id, period: AppModel.todayKey)
        let live = model.apiSummary(item.id)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                notices
                tiles(today: today, live: live)
                CardSection("What today's cost is for") {
                    TokenMixBar(newInput: max(0, today.promptTokens - today.cachedTokens), cachedInput: today.cachedTokens,
                                output: today.completionTokens,
                                newInputUsd: price(\.input, max(0, today.promptTokens - today.cachedTokens)),
                                cachedInputUsd: price(\.cacheRead, today.cachedTokens),
                                outputUsd: price(\.output, today.completionTokens),
                                hint: cacheHint(today), tint: tint)
                } accessory: {
                    InfoButton("An agent sends the whole conversation with every request, so input tokens dominate. Tokens the provider already has in its cache cost a fraction. Modlight sends a cache key per agent and system prompt so that requests land where the prefix is cached.")
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        liveChart(live).frame(minWidth: 380)
                        limits(live).frame(width: 280)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        liveChart(live)
                        limits(live)
                    }
                }
                hourChart
                details
                agentsCard
            }
            .padding(20)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .navigationTitle(item.name)
        .toolbar {
            ToolbarItem {
                Button("Rename…") { model.editingModel = item }
            }
        }
        .confirmationDialog("Remove \(item.name)?", isPresented: $confirmingDelete) {
            Button("Remove", role: .destructive) { Task { await model.remove(item) } }
        } message: {
            Text("Nothing is deleted at Venice; you can add the model again at any time.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "sparkles").font(.title2).foregroundStyle(tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(spec?.displayName ?? item.name).font(.title2.weight(.semibold))
                HStack(spacing: 8) {
                    Text(item.provider.displayName)
                    if let spec {
                        PrivacyBadge(privacy: spec.privacy)
                        Text(VeniceText.prices(spec.pricing))
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(pillState, tint: tint, label: pillLabel)
        }
    }

    private var inFlight: Int { source == .local ? model.localInFlight[item.id] ?? 0 : 0 }

    private var pillState: StatusPill.State {
        if !hasKey { return .error }
        return inFlight > 0 ? .active(inFlight) : .ready
    }

    private var pillLabel: String? {
        if !hasKey { return String(localized: "No key") }
        return inFlight > 0 ? String(localized: "\(inFlight) requests running") : String(localized: "Ready")
    }

    @ViewBuilder private var notices: some View {
        if !hasKey {
            Label("Agents get an error until a Venice API key is added (Settings → Providers).", systemImage: "key.slash")
                .foregroundStyle(.orange)
        }
        if let removes = spec?.removesAt {
            Label("Venice retires this model on \(removes.formatted(date: .long, time: .omitted)). Add a successor before then.",
                  systemImage: "calendar.badge.exclamationmark")
                .foregroundStyle(.orange)
        }
        if let error = model.actionError {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        }
    }

    // MARK: Tiles

    private func tiles(today: APIUsageTotals, live: APITelemetrySummary) -> some View {
        let venice = model.performance(of: item)?.lastHour
        let todayCache = today.promptTokens > 0 ? Double(today.cachedTokens) / Double(today.promptTokens) : nil
        return MetricGrid(minimumTileWidth: 128) {
            MetricTile("Cost today", value: Format.smallMoney(today.usd), symbol: "dollarsign.circle",
                       caption: live.usdPerHour > 0 ? String(localized: "≈ \(Format.money(live.usdPerHour))/h now")
                                                    : String(localized: "\(today.requests) requests"),
                       sparkline: live.minutes.map(\.usd), tint: tint)
            MetricTile("Cache hits", value: todayCache.map(Self.percent) ?? "–", symbol: "arrow.triangle.2.circlepath",
                       caption: live.cacheShare.map { String(localized: "last 30 min: \(Self.percent($0))") } ?? String(localized: "share of input from the cache"),
                       sparkline: live.minutes.map { m in m.newInput + m.cachedInput > 0 ? Double(m.cachedInput) / Double(m.newInput + m.cachedInput) : 0 },
                       status: Self.cacheStatus(todayCache), tint: tint)
            MetricTile("Writing", value: live.tokensPerSecondMedian.map { String(localized: "\(Int($0.rounded())) tok/s") } ?? "–",
                       symbol: "text.cursor",
                       caption: venice?.tokensPerSecond.map { String(localized: "Venice median \(Int($0.rounded()))") } ?? String(localized: "median, last 30 min"),
                       tint: tint)
            MetricTile("First token", value: live.ttftP50Ms.map(Self.seconds) ?? "–", symbol: "timer",
                       caption: venice?.ttftP50Ms.map { String(localized: "Venice median \(Self.seconds($0))") } ?? String(localized: "median, last 30 min"),
                       tint: tint)
            MetricTile("Avg. context", value: Self.averageContext(today, live), symbol: "text.alignleft",
                       caption: String(localized: "sent per request"), tint: tint)
            MetricTile("Requests", value: today.requests.formatted(), symbol: "arrow.left.arrow.right",
                       caption: live.requestsPerMinute > 0 ? String(localized: "\(live.requestsPerMinute.formatted(.number.precision(.fractionLength(0...1))))/min now")
                                                           : String(localized: "today"),
                       sparkline: live.minutes.map { Double($0.requests) },
                       status: (live.errorShare ?? 0) > 0.1 ? .warning : .normal, tint: tint)
        }
    }

    static func percent(_ share: Double) -> String { share.formatted(.percent.precision(.fractionLength(0))) }

    static func seconds(_ ms: Int) -> String {
        (Double(ms) / 1000).formatted(.number.precision(.fractionLength(ms < 10_000 ? 1 : 0))) + " s"
    }

    static func cacheStatus(_ share: Double?) -> MetricStatus {
        guard let share else { return .normal }
        return share >= 0.6 ? .good : share >= 0.3 ? .warning : .critical
    }

    static func averageContext(_ today: APIUsageTotals, _ live: APITelemetrySummary) -> String {
        if let average = live.averagePromptTokens { return Format.tokenCount(average) }
        guard today.requests > 0 else { return "–" }
        return Format.tokenCount(today.promptTokens / today.requests)
    }

    // MARK: Cost and cache

    private func price(_ rate: KeyPath<APIRates, Double>, _ tokens: Int) -> Double? {
        guard let pricing = spec?.pricing else { return nil }
        return Double(tokens) * pricing.base[keyPath: rate] / 1_000_000
    }

    private func price(_ rate: KeyPath<APIRates, Double?>, _ tokens: Int) -> Double? {
        guard let pricing = spec?.pricing else { return nil }
        return Double(tokens) * (pricing.base[keyPath: rate] ?? pricing.input) / 1_000_000
    }

    /// When the cache barely helps: what the same day would have cost at 70 % cache hits.
    private func cacheHint(_ today: APIUsageTotals) -> String? {
        guard let pricing = spec?.pricing, today.promptTokens > 100_000 else { return nil }
        let share = Double(today.cachedTokens) / Double(today.promptTokens)
        guard share < 0.3 else { return nil }
        let cached = pricing.cacheRead ?? pricing.input
        let at70 = (Double(today.promptTokens) * (0.3 * pricing.input + 0.7 * cached) + Double(today.completionTokens) * pricing.output) / 1_000_000
        guard at70 < today.usd * 0.9 else { return nil }
        return String(localized: "Only \(Self.percent(share)) of the input came from the cache. Modlight now sends a cache key per agent; at 70 % today would have cost about \(Format.money(at70)).")
    }

    // MARK: Live

    private func liveChart(_ live: APITelemetrySummary) -> some View {
        CardSection("Tokens per minute · last 30 min") {
            let points = live.minutes.enumerated().flatMap { index, minute in
                [TokenPoint(minute: index, kind: String(localized: "New input"), tokens: minute.newInput),
                 TokenPoint(minute: index, kind: String(localized: "Cached input"), tokens: minute.cachedInput),
                 TokenPoint(minute: index, kind: String(localized: "Output"), tokens: minute.output)]
            }
            if live.requests == 0 {
                Text("No requests in the last half hour.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 140)
            } else {
                Chart(points) { point in
                    BarMark(x: .value("Minute", point.minute), y: .value("Tokens", point.tokens))
                        .foregroundStyle(by: .value("Kind", point.kind))
                }
                .chartForegroundStyleScale([String(localized: "New input"): tint, String(localized: "Cached input"): tint.opacity(0.4),
                                            String(localized: "Output"): Color.purple])
                .chartXAxis {
                    AxisMarks(values: [0, 10, 20, 29]) { value in
                        AxisValueLabel { if let i = value.as(Int.self) { Text(i == 29 ? String(localized: "now") : String(localized: "−\(29 - i) min")) } }
                    }
                }
                .chartYAxis { AxisMarks { value in AxisGridLine(); AxisValueLabel { if let v = value.as(Int.self) { Text(Format.tokenCount(v)) } } } }
                .chartLegend(position: .top, alignment: .leading)
                .frame(height: 170)
                .accessibilityLabel(Text("Tokens per minute in the last 30 minutes"))
                .accessibilityValue(Text("\(live.requests) requests, \(Format.tokenCount(live.minutes.map { $0.newInput + $0.cachedInput + $0.output }.reduce(0, +))) tokens"))
            }
        }
    }

    private struct TokenPoint: Identifiable {
        var id: String { "\(minute)-\(kind)" }
        let minute: Int
        let kind: String
        let tokens: Int
    }

    private func limits(_ live: APITelemetrySummary) -> some View {
        CardSection("Limits now") {
            VStack(alignment: .leading, spacing: 12) {
                if let limit = model.apiRateLimit(item.id) {
                    if let total = limit.limitRequests, let left = limit.remainingRequests {
                        MeterRow("Requests per minute", value: Double(total - left), limit: Double(total), tint: tint,
                                 format: { Int($0).formatted() })
                    }
                    if let total = limit.limitTokens, let left = limit.remainingTokens {
                        MeterRow("Tokens per minute", value: Double(total - left), limit: Double(total), tint: tint,
                                 format: { Format.tokenCount(Int($0)) })
                    }
                } else {
                    Text("Rate limits show after the first request.").font(.callout).foregroundStyle(.secondary)
                }
                let spend = model.spend(in: source)
                let split = model.spendSplitByDay(in: source)[AppModel.todayKey] ?? (0, 0)
                MeterRow("Daily limit", value: spend.todayUsd, limit: spend.dailyLimitUsd,
                         segments: [.init(String(localized: "Pods"), value: split.pods, color: .green),
                                    .init(item.provider.displayName, value: split.api, color: tint)])
                if let account = model.veniceAccount(in: source) {
                    VStack(alignment: .leading, spacing: 2) {
                        LabeledContent("Balance", value: VeniceText.balances(account))
                        if let hours = live.runwayHours {
                            Text("Lasts about \(Self.runway(hours)) at the current rate")
                                .font(.caption).foregroundStyle(hours < 2 ? .orange : .secondary)
                        }
                    }
                }
            }
        }
    }

    static func runway(_ hours: Double) -> String {
        if hours >= 48 { return String(localized: "\(Int(hours / 24)) days") }
        if hours >= 1 { return String(localized: "\(Int(hours.rounded())) h") }
        return String(localized: "\(max(1, Int((hours * 60).rounded()))) min")
    }

    private var hourChart: some View {
        CardSection("Cost today by hour") {
            let hours = model.apiCostByHour(item.id, in: source)
            Chart(hours, id: \.hour) { entry in
                BarMark(x: .value("Hour", entry.hour), y: .value("USD", entry.usd), width: .fixed(16))
                    .foregroundStyle(tint)
            }
            .chartXScale(domain: -0.5...23.5)
            .chartXAxis { AxisMarks(values: [0, 6, 12, 18, 23]) { value in AxisValueLabel { if let h = value.as(Int.self) { Text("\(h):00") } } } }
            .chartYAxis { AxisMarks { value in AxisGridLine(); AxisValueLabel { if let v = value.as(Double.self) { Text(Format.money(v)) } } } }
            .frame(height: 140)
            .accessibilityLabel(Text("Cost per hour today"))
            .accessibilityValue(Text(Format.money(hours.map(\.usd).reduce(0, +))))
        }
    }

    // MARK: Details

    private var details: some View {
        CardSection("Model details") {
            DisclosureGroup("Prices, capabilities and Venice's figures") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    if let spec {
                        row("Venice model", spec.providerModelId)
                        row("Price", VeniceText.prices(spec.pricing))
                        if let cached = spec.pricing.cacheRead { row("Cached input", String(localized: "\(Format.perMillion(cached)) per 1M tokens")) }
                        if let above = spec.pricing.extendedAboveTokens, let extended = spec.pricing.extended {
                            row(String(localized: "Above \(Format.tokens(above)) tokens"),
                                VeniceText.prices(APIPricing(input: extended.input, output: extended.output)))
                        }
                        row("Context", String(localized: "\(Format.tokens(item.contextTokens)) tokens"))
                        if let maxOut = spec.maxCompletionTokens { row("Longest answer", String(localized: "\(Format.tokens(maxOut)) tokens")) }
                        if !spec.capabilities.isEmpty { row("Can", spec.capabilities.map(VeniceText.capability).joined(separator: ", ")) }
                        row("Prices as of", Format.time(spec.pricedAt))
                    }
                    if let figures = model.performance(of: item) {
                        if let uptime = figures.uptime24hPercent { row("Uptime at Venice (24 h)", "\(uptime.formatted()) %") }
                        if let p90 = figures.lastHour?.ttftP90Ms { row("First token at Venice, p90", Self.seconds(p90)) }
                    }
                    if let last = model.run(item.id).lastRequestAt { row("Last request", Format.time(last)) }
                }
                .padding(.top, 6)
            }
        }
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    @_disfavoredOverload
    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private var agentsCard: some View {
        CardSection("For agents") {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name).font(.body.monospaced()).textSelection(.enabled)
                    Text("Same address and key as every other model. Claude Code works too; Modlight translates its requests.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy Name") { Pasteboard.copy(item.name) }
                Button("Remove…", role: .destructive) { confirmingDelete = true }
            }
        }
    }
}
