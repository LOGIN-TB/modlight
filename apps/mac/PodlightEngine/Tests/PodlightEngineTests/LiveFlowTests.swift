import Foundation
import Testing
@testable import PodlightEngine

// The whole local flow on real RunPod hardware, with a tiny model on the cheapest suitable card.
// Costs real money (roughly 0.10 USD), so it runs only when asked for explicitly:
//   PODLIGHT_LIVE_E2E=1 RUNPOD_API_KEY=… swift test --filter LiveFlow
// Whatever happens, the pod is deleted at the end and RunPod is asked whether it is gone.

private func log(_ message: String) {
    let stamp = Date().formatted(date: .omitted, time: .standard)
    print("[live \(stamp)] \(message)")
    fflush(stdout)
}

@Suite("Live flow on RunPod", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["PODLIGHT_LIVE_E2E"] == "1"
                && ProcessInfo.processInfo.environment["RUNPOD_API_KEY"] != nil))
struct LiveFlowTests {
    @Test(.timeLimit(.minutes(45)))
    func startServeStopResumeDelete() async throws {
        let apiKey = ProcessInfo.processInfo.environment["RUNPOD_API_KEY"]!
        let keychain = KeychainStore(service: "app.podlight.live.\(UUID().uuidString)")
        try keychain.write(apiKey, for: .runpodAPIKey)
        try keychain.write("gw-live", for: .gatewayKey)
        let stateURL = FileManager.default.temporaryDirectory.appendingPathComponent("podlight-live-\(UUID()).json")
        let manager = PodManager(store: StateStore(url: stateURL), keychain: keychain)
        let client = RunpodClient(apiKey: apiKey)
        var modelId: UUID?

        func cleanUp() async {
            if let id = modelId {
                let podId = await manager.state().run(id).podId
                try? await manager.remove(id)
                if let podId {
                    do {
                        _ = try await client.pod(id: podId)
                        log("WARNING: pod \(podId) still exists after delete")
                        try? await client.deletePod(id: podId)
                    } catch let e as RunpodError where e.isNotFound {
                        log("pod \(podId) is gone at RunPod (404)")
                    } catch { log("could not confirm deletion: \(error)") }
                }
                try? keychain.delete(.podKey(id))
            }
            for item in [KeychainStore.Item.runpodAPIKey, .gatewayKey] { try? keychain.delete(item) }
            try? FileManager.default.removeItem(at: stateURL)
        }

        do {
            // 1. Read a real model from Hugging Face.
            let info = try await HuggingFaceClient().info("Qwen/Qwen2.5-0.5B-Instruct")
            log("model: \(info.format) \(Format(info.weightBytes)) GB, context \(info.nativeContextTokens ?? 0), tools \(info.toolCallParser ?? "none")")
            #expect(info.access == .open && info.toolCallParser == "hermes")

            var model = PodlightModel(name: "qwen-tiny", repoId: info.repoId, format: info.format, weightBytes: info.weightBytes,
                                      nativeContextTokens: info.nativeContextTokens, toolCallParser: info.toolCallParser,
                                      reasoningParser: info.reasoningParser, contextTokens: 8_192, goal: .economical)
            let catalog = try await client.gpuCatalog()
            let options = GPUSuggestion.options(for: model.info, catalog: catalog, goal: .economical).filter { $0.pricePerHour <= 0.6 }
            log("cheapest suitable: " + options.prefix(5).map { "\($0.displayName) \($0.choice.cloud.rawValue) $\($0.pricePerHour)" }.joined(separator: ", "))
            model.preferredGPU = options.first?.choice
            try await manager.save(model)
            modelId = model.id

            // 2. Start with an end, and wait for the engine.
            let t0 = Date()
            try await manager.start(model.id, until: Date().addingTimeInterval(25 * 60))
            var run = await manager.state().run(model.id)
            log("created pod \(run.podId ?? "?") on \(run.gpuName ?? "?") at $\(run.pricePerHour ?? 0)/h; fell back from \(run.fellBackFrom ?? [])")
            var lastPhase = run.phase
            while Date().timeIntervalSince(t0) < 25 * 60 {
                try await Task.sleep(for: .seconds(15))
                await manager.refresh(model.id)
                run = await manager.state().run(model.id)
                if run.phase != lastPhase { log("phase \(run.phase) after \(Int(Date().timeIntervalSince(t0)))s"); lastPhase = run.phase }
                if run.phase == .ready || run.phase == .failed || run.phase == .stopped { break }
            }
            #expect(run.phase == .ready)
            #expect(run.lastHeartbeatAt != nil, "the watchdog never answered a heartbeat")
            log("ready after \(Int(Date().timeIntervalSince(t0)))s; heartbeat at \(run.lastHeartbeatAt?.description ?? "never")")

            // 3. Through the gateway, streamed, and with a tool.
            let port = Int.random(in: 45_000...48_000)
            let gateway = Task { try await LocalGateway(port: port, manager: manager, key: { "gw-live" }).run() }
            defer { gateway.cancel() }
            try await Task.sleep(for: .seconds(1))
            var chat = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
            chat.httpMethod = "POST"
            chat.timeoutInterval = 300
            chat.setValue("Bearer gw-live", forHTTPHeaderField: "Authorization")
            chat.setValue("application/json", forHTTPHeaderField: "Content-Type")
            chat.httpBody = Data(#"{"model":"qwen-tiny","stream":true,"max_tokens":40,"messages":[{"role":"user","content":"Say hello in German."}]}"#.utf8)
            let (streamed, streamResponse) = try await URLSession.shared.data(for: chat)
            let streamText = String(decoding: streamed, as: UTF8.self)
            log("stream: HTTP \((streamResponse as? HTTPURLResponse)?.statusCode ?? 0), \(streamText.components(separatedBy: "data: ").count - 1) events")
            #expect((streamResponse as? HTTPURLResponse)?.statusCode == 200 && streamText.contains("[DONE]"))

            chat.httpBody = Data(#"{"model":"qwen-tiny","max_tokens":120,"tool_choice":"auto","messages":[{"role":"user","content":"What is the weather in Berlin? Use the tool."}],"tools":[{"type":"function","function":{"name":"get_weather","description":"Current weather for a city","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}]}"#.utf8)
            let (toolData, toolResponse) = try await URLSession.shared.data(for: chat)
            let toolText = String(decoding: toolData, as: UTF8.self)
            log("tools: HTTP \((toolResponse as? HTTPURLResponse)?.statusCode ?? 0): \(toolText.prefix(400))")
            #expect((toolResponse as? HTTPURLResponse)?.statusCode == 200, "vLLM refused a request with tools")

            // 4. Stop, and check at RunPod.
            try await manager.stop(model.id)
            let stopped = try await client.pod(id: run.podId!)
            log("after stop: RunPod says \(stopped.status)")
            #expect(stopped.status == .exited)

            // 5. Resume: same pod, model already on its disk.
            let t1 = Date()
            try await manager.start(model.id, until: Date().addingTimeInterval(15 * 60))
            let resumedPod = await manager.state().run(model.id).podId
            #expect(resumedPod == run.podId, "resume built a new pod instead")
            while Date().timeIntervalSince(t1) < 15 * 60 {
                try await Task.sleep(for: .seconds(10))
                await manager.refresh(model.id)
                run = await manager.state().run(model.id)
                if run.phase == .ready || run.phase == .failed { break }
            }
            log("resume: \(run.phase) after \(Int(Date().timeIntervalSince(t1)))s on pod \(run.podId ?? "?")")
            #expect(run.phase == .ready)
            log("spend counted: \(await manager.state().spendByDay)")
        } catch {
            log("FAILED: \(error)")
            await cleanUp()
            throw error
        }
        await cleanUp()
    }

    private func Format(_ bytes: Double) -> String { String(format: "%.1f", bytes / 1e9) }
}

// 0.2 on real hardware: EU only, no kept disk, two cards with tensor parallel, read through the
// watchdog (engine log) when anything fails.
//   PODLIGHT_LIVE_E2E=1 RUNPOD_API_KEY=… swift test --filter LiveEUTwoCards
@Suite("Live 0.2 on RunPod", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["PODLIGHT_LIVE_E2E"] == "1"
                && ProcessInfo.processInfo.environment["RUNPOD_API_KEY"] != nil))
struct LiveEUTwoCards {
    /// Requests that end: RunPod's log stream never closes, so every call gets a hard limit.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()

