import Charts
import PodlightEngine
import SwiftUI

/// What a running pod is doing: GPU, memory, disk and the engine's own figures, as its watchdog
/// measures them every few seconds, and the last 30 minutes as a chart. RunPod's API reports no GPU
/// memory in use, so these come from inside the pod.
struct UsageSection: View {
    @Environment(AppModel.self) private var model
    let item: PodlightModel
    let run: ModelRun
    @State private var history: [PodTelemetry] = []

    private var sample: PodTelemetry? { model.telemetry(item.id) }

    var body: some View {
        Section {
            if let sample {
                rings(sample)
                figures(sample)
                if history.count >= 2 { UsageChart(samples: history) }
            } else {
                Text(waitingText).foregroundStyle(.secondary)
            }
        } header: {
            Text("Usage")
        } footer: {
            if let sample {
                Text("Measured inside the pod \(sample.date, format: .relative(presentation: .named)). Updated about every 10 seconds.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: item.id) {
            // Only while this view is visible: the history is a separate request for a server.
            while !Task.isCancelled {
                history = await model.telemetryHistory(item.id)
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    /// Before the first sample: still starting, or a pod whose watchdog predates telemetry.
    private var waitingText: String {
        if run.phase == .ready, run.lastHeartbeatAt != nil {
            return String(localized: "This pod was created by an earlier Podlight version and reports no usage. It will after the model is started on a new pod.")
        }
        return String(localized: "Usage appears once the pod answers.")
    }

    /// The card first, then the pod. Spread over the whole width; they wrap onto a second row
    /// when the window is narrow or the pod has several cards.
    @ViewBuilder private func rings(_ s: PodTelemetry) -> some View {
        let all = Self.rings(s)
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(all) { ring in UsageRing(ring: ring).frame(maxWidth: .infinity) }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 14) {
                ForEach(all) { ring in UsageRing(ring: ring) }
            }
        }
        .padding(.vertical, 6)
    }

    static func rings(_ s: PodTelemetry) -> [UsageRing.Figure] {
        let gpus = s.gpus ?? []
        var out: [UsageRing.Figure] = []
        for (offset, gpu) in gpus.enumerated() {
            let suffix = gpus.count > 1 ? " \(offset + 1)" : ""
            out.append(.init(id: "gpu\(offset)", title: String(localized: "GPU\(suffix)"), fraction: gpu.utilPercent.map { $0 / 100 }))
            // A full card memory is normal (vLLM takes it all on purpose), so it never warns.
            out.append(.init(id: "vram\(offset)", title: String(localized: "VRAM\(suffix)"),
                             fraction: fraction(gpu.memoryUsedBytes, gpu.memoryTotalBytes),
                             detail: amount(gpu.memoryUsedBytes, gpu.memoryTotalBytes)))
        }
        out.append(.init(id: "cpu", title: String(localized: "CPU"), fraction: s.cpuPercent.map { $0 / 100 }))
        out.append(.init(id: "ram", title: String(localized: "RAM"), fraction: fraction(s.memoryUsedBytes, s.memoryTotalBytes),
                         detail: amount(s.memoryUsedBytes, s.memoryTotalBytes), warns: true))
        out.append(.init(id: "disk", title: String(localized: "Disk"), fraction: fraction(s.diskUsedBytes, s.diskTotalBytes),
                         detail: amount(s.diskUsedBytes, s.diskTotalBytes), warns: true))
        if s.volumeTotalBytes != nil {
            out.append(.init(id: "volume", title: String(localized: "Volume"), fraction: fraction(s.volumeUsedBytes, s.volumeTotalBytes),
                             detail: amount(s.volumeUsedBytes, s.volumeTotalBytes), warns: true))
        }
        return out
    }

    /// What the engine and the card report, as tiles: speeds of the requests themselves (not the
    /// rate of the last few seconds, which is 0 between requests), the cache, the load, the totals.
    @ViewBuilder private func figures(_ s: PodTelemetry) -> some View {
        let tiles = Self.tiles(s)
        if !tiles.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                ForEach(tiles) { FigureTile(tile: $0) }
            }
            .padding(.vertical, 4)
        } else if run.phase == .ready {
            LabeledContent("Engine", value: String(localized: "No figures from the engine"))
        }
    }

    static func tiles(_ s: PodTelemetry) -> [FigureTile.Tile] {
        var out: [FigureTile.Tile] = []
        let engine = s.engine
        if let speed = engine?.generationSpeed ?? engine?.generationTokensPerSecond.flatMap({ $0 > 0 ? $0 : nil }) {
            out.append(.init(id: "writing", symbol: "text.cursor", title: String(localized: "Writing"),
                             value: String(localized: "\(rate(speed)) tokens/s"), detail: String(localized: "while it answers")))
        }
        if let speed = engine?.promptSpeed ?? engine?.promptTokensPerSecond.flatMap({ $0 > 0 ? $0 : nil }) {
            out.append(.init(id: "reading", symbol: "doc.text.magnifyingglass", title: String(localized: "Reading"),
                             value: String(localized: "\(rate(speed)) tokens/s"), detail: String(localized: "while it reads the prompt")))
        }
        if let hit = engine?.promptCacheHitPercent {
            out.append(.init(id: "cache", symbol: "arrow.triangle.2.circlepath", title: String(localized: "Prompt cache"),
                             value: (hit / 100).formatted(.percent.precision(.fractionLength(0))),
                             detail: String(localized: "of prompt tokens reused")))
        }
        if let running = engine?.running {
            out.append(.init(id: "requests", symbol: "arrow.left.arrow.right", title: String(localized: "Requests"),
                             value: String(localized: "\(running) running"), detail: String(localized: "\(engine?.waiting ?? 0) waiting")))
        }
        if let kv = engine?.kvCachePercent {
            out.append(.init(id: "kv", symbol: "memorychip", title: String(localized: "Context cache"),
                             value: (kv / 100).formatted(.percent.precision(.fractionLength(0))), detail: String(localized: "in use")))
        }
        if let read = engine?.promptTokensTotal, let written = engine?.generationTokensTotal {
            out.append(.init(id: "totals", symbol: "sum", title: String(localized: "Since the start"),
                             value: String(localized: "\(compact(read)) read"), detail: String(localized: "\(compact(written)) written")))
        }
        for (offset, gpu) in (s.gpus ?? []).enumerated() {
            guard let t = gpu.temperatureC else { continue }
            let suffix = (s.gpus?.count ?? 0) > 1 ? " \(offset + 1)" : ""
            out.append(.init(id: "card\(offset)", symbol: "thermometer.medium", title: String(localized: "Card\(suffix)"),
                             value: "\(Int(t.rounded())) °C", detail: power(gpu)))
        }
        return out
    }

    private static func power(_ gpu: PodTelemetry.GPU) -> String? {
        guard let w = gpu.powerW else { return nil }
        return gpu.powerLimitW.map { String(localized: "\(Int(w.rounded())) of \(Int($0.rounded())) W") } ?? "\(Int(w.rounded())) W"
    }

    /// "842k", "1.2M": short in every language (German compact names would spell out "Tsd.").
    static func compact(_ value: Int) -> String {
        switch value {
        case ..<1_000: return value.formatted()
        case ..<1_000_000: return "\(Int((Double(value) / 1_000).rounded()))k"
        default: return "\((Double(value) / 1_000_000).formatted(.number.precision(.fractionLength(1))))M"
        }
    }

    private static func fraction(_ used: Double?, _ total: Double?) -> Double? {
        guard let used, let total, total > 0 else { return nil }
        return used / total
    }

    private static func amount(_ used: Double?, _ total: Double?) -> String? {
        guard let used, let total else { return nil }
        return "\(Self.number(used / 1e9)) / \(Format.gigabytes(total))"
    }

    static func number(_ gb: Double) -> String { gb.formatted(.number.precision(.fractionLength(1))) }
    static func rate(_ value: Double) -> String { Int(value.rounded()).formatted() }

}

/// One figure as a ring, the way RunPod's console shows it: percent inside, name and amount below.
/// Memory and disks that run full turn orange, then red; the percent inside says the same, so
/// colour is never the only signal.
struct UsageRing: View {
    struct Figure: Identifiable {
        let id: String
        let title: String
        let fraction: Double?
        var detail: String? = nil
        var warns = false
    }

