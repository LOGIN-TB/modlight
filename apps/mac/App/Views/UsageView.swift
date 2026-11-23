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
                engineRows(sample)
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

    @ViewBuilder private func rings(_ s: PodTelemetry) -> some View {
        let gpus = s.gpus ?? []
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 18) {
                ForEach(Array(gpus.enumerated()), id: \.offset) { offset, gpu in
                    let suffix = gpus.count > 1 ? " \(offset + 1)" : ""
                    UsageRing(title: String(localized: "GPU\(suffix)"), fraction: gpu.utilPercent.map { $0 / 100 })
                    UsageRing(title: String(localized: "VRAM\(suffix)"),
                              fraction: fraction(gpu.memoryUsedBytes, gpu.memoryTotalBytes),
                              detail: amount(gpu.memoryUsedBytes, gpu.memoryTotalBytes))
                }
                UsageRing(title: String(localized: "CPU"), fraction: s.cpuPercent.map { $0 / 100 })
                UsageRing(title: String(localized: "RAM"), fraction: fraction(s.memoryUsedBytes, s.memoryTotalBytes),
                          detail: amount(s.memoryUsedBytes, s.memoryTotalBytes))
                UsageRing(title: String(localized: "Disk"), fraction: fraction(s.diskUsedBytes, s.diskTotalBytes),
                          detail: amount(s.diskUsedBytes, s.diskTotalBytes))
                if s.volumeTotalBytes != nil {
                    UsageRing(title: String(localized: "Volume"), fraction: fraction(s.volumeUsedBytes, s.volumeTotalBytes),
                              detail: amount(s.volumeUsedBytes, s.volumeTotalBytes))
                }
            }
            .padding(.vertical, 4)
        }
        ForEach(Array(gpus.enumerated()), id: \.offset) { offset, gpu in
            if let line = Self.gpuLine(gpu) {
                LabeledContent(gpus.count > 1 ? String(localized: "Temperature and power, card \(offset + 1)") : String(localized: "Temperature and power"), value: line)
            }
        }
    }

    @ViewBuilder private func engineRows(_ s: PodTelemetry) -> some View {
        if let engine = s.engine {
            if engine.running != nil || engine.waiting != nil {
                LabeledContent("Requests", value: String(localized: "\(engine.running ?? 0) running · \(engine.waiting ?? 0) waiting"))
            }
            if let output = engine.generationTokensPerSecond {
                LabeledContent("Output", value: String(localized: "\(Self.rate(output)) tokens/s"))
            }
            if let prompt = engine.promptTokensPerSecond {
                LabeledContent("Prompt processing", value: String(localized: "\(Self.rate(prompt)) tokens/s"))
            }
            if let kv = engine.kvCachePercent {
                LabeledContent("Context cache in use", value: (kv / 100).formatted(.percent.precision(.fractionLength(0))))
            }
        } else if run.phase == .ready {
            LabeledContent("Engine", value: String(localized: "No figures from the engine"))
        }
    }

    private func fraction(_ used: Double?, _ total: Double?) -> Double? {
        guard let used, let total, total > 0 else { return nil }
        return used / total
    }

    private func amount(_ used: Double?, _ total: Double?) -> String? {
        guard let used, let total else { return nil }
        return "\(Self.number(used / 1e9)) / \(Format.gigabytes(total))"
    }

    static func number(_ gb: Double) -> String { gb.formatted(.number.precision(.fractionLength(1))) }
    static func rate(_ value: Double) -> String { Int(value.rounded()).formatted() }

    /// "55 °C · 250 of 300 W"
    static func gpuLine(_ gpu: PodTelemetry.GPU) -> String? {
        var parts: [String] = []
        if let t = gpu.temperatureC { parts.append("\(Int(t.rounded())) °C") }
        if let w = gpu.powerW {
            parts.append(gpu.powerLimitW.map { String(localized: "\(Int(w.rounded())) of \(Int($0.rounded())) W") } ?? "\(Int(w.rounded())) W")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// One figure as a ring, the way RunPod's console shows it: percent inside, name and amount below.
struct UsageRing: View {
    let title: String
    let fraction: Double?
    var detail: String? = nil

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 6)
                if let fraction {
                    Circle()
                        .trim(from: 0, to: min(1, max(0, fraction)))
                        .stroke(.tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Text(fraction.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "–")
                    .font(.callout.monospacedDigit().weight(.medium))
            }
            .frame(width: 58, height: 58)
            Text(title).font(.caption.weight(.medium))
            Text(detail ?? " ").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
        .frame(minWidth: 72)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text([fraction.map { $0.formatted(.percent.precision(.fractionLength(0))) }, detail]
            .compactMap { $0 }.joined(separator: ", ")))
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
