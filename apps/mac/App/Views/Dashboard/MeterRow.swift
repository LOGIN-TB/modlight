import SwiftUI

/// An amount against its limit, like every other row: the name on the left, "x of y" on the right,
/// a capsule bar beneath. At 80 % the bar and amount turn orange, at 100 % red, each with an icon
/// so colour is never the only signal. Segments split the bar by who spent it (pods green, Venice
/// blue inside one daily limit) and add a small legend. Without a limit it says so and draws no bar.
///
///     MeterRow("Today", value: 6.12, limit: 20)
///     MeterRow("Today", value: 6.12, limit: 20, segments: [
///         .init("Pods", value: 5.70, color: .green), .init("Venice", value: 0.42, color: .blue)])
struct MeterRow: View {
    struct Segment: Identifiable, Hashable {
        var id: String { label }
        let label: String
        let value: Double
        let color: Color

        init(_ label: String, value: Double, color: Color) {
            self.label = label
            self.value = value
            self.color = color
        }
    }

    private let title: Text
    private let value: Double
    private let limit: Double?
    private let segments: [Segment]
    private let tint: Color
    private let format: (Double) -> String
    @ScaledMetric private var barHeight: CGFloat = 6

    /// - Parameters:
    ///   - value: the amount so far; with segments, normally their sum.
    ///   - limit: nil or 0 for "no limit".
    ///   - segments: parts of the amount in their own colours, drawn in this order.
    ///   - tint: the bar's colour below 80 % when there are no segments.
    ///   - format: how amounts read; dollars by default.
    init(_ title: LocalizedStringKey, value: Double, limit: Double?, segments: [Segment] = [],
         tint: Color = .accentColor, format: @escaping (Double) -> String = Format.money) {
        self.init(title: Text(title), value: value, limit: limit, segments: segments, tint: tint, format: format)
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, value: Double, limit: Double?, segments: [Segment] = [],
                            tint: Color = .accentColor, format: @escaping (Double) -> String = Format.money) {
        self.init(title: Text(title), value: value, limit: limit, segments: segments, tint: tint, format: format)
    }

    private init(title: Text, value: Double, limit: Double?, segments: [Segment], tint: Color, format: @escaping (Double) -> String) {
        self.title = title
        self.value = value
        self.limit = limit
        self.segments = segments.filter { $0.value > 0 }
        self.tint = tint
        self.format = format
    }

    private var level: MetricStatus {
        guard let limit, limit > 0 else { return .normal }
        return value >= limit ? .critical : value >= limit * 0.8 ? .warning : .normal
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let limit, limit > 0 {
                heading {
                    HStack(spacing: 4) {
                        if let icon = level.symbol { Image(systemName: icon) }
                        Text("\(format(value)) of \(format(limit))").monospacedDigit()
                    }
                    .foregroundStyle(level.color ?? .secondary)
                }
                bar(limit: limit)
            } else {
                heading {
                    Text("\(format(value)), no limit").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if !segments.isEmpty { legend }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(Text(spokenValue))
    }

    /// Name left, amount right, in a grouped form and on a card alike (a bare `LabeledContent`
    /// puts the amount right after the name outside a form).
    private func heading(@ViewBuilder amount: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            title
            Spacer(minLength: 8)
            amount()
        }
    }

    private func bar(limit: Double) -> some View {
        // Over the limit the bar is full and keeps the parts' proportions.
        let scale = max(limit, value, segments.map(\.value).reduce(0, +))
        let parts: [(Double, Color)] = segments.isEmpty
            ? [(min(value, limit) / scale, level.color ?? tint)]
            : segments.map { ($0.value / scale, $0.color) }
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                HStack(spacing: 0) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                        // A part too small to see still gets a sliver.
                        Rectangle().fill(part.1).frame(width: max(part.0 > 0 ? 2 : 0, geo.size.width * part.0))
                    }
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: barHeight)
        .accessibilityHidden(true)
    }

    private var legend: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { legendItems }
            VStack(alignment: .leading, spacing: 2) { legendItems }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var legendItems: some View {
        ForEach(segments) { segment in
            HStack(spacing: 5) {
                Circle().fill(segment.color).frame(width: 7, height: 7)
                Text(segment.label)
                Text(format(segment.value)).monospacedDigit()
            }
            .fixedSize()
        }
    }

    private var spokenValue: String {
        var parts: [String]
        if let limit, limit > 0 {
            parts = [String(localized: "\(format(value)) of \(format(limit))"),
                     (value / limit).formatted(.percent.precision(.fractionLength(0)))]
            switch level {
            case .warning: parts.append(String(localized: "Near the limit"))
            case .critical: parts.append(String(localized: "Limit reached"))
            default: break
            }
        } else {
            parts = [String(localized: "\(format(value)), no limit")]
        }
        parts += segments.map { "\($0.label) \(format($0.value))" }
        return parts.joined(separator: ", ")
    }
}

private let sampleSegments: [MeterRow.Segment] = [.init("Pods", value: 13.10, color: .green), .init("Venice", value: 3.25, color: .blue)]

#Preview("Meters", traits: .fixedLayout(width: 460, height: 420)) {
    Form {
        Section {
            MeterRow(String("Today"), value: 6.12, limit: 20)
            MeterRow(String("This month"), value: 128.40, limit: 150)
            MeterRow(String("Yesterday"), value: 21.80, limit: 20)
            MeterRow(String("Per week"), value: 42.00, limit: nil)
            MeterRow(String("Today, split"), value: 16.35, limit: 20, segments: sampleSegments)
        }
    }
    .formStyle(.grouped)
}

#Preview("Meters · dark", traits: .fixedLayout(width: 460, height: 300)) {
    Form {
        Section {
            MeterRow(String("Today"), value: 6.12, limit: 20, segments: sampleSegments.map { .init($0.label, value: $0.value / 3, color: $0.color) })
            MeterRow(String("This month"), value: 150, limit: 150)
            MeterRow(String("Per week"), value: 42.00, limit: nil, segments: sampleSegments)
        }
    }
    .formStyle(.grouped)
    .preferredColorScheme(.dark)
}