    let ring: Figure

    private var color: Color {
        guard ring.warns, let f = ring.fraction else { return .accentColor }
        return f >= 0.95 ? .red : f >= 0.85 ? .orange : .accentColor
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 6)
                if let fraction = ring.fraction {
                    Circle()
                        .trim(from: 0, to: min(1, max(0, fraction)))
                        .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Text(ring.fraction.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "–")
                    .font(.callout.monospacedDigit().weight(.medium))
            }
            .frame(width: 58, height: 58)
            Text(ring.title).font(.caption.weight(.medium))
            Text(ring.detail ?? " ").font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(minWidth: 76)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(ring.title))
        .accessibilityValue(Text([ring.fraction.map { $0.formatted(.percent.precision(.fractionLength(0))) }, ring.detail]
            .compactMap { $0 }.joined(separator: ", ")))
    }
}

/// One figure as a small tile: what it is, the value, and what the value means.
struct FigureTile: View {
    struct Tile: Identifiable {
        let id: String
        let symbol: String
        let title: String
        let value: String
        let detail: String?
    }

    let tile: Tile

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(tile.title, systemImage: tile.symbol)
                .font(.caption).foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            Text(tile.value)
                .font(.title3.monospacedDigit().weight(.semibold))
                .lineLimit(1).minimumScaleFactor(0.8)
            if let detail = tile.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(tile.title))
        .accessibilityValue(Text([tile.value, tile.detail].compactMap { $0 }.joined(separator: ", ")))
    }
}

