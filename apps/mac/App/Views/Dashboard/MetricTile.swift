import Charts
import SwiftUI

/// One figure as a small tile: what it is, the value, what the value means, and optionally its
/// recent course as a sparkline and a status (icon and colour together).
///
///     MetricTile("Writing", value: "42 tokens/s", symbol: "text.cursor", caption: "while it answers")
///     MetricTile(metric)   // from a data-driven list of `MetricTile.Metric`
struct MetricTile: View {
    /// The same figure as a value, for grids built from data.
    struct Metric: Identifiable, Hashable {
        let id: String
        var symbol: String? = nil
        var title: String
        var value: String
        var caption: String? = nil
        var sparkline: [Double] = []
        var status: MetricStatus = .normal
    }

    private let title: Text
    private let value: String
    private let symbol: String?
    private let caption: String?
    private let sparkline: [Double]
    private let status: MetricStatus
    private let tint: Color

    /// - Parameters:
    ///   - title: what the figure is, short ("Writing", "Today").
    ///   - value: the figure, already formatted.
    ///   - symbol: an SF Symbol before the title.
    ///   - caption: a trend or comparison under the value ("while it answers", "+12 % on yesterday").
    ///   - sparkline: recent values, oldest first; drawn when there are at least two.
    ///   - status: tints the value and adds its icon.
    ///   - tint: the sparkline's colour while the status is normal (pod green, Venice blue).
    init(_ title: LocalizedStringKey, value: String, symbol: String? = nil, caption: String? = nil,
         sparkline: [Double] = [], status: MetricStatus = .normal, tint: Color = .accentColor) {
        self.init(title: Text(title), value: value, symbol: symbol, caption: caption, sparkline: sparkline, status: status, tint: tint)
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, value: String, symbol: String? = nil, caption: String? = nil,
                            sparkline: [Double] = [], status: MetricStatus = .normal, tint: Color = .accentColor) {
        self.init(title: Text(title), value: value, symbol: symbol, caption: caption, sparkline: sparkline, status: status, tint: tint)
    }

    init(_ metric: Metric, tint: Color = .accentColor) {
        self.init(title: Text(metric.title), value: metric.value, symbol: metric.symbol, caption: metric.caption,
                  sparkline: metric.sparkline, status: metric.status, tint: tint)
    }

    private init(title: Text, value: String, symbol: String?, caption: String?, sparkline: [Double], status: MetricStatus, tint: Color) {
        self.title = title
        self.value = value
        self.symbol = symbol
        self.caption = caption
        self.sparkline = sparkline
        self.status = status
        self.tint = tint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            heading
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let icon = status.symbol {
                    Image(systemName: icon).font(.callout).foregroundStyle(status.color ?? .primary)
                }
                Text(value)
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(status.color ?? .primary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            // Always a caption line, so tiles in one row keep the same height.
            Text(caption ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if sparkline.count >= 2 {
                Sparkline(values: sparkline, color: status.color ?? tint)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        // Fills its grid row, so a tile without a sparkline is as tall as its neighbour with one.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(Text([value, status.spoken, caption, Sparkline.trend(sparkline)].compactMap { $0 }.joined(separator: ", ")))
    }

    @ViewBuilder private var heading: some View {
        if let symbol {
            Label { title } icon: { Image(systemName: symbol) }
                .font(.caption).foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
        } else {
            title.font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

/// A small line with a soft fill under it, without axes: the course, not the numbers.
struct Sparkline: View {
    let values: [Double]
    var color: Color = .accentColor
    @ScaledMetric private var height: CGFloat = 24

    var body: some View {
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        // A flat series sits in the middle instead of on the floor.
        let pad = high > low ? (high - low) * 0.1 : max(abs(high) * 0.5, 1)
        Chart(Array(values.enumerated()), id: \.offset) { point in
            AreaMark(x: .value("Sample", point.offset), yStart: .value("Floor", low - pad), yEnd: .value("Value", point.element))
                .foregroundStyle(color.opacity(0.15))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Sample", point.offset), y: .value("Value", point.element))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartXScale(domain: 0...(values.count - 1))
        .chartYScale(domain: (low - pad)...(high + pad))
        .frame(height: height)
        .accessibilityLabel(Text("Trend"))
        .accessibilityValue(Text(Self.trend(values) ?? ""))
    }

    /// "Rising", "Falling" or "Steady": the last value against the first, beyond 5 % of the range
    /// of values seen.
    static func trend(_ values: [Double]) -> String? {
        guard values.count >= 2, let first = values.first, let last = values.last,
              let low = values.min(), let high = values.max() else { return nil }
        let band = max((high - low) * 0.05, abs(first) * 0.05)
        if last > first + band { return String(localized: "Rising trend") }
        if last < first - band { return String(localized: "Falling trend") }
        return String(localized: "Steady trend")
    }
}

// Sample text is plain `String` (through `Metric`), so it stays out of the string catalog.
private let sampleMetrics: [MetricTile.Metric] = [
    .init(id: "writing", symbol: "text.cursor", title: "Writing", value: "48 tokens/s", caption: "while it answers",
          sparkline: [31, 38, 44, 41, 47, 52, 48]),
    .init(id: "cache", symbol: "arrow.triangle.2.circlepath", title: "Prompt cache", value: "82 %", caption: "of prompt tokens reused"),
    .init(id: "today", title: "Today", value: "$4.31", caption: "+18 % on yesterday",
          sparkline: [2.1, 3.4, 2.8, 3.9, 3.6, 4.31], status: .warning),
    .init(id: "card", symbol: "thermometer.medium", title: "Card", value: "91 °C", caption: "312 of 350 W", status: .critical),
    .init(id: "requests", symbol: "arrow.left.arrow.right", title: "Requests", value: "2 running", caption: "0 waiting", status: .good),
    .init(id: "totals", symbol: "sum", title: "Since the start", value: "1.2M read"),
]

#Preview("Tiles", traits: .fixedLayout(width: 520, height: 280)) {
    MetricGrid { ForEach(sampleMetrics) { MetricTile($0, tint: .green) } }
        .padding()
}

#Preview("Tiles · dark", traits: .fixedLayout(width: 520, height: 280)) {
    MetricGrid { ForEach(sampleMetrics) { MetricTile($0, tint: .blue) } }
        .padding()
        .preferredColorScheme(.dark)
}
