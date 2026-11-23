import PodlightEngine
import SwiftUI

/// Podlight pods in the RunPod account that another Mac manages, with "Take Over…".
struct OtherMacsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            ForEach(model.otherMacsPods) { pod in OtherMacPodRow(pod: pod) }
            if let error = model.otherMacsError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            } else if model.otherMacsPods.isEmpty {
                Text(model.otherMacsCheckedAt == nil
                     ? String(localized: "Looking in your RunPod account…")
                     : String(localized: "No models from other Macs right now. Checked at \(Format.time(model.otherMacsCheckedAt!))."))
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("From other Macs")
                Spacer()
                Button { Task { await model.refreshOtherMacsPods() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Look for other Macs' models again")
                    .accessibilityLabel(Text("Refresh"))
            }
        } footer: {
            Text("Models another Mac set up with the same RunPod key, running or stopped, checked every minute. Starting or taking one over moves it to this Mac: from then on this Mac starts, stops and bills it, and the other Mac lets go. Models of a Mac with Podlight before 0.7 appear only while they have a pod.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct OtherMacPodRow: View {
    @Environment(AppModel.self) private var model
    let pod: ForeignPod
    @State private var confirming: Action?

    enum Action: Identifiable { case start, takeOver; var id: Self { self } }

    private var owner: String {
        pod.owner.map { PodOwner.displayName(of: $0) } ?? String(localized: "an older Podlight version")
    }

    private var gpu: String {
        guard let id = pod.gpuId else { return "–" }
        let name = id.replacingOccurrences(of: "NVIDIA ", with: "").replacingOccurrences(of: "GeForce ", with: "")
        return pod.gpuCount > 1 ? "\(pod.gpuCount) × \(name)" : name
    }

    private var state: String {
        pod.isRunning ? String(localized: "Running") : String(localized: "Stopped")
    }

    private var cost: String {
        if pod.isRunning, let price = pod.pricePerHour { return Format.perHour(price) }
        if pod.hasPod, let gb = pod.persistentGB, gb > 0 { return String(localized: "Stopped: \(Format.keptDisk(gb: gb))") }
        return String(localized: "Stopped: nothing")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: pod.isRunning ? "lightbulb.fill" : "lightbulb")
                .foregroundStyle(pod.isRunning ? .green : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(pod.servedName)
                Text("\(state) · \(gpu) · from \(owner)")
                    .font(.caption).foregroundStyle(.secondary)
                Text(cost).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.takingOver.contains(pod.id) {
                ProgressView().controlSize(.small)
            } else if pod.isRunning {
                Button("Take Over…") { confirming = .takeOver }
            } else {
                Button("Take Over") { confirming = .takeOver }
                Button("Start…") { confirming = .start }.buttonStyle(.borderedProminent)
            }
        }
        .confirmationDialog(confirming == .start ? "Start \(pod.servedName) on this Mac?" : "Take over \(pod.servedName)?",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            presenting: confirming) { action in
            switch action {
            case .start: Button("Take Over and Start…") { Task { await model.takeOver(pod, thenStart: true) } }
            case .takeOver: Button("Take Over") { Task { await model.takeOver(pod) } }
            }
        } message: { _ in
            Text(pod.isRunning
                 ? "This Mac manages \(pod.servedName) from now on: it keeps the pod running, stops it when idle and counts its costs. \(owner) lets go within a minute; agents there are told to use this Mac."
                 : "The model moves to this Mac: from now on this Mac starts, stops and bills it, and your agents use it here. \(owner) lets go within a minute, or the next time it runs.")
        }
    }
}