/// GPU load and output tokens per second over the last 30 minutes.
struct UsageChart: View {
    let samples: [PodTelemetry]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            chart(title: String(localized: "GPU load"), unit: "%",
                  points: samples.compactMap { s in s.averageGPUPercent.map { (s.date, $0) } }, maximum: 100)
            let tokens = samples.compactMap { s in s.engine?.generationTokensPerSecond.map { (s.date, $0) } }
            if tokens.contains(where: { $0.1 > 0 }) {
                chart(title: String(localized: "Output tokens/s"), unit: "", points: tokens, maximum: nil)
            }
        }
        .padding(.vertical, 4)
    }

    private func chart(title: String, unit: String, points: [(Date, Double)], maximum: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Chart(points, id: \.0) { point in
                AreaMark(x: .value("Time", point.0), y: .value(title, point.1))
                    .foregroundStyle(.tint.opacity(0.15))
                LineMark(x: .value("Time", point.0), y: .value(title, point.1))
                    .foregroundStyle(.tint)
            }
            .chartYScale(domain: 0...(maximum ?? max(1, (points.map(\.1).max() ?? 1) * 1.1)))
            .chartXAxis { AxisMarks(values: .stride(by: .minute, count: 10)) { AxisValueLabel(format: .dateTime.hour().minute()); AxisGridLine() } }
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { AxisValueLabel(); AxisGridLine() } }
            .frame(height: 90)
            .accessibilityLabel(Text("\(title), last 30 minutes"))
            .accessibilityValue(Text(verbatim: points.last.map { "\(Int($0.1.rounded()))\(unit)" } ?? ""))
        }
    }
}

/// "GPU 87 %": the compact figure beside a running model in lists and the menu bar.
enum UsageText {
    static func gpu(_ sample: PodTelemetry?) -> String? {
        guard let percent = sample?.averageGPUPercent else { return nil }
        return String(localized: "GPU \((percent / 100).formatted(.percent.precision(.fractionLength(0))))")
    }
}