    func get(_ url: URL, key: String) async -> (Int, Data) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await Self.session.data(for: request) else { return (0, Data()) }
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    @Test(.timeLimit(.minutes(40)))
    func euNoDiskTwoCards() async throws {
        let apiKey = ProcessInfo.processInfo.environment["RUNPOD_API_KEY"]!
        let client = RunpodClient(apiKey: apiKey, transport: Self.session)
        let podKey = PodManager.randomKey()
        var podId: String?

        func cleanUp() async {
            guard let id = podId else { return }
            try? await client.deletePod(id: id)
            do { _ = try await client.pod(id: id); print("[live] WARNING: \(id) still exists") }
            catch let e as RunpodError where e.isNotFound { print("[live] pod \(id) is gone at RunPod (404)") }
            catch { print("[live] could not confirm deletion: \(error)") }
        }

        do {
            let info = try await HuggingFaceClient().info("Qwen/Qwen2.5-0.5B-Instruct")
            let catalog = try await client.gpuCatalog()
            let eu = HostingPolicy(region: .eu)
            func candidates(_ policy: HostingPolicy, count: Int) -> [(GPUChoice, Double)] {
                catalog.filter { $0.manufacturer == "NVIDIA" && CardSupport.runsEngineImage($0.id)
                    && policy.mayHaveCapacity($0) && $0.mayHaveCuda(atLeast: PodPlan.minCudaVersion) }
                    .flatMap { gpu in policy.clouds.compactMap { cloud -> (GPUChoice, Double)? in
                        guard let p = gpu.pricePerHour(in: cloud), gpu.maxCards(in: cloud) >= count, p <= 0.6 else { return nil }
                        return (GPUChoice(gpuId: gpu.id, cloud: cloud, count: count), p * Double(count)) } }
                    .sorted { $0.1 < $1.1 }
            }
            // Two cards anywhere first (scarce in the EU), then one card in the EU to check the region path.
            let choices = Array(candidates(.anywhere, count: 2).prefix(6)) + Array(candidates(eu, count: 1).prefix(4))
            print("[live] choices: " + choices.map { "\($0.0.gpuId) \($0.0.cloud.rawValue) $\($0.1)" }.joined(separator: ", "))
            var model = PodlightModel(name: "qwen-tiny-tp2", repoId: info.repoId, format: info.format, weightBytes: info.weightBytes,
                                      nativeContextTokens: info.nativeContextTokens, toolCallParser: info.toolCallParser,
                                      reasoningParser: info.reasoningParser, contextTokens: 8_192, kvProfile: info.kvProfile,
                                      keepDisk: false)
            model.preferredGPU = choices.first?.0
            let request = PodPlan.request(for: model, podKey: podKey, huggingFaceToken: nil, runUntil: Date().addingTimeInterval(30 * 60),
                                          heartbeatMinutes: 15, dataCenterIds: nil)
            let created = try await client.createPod(request, tryingInOrder: choices.map(\.0), catalog: catalog)
            podId = created.pod.id
            print("[live] created \(created.pod.id): \(created.choice.gpuId) × \(created.choice.count), attempts \(created.attempts.map { "\($0.choice.gpuId):\($0.outcome)" })")
            let t0 = Date()
            let wd = PodPlan.proxyURL(created.pod.id, PodPlan.watchdogPort)
            let engine = PodPlan.proxyURL(created.pod.id, PodPlan.enginePort)
            var ready = false, center: String?
            while Date().timeIntervalSince(t0) < 30 * 60 {
                try await Task.sleep(for: .seconds(15))
                if let pod = try? await client.pod(id: created.pod.id) {
                    center = pod.dataCenterId
                    if pod.status == .exited || pod.status == .terminated { print("[live] pod \(pod.status) after \(Int(Date().timeIntervalSince(t0)))s"); break }
                }
                let (status, body) = await get(wd, key: podKey)
                if status == 200, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any], json["engineAlive"] as? Bool == false {
                    let (_, logData) = await get(wd.appendingPathComponent("log"), key: podKey)
                    let lines = (try? JSONSerialization.jsonObject(with: logData) as? [String: Any])?["lines"] as? [String] ?? []
                    print("[live] ENGINE EXITED (code \(json["engineExitCode"] ?? "?")). Last lines:\n" + lines.suffix(25).joined(separator: "\n"))
                    break
                }
                if await get(engine.appendingPathComponent("v1/models"), key: podKey).0 == 200 { ready = true; break }
            }
            print("[live] ready=\(ready) after \(Int(Date().timeIntervalSince(t0)))s in \(center ?? "?")")
            #expect(ready)
            print("[live] placed in \(center ?? "?") with \(created.choice.count) card(s)")
            if ready {
                let (_, logData) = await get(wd.appendingPathComponent("log"), key: podKey)
                let text = ((try? JSONSerialization.jsonObject(with: logData) as? [String: Any])?["lines"] as? [String] ?? []).joined(separator: "\n")
                print("[live] engine log mentions tensor_parallel_size=2: \(text.contains("tensor_parallel_size=2"))")
                var chat = URLRequest(url: engine.appendingPathComponent("v1/chat/completions"))
                chat.httpMethod = "POST"
                chat.setValue("Bearer \(podKey)", forHTTPHeaderField: "Authorization")
                chat.setValue("application/json", forHTTPHeaderField: "Content-Type")
                chat.httpBody = Data(#"{"model":"qwen-tiny-tp2","max_tokens":20,"messages":[{"role":"user","content":"Hallo"}]}"#.utf8)
                let (_, response) = try await Self.session.data(for: chat)
                print("[live] chat on \(created.choice.count) card(s): HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                #expect((response as? HTTPURLResponse)?.statusCode == 200)
            }
        } catch {
            print("[live] FAILED: \(error)")
            await cleanUp()
            throw error
        }
        await cleanUp()
    }
}
