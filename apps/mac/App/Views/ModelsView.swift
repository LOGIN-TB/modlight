import PodlightEngine
import SwiftUI

struct ModelRow: View {
    @Environment(AppModel.self) private var model
    let item: PodlightModel
    let run: ModelRun

    private var summary: String {
        let text = PhaseText.summary(run)
        if run.phase == .stopped, run.managedBy == nil, run.podId != nil, let gb = run.persistentGB, gb > 0 {
            return String(localized: "\(text) · disk \(Format.storagePerHour(StoragePricing.stoppedPerHour(volumeGB: gb)))")
        }
        guard run.phase == .ready, let gpu = UsageText.gpu(model.telemetry(item.id)) else { return text }
        return "\(text) · \(gpu)"
    }

    var body: some View {
        HStack(spacing: 8) {
            PhaseIcon(phase: run.phase)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1)
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
        if let other = run.managedBy { return String(localized: "Managed by \(PodOwner.displayName(of: other))") }
        if run.waitingForCard != nil { return String(localized: "Waiting for a card") }
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
    @State private var showingEngineLog = false

    private var run: ModelRun { model.run(item.id) }
    private var source: Source { model.source(of: item.id) }
    private var isIdle: Bool { run.phase == .stopped || run.phase == .failed }

    var body: some View {
        Form {
            if let other = run.managedBy {
                managedElsewhereSection(PodOwner.displayName(of: other))
            } else {
            Section {
                HStack(alignment: .center, spacing: 12) {
                    PhaseIcon(phase: run.phase).imageScale(.large)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(run.waitingForCard != nil ? String(localized: "Waiting for a Card") : PhaseText.title(run.phase))
                            .font(.title3.weight(.semibold))
                        if let detail = statusDetail {
                            Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.vertical, 4)
                ModelActions(item: item, run: run, prominent: true)
                if let waiting = run.waitingForCard {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Podlight tries every 30 seconds until \(Format.time(waiting.until)) and then resumes the pod with its disk, without downloading the model again.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Stop Waiting") { Task { await model.stop(item) } }
                    }
                }
                if ["host-busy", "gpu-unusable", "engine-stuck"].contains(run.lastReason ?? ""), run.phase == .stopped || run.phase == .failed, run.podId != nil {
                    HStack {
                        Button("Start on a New Card…") {
                            model.startingOnNewCard = true
                            model.startingModel = item
                        }
                        Text("Builds a new pod and downloads the model again. The old pod and its disk stay until the new one answers.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if run.phase == .loading || run.phase == .creating {
                    ProgressView {
                        Text(run.resumed == true
                             ? "Resuming takes about a minute."
                             : item.engine == .vllm
                                ? "A new pod can take 10–25 minutes: the GPU host first downloads the engine (about 9 GB), then the model. Resuming a stopped pod takes about a minute."
                                : "A new pod can take 5–20 minutes: the GPU host first downloads the engine (about 4 GB), then the model. Resuming a stopped pod takes about a minute.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .progressViewStyle(.linear)
                }
                if let error = model.actionError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                if run.phase == .failed, let lines = run.engineLog, !lines.isEmpty {
                    Button("Show Engine Log…") { showingEngineLog = true }
                        .sheet(isPresented: $showingEngineLog) { EngineLogSheet(name: item.name, lines: lines) }
                }
                if let fallback = run.fellBackFrom, !fallback.isEmpty, !isIdle {
                    Label("\(fallback.joined(separator: ", ")) was taken; Podlight used \(run.gpuName ?? "another card").",
                          systemImage: "arrow.triangle.branch")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            }

            if run.managedBy == nil, run.podStatus == .running, run.phase == .ready || run.phase == .loading {
                UsageSection(item: item, run: run)
            }

            Section("GPU and costs") {
                LabeledContent("GPU", value: run.gpuName ?? gpuLabel)
                if let price = run.pricePerHour ?? item.expectedPricePerHour {
                    LabeledContent("Price", value: Describe.price(gpu: price, storage: run.storagePerHour ?? PodPlan.storagePerHour(for: item)))
                }
                if case .server = source {
                    LabeledContent("Runs on", value: model.name(of: source))
                }
                LabeledContent("Where", value: Describe.hosting(item.hosting(default: model.defaultHosting(in: source))))
                if let end = run.runUntil, !isIdle {
                    LabeledContent("Runs until", value: Format.time(end))
                }
                if let center = run.dataCenterId, !isIdle {
                    LabeledContent("Data center", value: center)
                }
                LabeledContent("Stops when idle for", value: "\(item.schedule.idleStopMinutes) min")
                LabeledContent("Keep model on disk") {
                    if let gb = model.keptDiskGB(item) {
                        Text("On · \(Format.keptDisk(gb: gb)) while stopped")
                    } else {
                        Text("Off · nothing billed while stopped")
                    }
                }
            }

            Section("Model") {
                LabeledContent("Hugging Face", value: item.repoId)
                LabeledContent("Name for agents", value: item.name)
                    .textSelection(.enabled)
                LabeledContent("Weights", value: "\(Format.gigabytes(item.weightBytes)) · \(item.format.rawValue.uppercased())\(item.quant.map { " \($0)" } ?? "")")
                LabeledContent("Engine", value: item.engine == .vllm ? "vLLM" : "llama.cpp")
                LabeledContent("Context", value: String(localized: "\(Format.tokens(item.contextTokens)) tokens"))
                LabeledContent("Tool calls", value: item.toolCallParser != nil ? String(localized: "Supported") : String(localized: "Not supported by this model"))
            }

            Section {
                HStack {
                    Button("Edit…") { model.editingModel = item }.disabled(!isIdle || run.managedBy != nil)
                    Spacer()
                    Button("Delete Model…", role: .destructive) { confirmingDelete = true }
                }
            } footer: {
                Text(run.managedBy != nil
                     ? "Deleting removes the model from this Mac only. Its pod stays with the other Mac."
                     : isIdle ? "Deleting also deletes a kept disk at RunPod." : "Stop the model to edit it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(item.name)
        .toolbar { toolbar }
        .confirmationDialog("Delete \(item.name)?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { Task { await model.remove(item) } }
        } message: {
            Text(run.managedBy != nil
                 ? "The model is removed from this Mac. Its pod and disk at RunPod stay with the Mac that manages it."
                 : "The model's pod and its disk at RunPod are deleted too. This cannot be undone.")
        }
    }

    /// Another Mac took this model over: this Mac leaves the pod alone until it is taken back.
    @ViewBuilder private func managedElsewhereSection(_ mac: String) -> some View {
        Section {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "laptopcomputer.and.arrow.down").imageScale(.large).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Managed by \(mac)").font(.title3.weight(.semibold))
                    Text("That Mac took this model over. This Mac leaves its pod alone: it does not start, stop or bill it. Take it back to use the model here again.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
            ModelActions(item: item, run: run, prominent: true)
            if let error = model.actionError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
        }
    }

    private var gpuLabel: String {
        guard let gpu = item.preferredGPU else { return "–" }
        if let name = item.preferredGPUName { return name }
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
        if run.managedBy != nil {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await model.takeBack(item) } } label: { Label("Take Back", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(.glassProminent)
                    .help("Manage this model on this Mac again")
            }
        } else if run.phase == .loading || run.phase == .ready {
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

/// Start, or Stop and Extend, in the content: the toolbar's action is easy to miss on a first
/// visit, so the model's status says what to do next right where the user looks.
struct ModelActions: View {
    @Environment(AppModel.self) private var model
    let item: PodlightModel
    let run: ModelRun
    var prominent = false

    var body: some View {
        HStack(spacing: 10) {
            if run.managedBy != nil {
                Button { Task { await model.takeBack(item) } } label: { Label("Take Back", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(prominent ? .large : .regular)
            } else {
            switch run.phase {
            case .stopped, .failed:
                Button { model.startingModel = item } label: { Label("Start…", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(prominent ? .large : .regular)
                    .disabled(!model.canStart(item))
                if prominent {
                    Text("You choose how long it runs when you start it.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            case .loading, .ready:
                Button { Task { await model.stop(item) } } label: { Label("Stop", systemImage: "stop.fill") }
                    .controlSize(prominent ? .large : .regular)
                Menu {
                    Button("1 Hour") { Task { await model.extend(item, by: 3600) } }
                    Button("2 Hours") { Task { await model.extend(item, by: 7200) } }
                    Button("4 Hours") { Task { await model.extend(item, by: 4 * 3600) } }
                } label: {
                    Label("Extend", systemImage: "clock.arrow.circlepath")
                }
                .fixedSize()
                .controlSize(prominent ? .large : .regular)
                .disabled(run.runUntil == nil)
            case .creating, .stopping:
                ProgressView().controlSize(.small)
            }
            }
            Spacer(minLength: 0)
        }
    }
}

/// The engine's last lines from a failed start, to read the whole error or pass it on.
struct EngineLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    let name: String
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Engine log of \(name)").font(.title3.weight(.semibold))
            Text("The last lines the engine wrote before it stopped. The cause is usually near an error line, often above the final traceback.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(lines.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 320)
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 760, height: 520)
    }
}
