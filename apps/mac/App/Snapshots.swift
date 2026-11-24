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
        model.sampleTelemetry = [running.id: sampleTelemetry(gpu: "NVIDIA L40S", memoryGB: 48)]
        model.showOtherMacsPodsForSnapshots(sampleOtherMacsPods())
        model.showBalanceForSnapshots(RunpodBalance(usd: 37.8, spendPerHourUsd: 1.21, spendLimitUsd: 80, checkedAt: .now))
        // Content views without the sidebar: its material does not render offscreen, and the help
        // pages are about the content anyway.
        render("overview", size: CGSize(width: 720, height: 900), into: folder) { NavigationStack { OverviewView() }.environment(model) }
        render("model-stopped", size: CGSize(width: 720, height: 640), into: folder) {
            NavigationStack { ModelDetailView(item: model.state.models[1]) }.environment(model)
        }
        render("other-macs", size: CGSize(width: 720, height: 560), into: folder) {
            Form { OtherMacsSection() }.formStyle(.grouped).environment(model)
        }
        render("models", size: CGSize(width: 720, height: 1180), into: folder) { NavigationStack { ModelDetailView(item: running) }.environment(model) }
        render("connection", size: CGSize(width: 720, height: 860), into: folder) { ConnectionView().environment(model) }
        render("connection-claude", size: CGSize(width: 720, height: 1240), into: folder) {
            ConnectionView(agent: .claudeCode, showFiles: true).environment(model)
        }
        render("connection-codex", size: CGSize(width: 720, height: 1000), into: folder) {
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
        // A model another Mac took over, as this Mac shows it.
        let released = model.state.models[1].id
        _ = try? await store.update { $0.runs[released, default: ModelRun()].managedBy = "studio-mac-7c1e" }
        let releasedModel = AppModel(storeURL: storeURL, keychainService: service)
        await releasedModel.reloadState()
        render("model-managed", size: CGSize(width: 720, height: 520), into: folder) {
            NavigationStack { ModelDetailView(item: releasedModel.state.models[1]) }.environment(releasedModel)
        }
        // A start waiting for the card on its machine, the disk kept.
        _ = try? await store.update {
            $0.runs[released, default: ModelRun()].managedBy = nil
            $0.runs[released, default: ModelRun()].lastReason = "host-busy"
            $0.runs[released, default: ModelRun()].waitingForCard = WaitingForCard(until: Date().addingTimeInterval(3600), runUntil: nil, manual: true)
        }
        let waitingModel = AppModel(storeURL: storeURL, keychainService: service)
        await waitingModel.reloadState()
        render("model-waiting", size: CGSize(width: 720, height: 640), into: folder) {
            NavigationStack { ModelDetailView(item: waitingModel.state.models[1]) }.environment(waitingModel)
        }

        // Server mode, with a sample server that is never contacted.
        let entry = ServerEntry(name: "Office", baseURL: URL(string: "https://podlight.example.com")!)
        _ = try? await model.manager.store.update { $0.servers = [entry] }
        await model.reloadState()
        if let server = model.server(entry.id), let sample = sampleServer() {
            server.showForSnapshots(sample.0, tokens: sample.1)
            render("server-add", size: CGSize(width: 560, height: 720), into: folder) { AddServerSheet(expandedHelp: true).environment(model) }
            render("server-connection", size: CGSize(width: 720, height: 860), into: folder) {
                ServerConnectionView(serverID: entry.id).environment(model)
            }
            render("server-settings", size: CGSize(width: 720, height: 1040), into: folder) {
                ServerSettingsView(serverID: entry.id).environment(model)
            }
            render("overview-server", size: CGSize(width: 720, height: 1180), into: folder) { NavigationStack { OverviewView() }.environment(model) }
            render("server-costs", size: CGSize(width: 720, height: 760), into: folder) { CostsView(source: .server(entry.id)).environment(model) }
            if let remote = sample.0.models.first {
                model.sampleTelemetry?[remote.id] = sampleTelemetry(gpu: "NVIDIA RTX A6000", memoryGB: 48, cards: 2)
                render("server-model", size: CGSize(width: 720, height: 1180), into: folder) {
                    NavigationStack { ModelDetailView(item: remote) }.environment(model)
                }
                render("server-start", size: CGSize(width: 460, height: 560), into: folder) { StartSheet(model: remote).environment(model) }
            }
            // Right after pairing a new server: bring this Mac's key, rules and models along.
            if let fresh = sampleServer(fresh: true) {
                server.showForSnapshots(fresh.0, tokens: fresh.1)
                render("server-transfer", size: CGSize(width: 560, height: 600), into: folder) {
                    TransferSheet(request: TransferRequest(serverID: entry.id, models: [model.state.models[1].id])).environment(model)
                }
            }
        }
    }

    /// A server with one running model, as `/admin/state` reports it.
    private static func sampleServer(fresh: Bool = false) -> (ServerSnapshot, [ClientToken])? {
        let started = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-25 * 60))
        let until = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3 * 3600))
        let last = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-90))
        let today = PodlightState.dayKey(.now)
        let json = """
        {"version":"0.8.0","serverTime":"\(started)",
         "models":[{"id":"6F1D2C1E-4E57-4D7B-9A57-7E3E1C1E0001","name":"coder-office","repoId":"Qwen/Qwen3-Coder-30B-A3B-Instruct-AWQ",
           "format":"awq","weightBytes":17400000000,"nativeContextTokens":262144,"toolCallParser":"qwen3_xml","contextTokens":131072,
           "concurrency":2,"goal":"balanced","preferredGPU":{"gpuId":"NVIDIA RTX A6000","cloud":"SECURE","count":2},"preferredGPUName":"2 × RTX A6000",
           "expectedPricePerHour":0.98,"schedule":{"enabled":false,"timezone":"Europe/Berlin","weekdays":[1,2,3,4,5],"startAt":"08:00","stopAt":"18:00","idleStopMinutes":30,"maxRuntimeHours":12},
           "createdAt":"2026-11-21T10:00:00Z","keepDisk":true,"hosting":{"region":"eu","secureOnly":true}},
          {"id":"6F1D2C1E-4E57-4D7B-9A57-7E3E1C1E0002","name":"small-office","repoId":"Qwen/Qwen3-8B-AWQ","format":"awq","weightBytes":6100000000,
           "nativeContextTokens":131072,"toolCallParser":"hermes","contextTokens":32768,"goal":"economical",
           "preferredGPU":{"gpuId":"NVIDIA RTX A6000","cloud":"SECURE","count":1},"expectedPricePerHour":0.49,
           "schedule":{"enabled":false,"timezone":"Europe/Berlin","weekdays":[1,2,3,4,5],"startAt":"08:00","stopAt":"18:00","idleStopMinutes":30,"maxRuntimeHours":12},
           "keepDisk":false}],
         "runs":{"6F1D2C1E-4E57-4D7B-9A57-7E3E1C1E0001":{"podId":"srv1","gpuName":"2 × RTX A6000","pricePerHour":0.98,"podStatus":"RUNNING",
           "phase":"ready","engineReady":true,"startedManually":true,"startedAt":"\(started)","runUntil":"\(until)","lastRequestAt":"\(last)",
           "dataCenterId":"EU-SE-1","storagePerHour":0.0137},
          "6F1D2C1E-4E57-4D7B-9A57-7E3E1C1E0002":{"phase":"stopped","engineReady":false,"startedManually":false,"lastReason":"idle-timeout"}},
         "settings":{"dailyLimitUsd":15,"monthlyLimitUsd":200,"heartbeatMinutes":15,"wakeWaitSeconds":600,"deleteStoppedAfterDays":3,
           "wakeOnRequest":true,"hostingRegion":"eu","secureCloudOnly":true,"timezone":"Europe/Berlin","hasRunpodKey":\(!fresh),"hasHuggingFaceToken":true},
         "spendByDay":{"\(today)":3.4},"spend":{"todayUsd":3.4,"monthUsd":41.2,"dailyLimitUsd":15,"monthlyLimitUsd":200},
         "costPerHour":0.98,"lastClientRequestAt":"\(last)",
         "balance":{"usd":37.8,"spendPerHourUsd":1.21,"spendLimitUsd":80,"checkedAt":"\(last)"}}
        """
        let tokensJSON = """
        [{"id":"t1","name":"OpenCode on the laptop","createdAt":"2026-11-21T10:05:00Z","lastUsedAt":"\(last)","revokedAt":null,"models":null},
         {"id":"t2","name":"n8n","createdAt":"2026-11-21T10:06:00Z","lastUsedAt":null,"revokedAt":null,
          "models":["6F1D2C1E-4E57-4D7B-9A57-7E3E1C1E0002"]}]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(ServerSnapshot.self, from: Data(json.utf8)),
              let tokens = try? decoder.decode([ClientToken].self, from: Data(tokensJSON.utf8)) else { return nil }
        return (snapshot, tokens)
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

    /// 30 minutes of a pod at work: bursts of requests with idle gaps, as an agent session looks.
    nonisolated static func sampleTelemetry(gpu: String, memoryGB: Double, cards: Int = 1) -> [PodTelemetry] {
        let now = Date().timeIntervalSince1970
        return (0..<PodTelemetry.historyLimit).map { i in
            // Counted from the end, so the latest sample is in the middle of work.
            let busy = ((PodTelemetry.historyLimit - 1 - i) / 12) % 3 != 2
            let wave = (sin(Double(i) / 2.3) + 1) / 2
            let load = busy ? 55 + 40 * wave : 2
            return PodTelemetry(
                time: now - Double(PodTelemetry.historyLimit - 1 - i) * 10,
                cpuPercent: busy ? 9 + 6 * wave : 1.5,
                memoryUsedBytes: 11.2e9, memoryTotalBytes: 62e9,
                diskUsedBytes: 21.4e9, diskTotalBytes: 40e9,
                gpus: (0..<cards).map { card in
                    PodTelemetry.GPU(index: card, name: gpu, utilPercent: (load - Double(card) * 6).rounded(),
                                     memoryUsedBytes: memoryGB * (0.93 - Double(card) * 0.02) * 1e9, memoryTotalBytes: memoryGB * 1e9,
                                     temperatureC: busy ? 61 - Double(card) * 3 : 38, powerW: busy ? 210 + 80 * wave : 32, powerLimitW: 300)
                },
                engine: PodTelemetry.Engine(running: busy ? 1 + Int(wave * 2) : 0, waiting: 0, kvCachePercent: busy ? 18 + 30 * wave : 0,
                                            promptTokensPerSecond: busy ? 900 * wave : 0, generationTokensPerSecond: busy ? 48 + 14 * wave : 0))
        }
    }

    /// Two of another Mac's models: one running, one stopped with its disk kept.
    nonisolated static func sampleOtherMacsPods() -> [ForeignPod] {
        func pod(_ id: String, _ name: String, _ status: String, gpu: String, cost: Double, disk: Int) -> ForeignPod? {
            let json = """
            {"id":"\(id)","name":"podlight-\(name)@studio-mac-7c1e","status":"\(status)","cloud":"SECURE","cost":\(cost),"disk":30,
             "gpu":{"id":"\(gpu)","count":1},"mounts":{"persistent":{"size":\(disk),"path":"/workspace"}},
             "env":{"PODLIGHT_API_KEY":"sample","PODLIGHT_MODEL":"Qwen/Qwen3-32B-AWQ","PODLIGHT_SERVED_NAME":"\(name)",
                    "PODLIGHT_ENGINE":"vllm","PODLIGHT_MAX_LEN":"32768"}}
            """
            return (try? JSONDecoder().decode(RunpodPod.self, from: Data(json.utf8))).flatMap(ForeignPod.init)
        }
        // A model the other Mac has set up but not running: no pod, only its record.
        var stopped = PodlightModel(name: "huihui-qwen3.8-27b", repoId: "huihui-ai/Qwen3.8-27B-GGUF", format: .gguf,
                                    weightBytes: 17e9, nativeContextTokens: 262_144, toolCallParser: "qwen3_coder",
                                    reasoningParser: nil, contextTokens: 131_072,
                                    preferredGPU: GPUChoice(gpuId: "NVIDIA A40", cloud: .secure))
        stopped.expectedPricePerHour = 0.44
        let record = RunpodTemplate(id: "t1", name: ModelRecord.name(model: stopped.name, owner: "studio-mac-7c1e"),
                                    env: ModelRecord.env(model: stopped, podKey: "sample", podId: nil))
        return [pod("s1", "qwen3-32b", "RUNNING", gpu: "NVIDIA A40", cost: 0.44, disk: 30),
                pod("s2", "gemma3-27b", "EXITED", gpu: "NVIDIA RTX A6000", cost: 0.49, disk: 26),
                ForeignPod(record: record, pod: nil)].compactMap { $0 }
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
        small.keepDisk = true
        state.models = [coder, small]
        var run = ModelRun()
        run.podId = "sample"
        run.gpuName = "L40S"
        run.pricePerHour = 0.86
        run.storagePerHour = PodPlan.storagePerHour(for: coder)
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
        // Stopped with its disk kept, as the costs view and the overview show it.
        stopped.podId = "sample-kept"
        stopped.podStatus = .exited
        stopped.persistentGB = PodPlan.persistentGB(for: small)
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
