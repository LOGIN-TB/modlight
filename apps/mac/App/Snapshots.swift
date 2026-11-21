import AppKit
import PodlightEngine
import SwiftUI

/// Renders the main screens with sample data into PNG files, then quits:
///   Podlight.app/Contents/MacOS/Podlight -PodlightSnapshots /path/to/dir [-AppleLanguages "(de)"]
/// Used for the help pages and to check the interface without screen-recording permission.
/// Touches no real state: a throwaway store and keychain service, removed afterwards.
@MainActor
enum Snapshots {
    static var requestedDirectory: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-PodlightSnapshots"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }

    static func run(into folder: URL) async {
        let service = "io.github.login-tb.podlight.snapshots"
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("podlight-snapshot-\(UUID()).json")
        let keychain = KeychainStore(service: service)
        try? keychain.write("rp-sample", for: .runpodAPIKey)
        try? keychain.write("pl-SampleKeyForScreenshotsOnly", for: .gatewayKey)
        defer {
            for item in [KeychainStore.Item.runpodAPIKey, .gatewayKey] { try? keychain.delete(item) }
            try? FileManager.default.removeItem(at: storeURL)
        }

        let store = StateStore(url: storeURL)
        let sample = sampleState()
        _ = try? await store.update { $0 = sample }
        let model = AppModel(storeURL: storeURL, keychainService: service)
        await model.reloadState()
        model.selection = model.state.models.first.map { .model($0.id) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let running = model.state.models[0]
        // Content views without the sidebar: its material does not render offscreen, and the help
        // pages are about the content anyway.
        render("overview", size: CGSize(width: 720, height: 900), into: folder) { NavigationStack { OverviewView() }.environment(model) }
        render("model-stopped", size: CGSize(width: 720, height: 640), into: folder) {
            NavigationStack { ModelDetailView(item: model.state.models[1]) }.environment(model)
        }
        render("models", size: CGSize(width: 720, height: 640), into: folder) { NavigationStack { ModelDetailView(item: running) }.environment(model) }
        render("connection", size: CGSize(width: 720, height: 860), into: folder) { ConnectionView().environment(model) }
        render("connection-claude", size: CGSize(width: 720, height: 1100), into: folder) {
            ConnectionView(agent: .claudeCode, showFiles: true).environment(model)
        }
        render("connection-codex", size: CGSize(width: 720, height: 1100), into: folder) {
            ConnectionView(agent: .codex, showFiles: true).environment(model)
        }
        render("costs", size: CGSize(width: 720, height: 760), into: folder) { CostsView().environment(model) }
        render("start", size: CGSize(width: 460, height: 520), into: folder) { StartSheet(model: running).environment(model) }
        render("setup-key", size: CGSize(width: 600, height: 520), into: folder) {
            RunpodKeyStep(onDone: {}).environment(model).padding(24).frame(width: 600, height: 520)
        }
        render("menubar", size: CGSize(width: 300, height: 240), into: folder) { MenuBarView().environment(model) }
        render("settings", size: CGSize(width: 640, height: 900), into: folder) { SettingsContent().environment(model) }
        render("add-model", size: CGSize(width: 760, height: 600), into: folder) { AddModelSheet(editing: running).environment(model) }
        render("move", size: CGSize(width: 460, height: 360), into: folder) { MoveToApplicationsView() }
    }

    private static func render<V: View>(_ name: String, size: CGSize, into folder: URL, @ViewBuilder _ view: () -> V) {
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: view().frame(width: size.width, height: size.height))
        window.contentView = host
        window.orderFrontRegardless()
        // Lists, tables and forms fill in over a few run-loop passes.
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name).png"))
        window.orderOut(nil)
    }

    nonisolated static func sampleState() -> PodlightState {
        var state = PodlightState()
        let coder = PodlightModel(name: "qwen3-coder-30b", repoId: "Qwen/Qwen3-Coder-30B-A3B-Instruct-AWQ", format: .awq,
                                  weightBytes: 17.4e9, nativeContextTokens: 262_144, toolCallParser: "qwen3_xml",
                                  reasoningParser: nil, contextTokens: 65_536,
                                  preferredGPU: GPUChoice(gpuId: "NVIDIA L40S", cloud: .secure))
        var small = PodlightModel(name: "qwen3-8b", repoId: "Qwen/Qwen3-8B-AWQ", format: .awq, weightBytes: 6.1e9,
                                  nativeContextTokens: 131_072, toolCallParser: "hermes", reasoningParser: "qwen3",
                                  contextTokens: 32_768, preferredGPU: GPUChoice(gpuId: "NVIDIA GeForce RTX 4090", cloud: .community))
        small.expectedPricePerHour = 0.34
        state.models = [coder, small]
        var run = ModelRun()
        run.podId = "sample"
        run.gpuName = "L40S"
        run.pricePerHour = 0.86
        run.podStatus = .running
        run.phase = .ready
        run.engineReady = true
        run.startedAt = Date().addingTimeInterval(-38 * 60)
        run.runUntil = Date().addingTimeInterval(102 * 60)
        run.lastRequestAt = Date().addingTimeInterval(-40)
        state.runs[coder.id] = run
        var stopped = ModelRun()
        stopped.phase = .stopped
        stopped.lastReason = "idle-timeout"
        state.runs[small.id] = stopped
        let calendar = Calendar.current
        for offset in 0..<30 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: .now) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            let amount = weekday == 1 || weekday == 7 ? 0 : [1.2, 2.6, 0.9, 3.4, 1.8][offset % 5]
            state.spendByDay[PodlightState.dayKey(day)] = amount
        }
        return state
    }
}
