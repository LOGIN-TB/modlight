import PodlightEngine
import SwiftUI

/// The first thing the app shows: what is running and what it costs, what to do next, the
/// models with their main action, and how agents connect. Standard grouped form, no custom glass.
struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @State private var copied: String?

    private var spend: Spend { model.state.spend(on: .now) }

    var body: some View {
        Form {
            nowSection
            if !steps.allSatisfy(\.done) { nextSteps }
            spendingSection
            modelsSection
            ForEach(model.servers) { server in ServerOverviewSection(server: server) }
            connectSection
        }
        .formStyle(.grouped)
        .navigationTitle("Overview")
    }

    // MARK: Now

    @ViewBuilder private var nowSection: some View {
        Section("Now") {
            let active = model.allActiveRuns
            if active.isEmpty {
                Label("Nothing is running, so nothing is billed for GPUs.", systemImage: "moon.zzz")
                if let disks = keptDisksPerMonth {
                    LabeledContent("Kept disks", value: String(localized: "about \(Format.money(disks)) a month"))
                }
            } else {
                ForEach(active, id: \.1.id) { source, item, run in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            PhaseIcon(phase: run.phase)
                            Text(item.name).font(.headline)
                            if case .server = source {
                                Label(model.name(of: source), systemImage: "server.rack").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(PhaseText.summary(run)).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 16) {
                            if let price = run.pricePerHour { Text(Format.perHour(price)) }
                            if let started = run.startedAt, let price = run.pricePerHour {
                                Text("\(Format.money(GPUSuggestion.cost(pricePerHour: price, from: started, until: .now))) so far")
                            }
                            if let end = run.runUntil { Text("until \(Format.time(end))") }
                            if run.phase == .ready, let gpu = UsageText.gpu(model.telemetry(item.id)) { Text(gpu) }
                        }
                        .font(.callout).foregroundStyle(.secondary)
                        ModelActions(item: item, run: run)
                    }
                    .padding(.vertical, 2)
                }
                LabeledContent("Together", value: Format.perHour(model.totalCostPerHour))
            }
        }
    }

    private var keptDisksPerMonth: Double? {
        let all = model.state.models + model.servers.flatMap(\.models)
        let total = all.compactMap { model.keptDiskPerMonth($0) }.reduce(0, +)
        return total > 0 ? total : nil
    }

    // MARK: Next steps

    private struct Step: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let detail: LocalizedStringKey
        let done: Bool
        let optional: Bool
        let action: LocalizedStringKey
        let run: @MainActor () -> Void
    }

    private var steps: [Step] {
        let started = model.state.models.contains { model.state.run($0.id).startedAt != nil }
        return [
            Step(id: "runpod", title: "Connect RunPod", detail: "Podlight needs your RunPod API key to start pods.",
                 done: model.hasRunpodKey, optional: false, action: "Set Up…") { model.showingSetup = true },
            Step(id: "hf", title: "Add a Hugging Face token", detail: "Recommended: downloads are limited more strictly without one, and gated models need it.",
                 done: model.hasHuggingFaceToken, optional: true, action: "Open Settings") { model.selection = .settings },
            Step(id: "model", title: "Add a model", detail: "Choose one on Hugging Face; Podlight suggests a GPU and shows the price.",
                 done: !model.state.models.isEmpty, optional: false, action: "Add Model…") { model.addModel(to: .local) },
            Step(id: "start", title: "Start it once in Podlight", detail: "The first start takes 10–25 minutes, longer than an agent waits.",
                 done: started, optional: false, action: "Show Model") {
                     if let first = model.state.models.first { model.selection = .model(first.id) }
                 },
            Step(id: "agent", title: "Connect your agent", detail: "Enter the address, key and model name in your coding agent.",
                 done: model.state.lastClientRequestAt != nil, optional: false, action: "Show Connection") { model.selection = .connection },
        ]
    }

    private var nextSteps: some View {
        Section {
            ForEach(steps) { step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: step.done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(step.done ? Color.green : Color.secondary)
                        .accessibilityLabel(step.done ? Text("Done") : Text("To do"))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(step.title).strikethrough(step.done, color: .secondary)
                            if step.optional { Text("optional").font(.caption).foregroundStyle(.secondary) }
                        }
                        if !step.done { Text(step.detail).font(.callout).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if !step.done && isNext(step) {
                        Button(step.action) { step.run() }.buttonStyle(.borderedProminent)
                    } else if !step.done {
                        Button(step.action) { step.run() }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Next steps")
        }
    }

    /// The first open, required step gets the prominent button: one clear thing to do.
    private func isNext(_ step: Step) -> Bool {
        steps.first { !$0.done && !$0.optional }?.id == step.id
    }

    // MARK: Spending

    private var spendingSection: some View {
        Section {
            LimitRow(title: "Today", spent: spend.todayUsd, limit: spend.dailyLimitUsd)
            LimitRow(title: "This month", spent: spend.monthUsd, limit: spend.monthlyLimitUsd)
        } header: {
            HStack {
                Text(model.servers.isEmpty ? "Spending" : "Spending on this Mac")
                Spacer()
                Button("Costs") { model.selection = .costs }.buttonStyle(.link).font(.callout)
            }
        }
    }

    // MARK: Models

    @ViewBuilder private var modelsSection: some View {
        if !model.state.models.isEmpty {
            Section {
                ForEach(model.state.models) { item in
                    let run = model.state.run(item.id)
                    HStack {
                        Button { model.selection = .model(item.id) } label: {
                            ModelRow(item: item, run: run).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        if run.phase == .stopped || run.phase == .failed {
                            Button("Start…") { model.startingModel = item }.disabled(!model.hasRunpodKey)
                        } else if run.phase == .ready || run.phase == .loading {
                            Button("Stop") { Task { await model.stop(item) } }
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                Button { model.addModel(to: .local) } label: { Label("Add Model…", systemImage: "plus") }
                    .buttonStyle(.borderless)
                    .disabled(!model.hasRunpodKey)
            } header: {
                Text(model.servers.isEmpty ? "Models" : "Models on this Mac")
            }
        }
    }

    // MARK: Connect

    private var connectSection: some View {
        Section {
            GatewayStatusBadge()
            CopyRow(title: "Address", value: model.localBaseURL, copied: $copied)
            HStack {
                LabeledContent("API key") { Text(String(repeating: "•", count: 16)).font(.body.monospaced()) }
                Button(copied == "key" ? "Copied" : "Copy") { Pasteboard.copy(model.gatewayKey ?? ""); copied = "key" }
            }
        } header: {
            HStack {
                Text("Connect an agent")
                Spacer()
                Button("Connection") { model.selection = .connection }.buttonStyle(.link).font(.callout)
            }
        }
    }
}

/// One server on the overview: whether it answers, its spending against its limits, its models.
private struct ServerOverviewSection: View {
    @Environment(AppModel.self) private var model
    let server: ServerMirror

    var body: some View {
        Section {
            if server.status != .online { ServerStatusLine(server: server) }
            if let spend = server.snapshot?.spend {
                LimitRow(title: "Today", spent: spend.todayUsd, limit: spend.dailyLimitUsd)
                LimitRow(title: "This month", spent: spend.monthUsd, limit: spend.monthlyLimitUsd)
            }
            ForEach(server.models) { item in
                let run = server.run(item.id)
                HStack {
                    Button { model.selection = .model(item.id) } label: {
                        ModelRow(item: item, run: run).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    if run.phase == .stopped || run.phase == .failed {
                        Button("Start…") { model.startingModel = item }.disabled(!server.canStart)
                    } else if run.phase == .ready || run.phase == .loading {
                        Button("Stop") { Task { await model.stop(item) } }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            if server.models.isEmpty && server.status == .online {
                if server.snapshot?.settings.hasRunpodKey == false {
                    Button("Add the Server's RunPod Key…") { model.selection = .serverSettings(server.id) }
                } else {
                    Button { model.addModel(to: .server(server.id)) } label: { Label("Add Model…", systemImage: "plus") }
                        .buttonStyle(.borderless)
                }
            }
        } header: {
            HStack {
                Label(server.entry.name, systemImage: "server.rack")
                Spacer()
                Button("Connection") { model.selection = .serverConnection(server.id) }.buttonStyle(.link).font(.callout)
            }
        }
    }
}
