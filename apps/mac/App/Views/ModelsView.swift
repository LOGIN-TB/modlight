import PodlightEngine
import SwiftUI

/// The models the user has set up, and the selected one's state and controls.
struct ModelsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        if !model.hasRunpodKey {
            ContentUnavailableView {
                Label("Connect Podlight to RunPod", systemImage: "key")
            } description: {
                Text("Podlight needs your RunPod API key to start pods. It takes about a minute.")
            } actions: {
                Button("Set Up…") { model.showingSetup = true }.buttonStyle(.borderedProminent)
            }
        } else if model.state.models.isEmpty {
            ContentUnavailableView {
                Label("No Models Yet", systemImage: "cpu")
            } description: {
                Text("Choose a model from Hugging Face. Podlight suggests a GPU and shows what it costs.")
            } actions: {
                Button("Add Model…") { model.showingAddModel = true }.buttonStyle(.borderedProminent)
            }
        } else {
            HSplitView {
                List(selection: $model.selectedModelID) {
                    ForEach(model.state.models) { item in
                        ModelRow(item: item, run: model.state.run(item.id)).tag(item.id)
                    }
                }
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
                Group {
                    if let selected = model.state.models.first(where: { $0.id == model.selectedModelID }) {
                        ModelDetailView(item: selected)
                    } else {
                        ContentUnavailableView("Select a Model", systemImage: "cpu")
                    }
                }
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
            .toolbar {
                ToolbarItem {
                    Button { model.showingAddModel = true } label: { Label("Add Model", systemImage: "plus") }
                        .help("Add a model from Hugging Face")
                }
            }
            .onAppear {
                if model.selectedModelID == nil { model.selectedModelID = model.state.models.first?.id }
            }
        }
    }
}

struct ModelRow: View {
    let item: PodlightModel
    let run: ModelRun

    var body: some View {
        HStack(spacing: 10) {
            PhaseIcon(phase: run.phase)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.body.weight(.medium))
                Text(PhaseText.summary(run)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
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
        .imageScale(.large)
        .frame(width: 22)
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

struct ModelDetailView: View {
    @Environment(AppModel.self) private var model
    let item: PodlightModel
    @State private var confirmingDelete = false

    private var run: ModelRun { model.state.run(item.id) }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 12) {
                    PhaseIcon(phase: run.phase).imageScale(.large)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(PhaseText.title(run.phase)).font(.title3.weight(.semibold))
                        if let detail = statusDetail { Text(detail).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 8)
                    controls
                        .fixedSize()
                        .layoutPriority(1)
                }
                .padding(.vertical, 4)
                if run.phase == .loading || run.phase == .creating {
                    ProgressView {
                        Text("The first start downloads the model. Expect 3–10 minutes; later starts are faster.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .progressViewStyle(.linear)
                }
                if let error = model.actionError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                if let fallback = run.fellBackFrom, !fallback.isEmpty, run.phase != .stopped {
                    Label("\(fallback.joined(separator: ", ")) was taken; Podlight used \(run.gpuName ?? "another card").",
                          systemImage: "arrow.triangle.branch")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("This run") {
                LabeledContent("GPU", value: run.gpuName ?? item.preferredGPU?.gpuId.replacingOccurrences(of: "NVIDIA ", with: "") ?? "–")
                if let price = run.pricePerHour { LabeledContent("Price", value: Format.perHour(price)) }
                if let end = run.runUntil, run.phase != .stopped {
                    LabeledContent("Runs until", value: Format.time(end))
                }
                LabeledContent("Stops when idle for", value: "\(item.schedule.idleStopMinutes) min")
                if let start = run.startedAt, run.phase != .stopped {
                    LabeledContent("Running since", value: Format.time(start))
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
                Button("Delete Model…", role: .destructive) { confirmingDelete = true }
            } footer: {
                Text("Deleting also deletes its pod and disk at RunPod.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(item.name)
        .confirmationDialog("Delete \(item.name)?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { Task { await model.remove(item) } }
        } message: {
            Text("The model's pod and its disk at RunPod are deleted too. This cannot be undone.")
        }
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

    @ViewBuilder private var controls: some View {
        switch run.phase {
        case .stopped, .failed:
            Button("Start…") { model.startingModel = item }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("r")
        case .creating, .stopping:
            ProgressView().controlSize(.small)
        case .loading, .ready:
            HStack {
                Menu("Extend") {
                    Button("1 Hour") { Task { await model.extend(item, by: 3600) } }
                    Button("2 Hours") { Task { await model.extend(item, by: 7200) } }
                    Button("4 Hours") { Task { await model.extend(item, by: 4 * 3600) } }
                }
                .fixedSize()
                .disabled(run.runUntil == nil)
                Button("Stop") { Task { await model.stop(item) } }
            }
        }
    }
}
