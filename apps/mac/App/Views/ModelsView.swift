import PodlightEngine
import SwiftUI

struct ModelRow: View {
    let item: PodlightModel
    let run: ModelRun

    var body: some View {
        HStack(spacing: 8) {
            PhaseIcon(phase: run.phase)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1)
                Text(PhaseText.summary(run)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Phase as symbol and colour; the text beside it always says the same, so colour is never the
/// only signal.
struct PhaseIcon: View {
    let phase: RunPhase

    var body: some View {
        Group {
            switch phase {
            case .ready: Image(systemName: "lightbulb.max.fill").foregroundStyle(.green)
            case .loading, .creating: Image(systemName: "hourglass").foregroundStyle(.orange)
            case .stopping: Image(systemName: "stop.circle").foregroundStyle(.secondary)
            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            case .stopped: Image(systemName: "lightbulb").foregroundStyle(.secondary)
            }
        }
        .frame(width: 20)
        .accessibilityHidden(true)
    }
}

enum PhaseText {
    static func title(_ phase: RunPhase) -> String {
        switch phase {
        case .stopped: String(localized: "Stopped")
        case .creating: String(localized: "Finding a GPU")
        case .loading: String(localized: "Loading the model")
        case .ready: String(localized: "Running")
        case .stopping: String(localized: "Stopping")
        case .failed: String(localized: "Could not start")
        }
    }

    static func summary(_ run: ModelRun) -> String {
        switch run.phase {
        case .ready:
            if let end = run.runUntil { return String(localized: "Running · \(Format.remaining(until: end)) left") }
            return String(localized: "Running · stops when idle")
        case .loading, .creating, .stopping, .failed: return title(run.phase)
        case .stopped: return String(localized: "Stopped")
        }
    }
}

/// One model: its state, what it costs, what it is, and the actions for it in the toolbar.
struct ModelDetailView: View {
    @Environment(AppModel.self) private var model
    let item: PodlightModel
    @State private var confirmingDelete = false

    private var run: ModelRun { model.state.run(item.id) }
    private var isIdle: Bool { run.phase == .stopped || run.phase == .failed }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 12) {
                    PhaseIcon(phase: run.phase).imageScale(.large)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(PhaseText.title(run.phase)).font(.title3.weight(.semibold))
                        if let detail = statusDetail {
                            Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.vertical, 4)
                if run.phase == .loading || run.phase == .creating {
                    ProgressView {
                        Text(item.keepDisk && run.persistentGB != nil
                             ? "Resuming takes about a minute."
                             : "A new pod can take 10–25 minutes: the GPU host first downloads the engine (about 9 GB), then the model. Resuming a stopped pod takes about a minute.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .progressViewStyle(.linear)
                }
                if let error = model.actionError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                if let fallback = run.fellBackFrom, !fallback.isEmpty, !isIdle {
                    Label("\(fallback.joined(separator: ", ")) was taken; Podlight used \(run.gpuName ?? "another card").",
                          systemImage: "arrow.triangle.branch")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("GPU and costs") {
                LabeledContent("GPU", value: run.gpuName ?? gpuLabel)
                if let price = run.pricePerHour ?? item.expectedPricePerHour {
                    LabeledContent("Price", value: Format.perHour(price + (run.storagePerHour ?? PodPlan.storagePerHour(for: item))))
                }
                if let end = run.runUntil, !isIdle {
                    LabeledContent("Runs until", value: Format.time(end))
                }
                if let center = run.dataCenterId, !isIdle {
                    LabeledContent("Data center", value: center)
                }
                LabeledContent("Stops when idle for", value: "\(item.schedule.idleStopMinutes) min")
                LabeledContent("Keep model on disk") {
                    if let monthly = model.keptDiskPerMonth(item) {
                        Text("On · about \(Format.money(monthly)) a month while stopped")
                    } else {
                        Text("Off · nothing billed while stopped")
                    }
                }
            }

            Section("Model") {
                LabeledContent("Hugging Face", value: item.repoId)
                LabeledContent("Name for agents", value: item.name)
                    .textSelection(.enabled)
                LabeledContent("Weights", value: "\(Format.gigabytes(item.weightBytes)) · \(item.format.rawValue.uppercased())")
                LabeledContent("Context", value: String(localized: "\(Format.tokens(item.contextTokens)) tokens"))
                LabeledContent("Tool calls", value: item.toolCallParser != nil ? String(localized: "Supported") : String(localized: "Not supported by this model"))
            }

            Section {
                HStack {
                    Button("Edit…") { model.editingModel = item }.disabled(!isIdle)
                    Spacer()
                    Button("Delete Model…", role: .destructive) { confirmingDelete = true }
                }
            } footer: {
                Text(isIdle ? "Deleting also deletes a kept disk at RunPod." : "Stop the model to edit it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(item.name)
        .toolbar { toolbar }
        .confirmationDialog("Delete \(item.name)?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { Task { await model.remove(item) } }
        } message: {
            Text("The model's pod and its disk at RunPod are deleted too. This cannot be undone.")
        }
    }

    private var gpuLabel: String {
        guard let gpu = item.preferredGPU else { return "–" }
        let name = gpu.gpuId.replacingOccurrences(of: "NVIDIA ", with: "").replacingOccurrences(of: "GeForce ", with: "")
        return gpu.count > 1 ? "\(gpu.count) × \(name)" : name
    }

    private var statusDetail: String? {
        switch run.phase {
        case .ready:
            var parts: [String] = []
            if let end = run.runUntil { parts.append(String(localized: "\(Format.remaining(until: end)) left")) }
            if let price = run.pricePerHour { parts.append(Format.perHour(price)) }
            return parts.joined(separator: " · ")
        case .stopped, .failed:
            if run.phase == .failed, let message = run.lastMessage { return "\(Describe.reason(run.lastReason) ?? "") \(message)" }
            return Describe.reason(run.lastReason)
        default:
            return run.gpuName
        }
    }

    /// One prominent action at the trailing end, as the HIG asks: Start, or Stop while running.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if run.phase == .loading || run.phase == .ready {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("1 Hour") { Task { await model.extend(item, by: 3600) } }
                    Button("2 Hours") { Task { await model.extend(item, by: 7200) } }
                    Button("4 Hours") { Task { await model.extend(item, by: 4 * 3600) } }
                } label: {
                    Label("Extend", systemImage: "clock.arrow.circlepath")
                }
                .disabled(run.runUntil == nil)
                .help("Run longer before it stops")
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await model.stop(item) } } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(.glassProminent)
                    .help("Stop now")
            }
        } else if run.phase == .creating || run.phase == .stopping {
            ToolbarItem(placement: .primaryAction) { ProgressView().controlSize(.small) }
        } else {
            ToolbarItem(placement: .primaryAction) {
                Button { model.startingModel = item } label: { Label("Start…", systemImage: "play.fill") }
                    .buttonStyle(.glassProminent)
                    .help("Start this model for a set time")
            }
        }
    }
}
