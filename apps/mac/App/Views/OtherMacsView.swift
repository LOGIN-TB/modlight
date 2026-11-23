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
            Text("Models another Mac set up with the same RunPod key, checked every minute. Taking one over moves it to this Mac: from then on this Mac starts, stops and bills it, and the other Mac lets go. Only models whose pod exists (running, or stopped with its disk kept) are listed.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct OtherMacPodRow: View {
    @Environment(AppModel.self) private var model
    let pod: ForeignPod
    @State private var confirming = false

    private var owner: String {
        pod.owner.map { PodOwner.displayName(of: $0) } ?? String(localized: "an older Podlight version")
    }

    private var gpu: String {
        guard let id = pod.gpuId else { return "–" }
        let name = id.replacingOccurrences(of: "NVIDIA ", with: "").replacingOccurrences(of: "GeForce ", with: "")
        return pod.gpuCount > 1 ? "\(pod.gpuCount) × \(name)" : name
    }

    private var cost: String {
        if pod.isRunning, let price = pod.pricePerHour { return Format.perHour(price) }
        if let gb = pod.persistentGB, gb > 0 { return Format.keptDisk(gb: gb) }
        return String(localized: "nothing")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: pod.isRunning ? "lightbulb.fill" : "lightbulb")
                .foregroundStyle(pod.isRunning ? .green : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(pod.servedName)
                Text("\(pod.isRunning ? String(localized: "Running") : String(localized: "Stopped")) · \(gpu) · from \(owner)")
                    .font(.caption).foregroundStyle(.secondary)
                Text(cost).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.takingOver.contains(pod.id) {
                ProgressView().controlSize(.small)
            } else {
                Button("Take Over…") { confirming = true }
            }
        }
        .confirmationDialog("Take over \(pod.servedName)?", isPresented: $confirming) {
            Button("Take Over") { Task { await model.takeOver(pod) } }
        } message: {
            Text(pod.isRunning
                 ? "This Mac manages \(pod.servedName) from now on: it keeps the pod running, stops it when idle and counts its costs. \(owner) lets go within a minute; agents there are told to use this Mac."
                 : "This Mac manages \(pod.servedName) from now on, including its kept disk (\(cost)). \(owner) lets go the next time it checks.")
        }
    }
}
